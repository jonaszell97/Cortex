import Foundation

/// Cortex borrowing the pasteboard: copying the selection in another app to
/// read it, then putting the clipboard back. The clipboard history leaves
/// pasteboard changes unread while it is borrowed; what Cortex puts back is
/// marked as its own, and anything another app copies meanwhile is still
/// recorded afterwards.
@MainActor
final class PasteboardActivity {
    private var borrowers = 0

    var isBorrowed: Bool { borrowers > 0 }

    func borrow<T>(_ body: @MainActor () async -> T) async -> T {
        borrowers += 1
        defer { borrowers -= 1 }
        return await body()
    }
}
