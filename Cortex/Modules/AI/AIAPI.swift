import Foundation
import CortexCore

/// What the AI module offers other modules: the vendor and text model set
/// in Settings → AI and a way to send, for requests of their own
/// (Knowledge's `$note`, `$todo` and `$tidy`). Only there while AI is on.
@MainActor
protocol AIAPI: AnyObject {
    var vendor: AIVendorID { get }
    var textModel: String { get }
    /// Sends a request with the vendor's API key from the Keychain and
    /// counts what it used, like AI's own actions. Errors are
    /// `QuickActionError`s meant for the user. Only ever called when the
    /// user runs something.
    var send: @Sendable (AIRequest) async throws -> AIResponse { get }
}
