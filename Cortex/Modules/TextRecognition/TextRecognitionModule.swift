import AppKit
import SwiftUI
import KeyboardShortcuts
import CortexCore

/// Copies the text in a region of the screen (⌃⌥⌘T, Capture Text in the
/// status menu or `$ocr`): the system's selection, then Vision on this Mac.
/// The text is recorded as a clip, like a picked colour. Also contributes
/// the Recognize Text quick action for images and image files.
///
/// Off by default: capturing needs Screen Recording, which nobody should be
/// asked for before they want the feature. Making image clips searchable is
/// the Clipboard module's and needs no permission
/// (docs/modules/TEXT_RECOGNITION.md, "Who owns what").
@MainActor
final class TextRecognitionModule: CortexModule, CommandContributing, ActionContributing {
    static let manifest = ModuleManifest(
        id: "text-recognition", name: "Text Recognition", summary: "Copies the text in a region of the screen.",
        symbol: "text.viewfinder", enabledByDefault: false, permissions: [.screenRecording], order: 57)

    let settings: TextRecognitionSettings
    /// The system's selection; tests replace it.
    var capturer: any ScreenCapturing = SystemScreenCapture()
    /// nil: Vision with the languages from Settings. Tests replace it.
    var recognizer: (any TextRecognizing)?
    /// Whether Screen Recording is granted; tests replace it.
    var isPermitted: @MainActor () -> Bool = { ScreenRecordingPermission.isGranted }
    /// Says why nothing happens without the permission; tests replace it.
    var explainPermission: @MainActor () -> Void = TextRecognitionModule.showPermissionAlert
    /// While the selection is showing, another press does nothing.
    private(set) var isCapturing = false
    private let context: ModuleContext

    init(context: ModuleContext) {
        self.context = context
        settings = TextRecognitionSettings(defaults: context.defaults)
    }

    var hotkeys: [ModuleHotkey] {
        [
            ModuleHotkey(.captureText, title: "Capture text:", help: "Select a region of the screen; its text is copied.") {
                [weak self] in self?.startCapture()
            },
        ]
    }

    var options: [ModuleOption] {
        let settings = Bindable(settings)
        // Stored as Vision lists it ("zh-Hant-TW"), titled the short way
        // ("Chinese (Taiwan)", "German").
        let languages = TextRecognizer.supportedLanguages
            .map { language in
                let short = language.minimalIdentifier
                let title = Locale.current.localizedString(forIdentifier: short)
                    ?? language.languageCode.flatMap { Locale.current.localizedString(forLanguageCode: $0.identifier) }
                    ?? short
                return (value: language.maximalIdentifier, title: title)
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        let joinLines = ModuleOption(
            id: "joinLines", title: "Join the lines of a paragraph",
            help: "Off, the line breaks are kept as on screen.",
            kind: .toggle(settings.joinLines))
        return (TextRecognizer.readsDocuments ? [joinLines] : []) + [
            ModuleOption(id: "notify", title: "Show a notification after capturing", kind: .toggle(settings.notify)),
            ModuleOption(
                id: "language", title: "Language",
                help: "Automatic detects it, preferring the languages of this Mac. Also used by Recognize Text in quick actions.",
                kind: .choice(settings.language, [("", "Automatic")] + languages)),
        ]
    }

    func statusMenuItems() -> [StatusMenuItem] {
        [StatusMenuItem("Capture Text", shortcut: .captureText) { [weak self] in self?.startCapture() }]
    }

    private func startCapture() {
        Task { await capture() }
    }

    private var currentRecognizer: any TextRecognizing {
        recognizer ?? TextRecognizer(languages: settings.languages)
    }

    // MARK: - CommandContributing

    var contributedCommands: [any Command] {
        [TextRecognitionCommand { [weak self] in self?.startCapture() }]
    }

    // MARK: - ActionContributing

    var contributedActions: [any QuickAction] {
        [RecognizeTextAction(recognizer: currentRecognizer, joinLines: settings.joinLines)]
    }

    // MARK: - Capturing

    /// Lets the user select a region and copies its text; Esc or a region
    /// without text leaves the clipboard alone. Returns what was copied.
    @discardableResult
    func capture() async -> String? {
        guard !isCapturing else { return nil }
        isCapturing = true
        defer { isCapturing = false }
        let palette = context.palette
        if palette.isVisible { palette.close() }

        guard isPermitted() else {
            explainPermission()
            return nil
        }
        let text: String
        do {
            guard let image = try await capturer.capture() else { return nil }
            text = try await currentRecognizer.recognizeCapture(image, joinLines: settings.joinLines)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            context.log.error("Capturing text failed: \(error, privacy: .public)")
            context.notifier.post(title: "Capturing text failed", body: String(describing: error))
            return nil
        }
        guard !text.isEmpty else {
            // The only answer the capture gives, so it shows whatever the
            // setting says.
            context.notifier.post(title: "No text found", body: "The clipboard is unchanged.")
            return nil
        }

        let detects = context.api(ClipboardAPI.self)?.detectsSensitiveText ?? true
        let sensitive = detects && SensitiveTextDetector.looksSensitive(text)
        palette.closeAndDeliver(.text(text), .copyOnly, recording: .record(sensitive: sensitive), restoringPasteboard: false, after: nil)
        if settings.notify {
            let lines = text.split(whereSeparator: \.isNewline).count
            context.notifier.post(
                title: lines == 1 ? "Copied 1 line" : "Copied \(lines) lines",
                body: sensitive ? "It looks like a password or token, so it is masked in the history." : Self.firstLine(of: text))
        }
        return text
    }

    /// The first line, shortened for a notification.
    static func firstLine(of text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.count > 80 ? String(line.prefix(79)) + "…" : line
    }

    private static func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Cortex needs Screen Recording to read text on the screen"
        alert.informativeText = "Turn on Cortex under Screen Recording in System Settings, then quit and open Cortex again."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        let open = alert.runModal() == .alertFirstButtonReturn
        NSApp.yieldActivationIfNoWindows(besides: alert.window)
        if open { ScreenRecordingPermission.request() }
    }
}

extension KeyboardShortcuts.Name {
    /// Lets the user select a region of the screen and copies its text.
    @MainActor static let captureText = Self("captureText", default: .init(.t, modifiers: [.control, .option, .command]))
}
