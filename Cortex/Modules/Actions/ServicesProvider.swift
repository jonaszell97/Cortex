import AppKit
import CortexCore

/// "Open in Cortex" in the Services menu (Finder's context menu → Quick
/// Actions or Services): opens the palette's quick actions on the selected
/// files or text. Declared under `NSServices` in Config/Cortex-Info.plist.
@MainActor
final class ServicesProvider: NSObject {
    private let open: (ResolvedActionInput) -> Void

    init(open: @escaping (ResolvedActionInput) -> Void) {
        self.open = open
    }

    @objc(openInCortex:userData:error:)
    func openInCortex(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !files.isEmpty {
            open(ResolvedActionInput(input: .files(files), source: .service))
        } else if let text = pasteboard.string(forType: .string), !text.isEmpty {
            open(ResolvedActionInput(input: .text(text), source: .service))
        } else {
            error.pointee = "Nothing to work on" as NSString
        }
    }
}
