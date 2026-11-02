import Foundation

/// What the Snippets module offers other modules.
@MainActor
protocol SnippetsAPI: AnyObject {
    /// Opens the snippet editor on a snippet, or on a new one.
    func editSnippet(_ request: SnippetEditRequest)
}

/// What the snippet editor shows when it opens.
enum SnippetEditRequest: Equatable {
    case snippet(Int64)
    /// A new snippet, optionally with a body (a clip saved as a snippet).
    case new(body: String?)
}
