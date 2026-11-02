import Foundation
import CortexCore

/// What the Clipboard module offers other modules.
@MainActor
protocol ClipboardAPI: AnyObject {
    /// Older text clips for `{clipboard offset=n}`, by offset: 1 is the one
    /// before the newest. Offset 0, the pasteboard itself, needs no module.
    func recentTexts(upTo maxOffset: Int) async -> [Int: String]
    /// The newest text clips with when they were copied, newest first, for
    /// a `$` form's suggestions. Sensitive clips are left out; the
    /// pasteboard itself is not read here.
    func recentTexts(limit: Int) async -> [RecentClipText]
    /// Whether copied text that looks like a password or token is flagged
    /// sensitive ("Detect passwords and tokens"), for other modules'
    /// recorded results (a captured text).
    var detectsSensitiveText: Bool { get }
}
