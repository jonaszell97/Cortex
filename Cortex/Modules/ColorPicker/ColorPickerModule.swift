import AppKit
import SwiftUI
import KeyboardShortcuts
import CortexCore

/// Picks a colour anywhere on screen with the system eyedropper (⌃⌥⌘C,
/// Pick Color in the status menu or `$color`) and copies it as hex, rgb(), hsl() or a
/// SwiftUI `Color`, in sRGB. The value is recorded as a clip, so the history
/// is the colour history; the Clipboard module shows colour clips with a
/// swatch.
@MainActor
final class ColorPickerModule: CortexModule, CommandContributing {
    static let manifest = ModuleManifest(
        id: "color-picker", name: "Color Picker", summary: "Picks a color anywhere on screen and copies its value.",
        symbol: "eyedropper", order: 55)

    let settings: ColorPickerSettings
    /// The system eyedropper; tests replace it.
    var sampler: any ColorSampling = SystemColorSampler()
    /// While the eyedropper is showing, another press does nothing.
    private(set) var isPicking = false
    private let context: ModuleContext

    init(context: ModuleContext) {
        self.context = context
        settings = ColorPickerSettings(defaults: context.defaults)
    }

    var hotkeys: [ModuleHotkey] {
        [
            ModuleHotkey(.pickColor, title: "Pick color:", help: "Shows the eyedropper; click a pixel to copy its color.") {
                [weak self] in self?.startPicking()
            },
        ]
    }

    var options: [ModuleOption] {
        let settings = Bindable(settings)
        let format = Binding(
            get: { [settings = self.settings] in settings.format.rawValue },
            set: { [settings = self.settings] in settings.format = ColorFormat(rawValue: $0) ?? .hex })
        return [
            ModuleOption(
                id: "format", title: "Copy as", help: "Values are in sRGB, as in Figma, CSS and Digital Color Meter.",
                kind: .choice(format, ColorFormat.allCases.map { ($0.rawValue, $0.title) })),
            ModuleOption(
                id: "uppercaseHex", title: "Uppercase hex", kind: .toggle(settings.uppercaseHex),
                isEnabled: { [settings = self.settings] in [.hex, .hexWithoutHash].contains(settings.format) }),
            ModuleOption(id: "notify", title: "Show a notification after picking", kind: .toggle(settings.notify)),
        ]
    }

    func statusMenuItems() -> [StatusMenuItem] {
        [StatusMenuItem("Pick Color", shortcut: .pickColor) { [weak self] in self?.startPicking() }]
    }

    private func startPicking() {
        Task { await pick() }
    }

    // MARK: - CommandContributing

    var contributedCommands: [any Command] {
        [ColorPickerCommand { [weak self] in self?.startPicking() }]
    }

    /// Shows the eyedropper and copies the picked colour; Esc leaves the
    /// clipboard alone. Returns what was copied.
    @discardableResult
    func pick() async -> String? {
        guard !isPicking else { return nil }
        isPicking = true
        defer { isPicking = false }
        let palette = context.palette
        if palette.isVisible { palette.close() }

        guard let color = await sampler.sample() else { return nil }
        let value = settings.string(for: color)
        palette.closeAndDeliver(.text(value), .copyOnly, recording: .record(sensitive: false), restoringPasteboard: false, after: nil)
        if settings.notify {
            context.notifier.post(title: "Copied \(value)", body: "Picked color, in sRGB.")
        }
        return value
    }
}

extension KeyboardShortcuts.Name {
    /// Shows the eyedropper and copies the picked colour.
    @MainActor static let pickColor = Self("pickColor", default: .init(.c, modifiers: [.control, .option, .command]))
}
