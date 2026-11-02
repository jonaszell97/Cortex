import AppKit
import CortexCore

extension ResolvedActionInput {
    /// What is on the pasteboard right now.
    @MainActor
    static func pasteboard(_ pasteboard: NSPasteboard = .general, problem: String? = nil) -> ResolvedActionInput {
        let snapshot = PasteboardReader.snapshot(
            of: pasteboard, types: (pasteboard.types ?? []).map(\.rawValue), source: nil)
        return ResolvedActionInput(
            input: snapshot.map(ActionInput.init) ?? .none, source: .pasteboard, problem: problem,
            isSensitive: snapshot?.isSensitive ?? false)
    }
}

extension ActionInput {
    /// A clip as action input: files as files, a bare image as an image,
    /// everything else as its plain text.
    init(_ detail: ClipDetail) {
        self.init(kind: detail.item.kind, plainText: detail.item.plainText, fileURLs: detail.fileURLs, imageData: detail.imageData)
    }

    init(_ snapshot: ClipSnapshot) {
        let data = { (type: String) in snapshot.representations.first { $0.type == type }?.data }
        let fileURLs = data(ClipType.fileURL).flatMap { String(data: $0, encoding: .utf8) }?
            .split(separator: "\n").compactMap { URL(string: String($0)) } ?? []
        self.init(kind: snapshot.kind, plainText: snapshot.plainText, fileURLs: fileURLs,
                  imageData: data(ClipType.png) ?? data(ClipType.tiff))
    }

    private init(kind: ClipItem.Kind, plainText: String?, fileURLs: [URL], imageData: Data?) {
        switch kind {
        case .files where !fileURLs.isEmpty:
            self = .files(fileURLs.filter(\.isFileURL))
        case .image:
            if let imageData { self = .image(imageData) } else { self = .none }
        default:
            if let plainText, !plainText.isEmpty { self = .text(plainText) } else { self = .none }
        }
    }
}

/// Reads the selected files in Finder over Apple Events. The first time,
/// macOS asks whether Cortex may control Finder.
@MainActor
enum FinderSelection {
    static let bundleID = "com.apple.finder"

    private static let script = """
        tell application id "com.apple.finder"
            set output to ""
            repeat with selectedItem in (get selection as alias list)
                set output to output & POSIX path of selectedItem & linefeed
            end repeat
            return output
        end tell
        """

    /// The selected files, or a message explaining why they cannot be read.
    static func read() -> Result<[URL], QuickActionError> {
        var error: NSDictionary?
        guard let result = NSAppleScript(source: script)?.executeAndReturnError(&error) else {
            let number = error?[NSAppleScript.errorNumber] as? Int
            Log.logger("actions").notice("Reading the Finder selection failed: \(number ?? 0, privacy: .public)")
            if number == -1743 {
                return .failure(QuickActionError(
                    "Cortex may not control Finder. Allow it in System Settings → Privacy & Security → Automation."))
            }
            return .failure(QuickActionError("Could not read the Finder selection"))
        }
        let paths = (result.stringValue ?? "").split(separator: "\n").map(String.init)
        return .success(paths.map { URL(filePath: $0) })
    }

    static func openAutomationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
    }
}
