import Foundation

/// The iOS app's deep links (plans/IOS.md, M4 and M5): an item, a search, a
/// new note or to-do, the to-dos, the reading list. Reminders, calendar
/// events, widgets and intents open the app through them.
///
/// - `cortex://item/<path>`, each path component percent-encoded
/// - `cortex://search?q=<text>`
/// - `cortex://new?kind=todo&project=<id>` (`kind` is `note` or `todo`)
/// - `cortex://todos`, `cortex://reading-list`
///
/// The MCP server's resource URIs (`cortex://<project>/<path>`) are read as
/// items too, so a link an agent hands out opens the note.
public enum KnowledgeLink: Equatable, Sendable {
    case item(String)
    case search(String)
    case new(KnowledgeKind, project: String?)
    case todos
    case readingList

    public static let scheme = "cortex"

    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.percentEncodedHost?.removingPercentEncoding, !host.isEmpty
        else { return nil }
        let query = { (name: String) in
            components.queryItems?.first { $0.name == name }?.value
        }
        switch host {
        case "item":
            guard let path = Self.itemPath(components.percentEncodedPath) else { return nil }
            self = .item(path)
        case "search":
            self = .search(query("q") ?? "")
        case "new":
            let kind: KnowledgeKind = query("kind") == "todo" ? .todo : .note
            self = .new(kind, project: query("project").flatMap { $0.isEmpty ? nil : $0 })
        // With a path, these are MCP resources of projects of that name.
        case "todos" where components.percentEncodedPath.split(separator: "/").isEmpty:
            self = .todos
        case "reading-list" where components.percentEncodedPath.split(separator: "/").isEmpty:
            self = .readingList
        default:
            // An MCP resource: the host is the project.
            guard let path = Self.itemPath(host + components.percentEncodedPath), KnowledgePath.classify(path) != nil
            else { return nil }
            self = .item(path)
        }
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case .item(let path):
            components.host = "item"
            components.percentEncodedPath = "/" + path.split(separator: "/").map {
                $0.addingPercentEncoding(withAllowedCharacters: Self.pathComponentAllowed) ?? String($0)
            }.joined(separator: "/")
        case .search(let text):
            components.host = "search"
            components.queryItems = [URLQueryItem(name: "q", value: text)]
        case .new(let kind, let project):
            components.host = "new"
            components.queryItems = [URLQueryItem(name: "kind", value: kind == .todo ? "todo" : "note")]
                + (project.map { [URLQueryItem(name: "project", value: $0)] } ?? [])
        case .todos:
            components.host = "todos"
        case .readingList:
            components.host = "reading-list"
        }
        return components.url!
    }

    private static let pathComponentAllowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))

    /// A relative path inside the folder: no `..`, nothing hidden.
    private static func itemPath(_ encoded: String) -> String? {
        let components = encoded.split(separator: "/").compactMap { $0.removingPercentEncoding }
        guard !components.isEmpty, !components.contains(where: { $0 == ".." || $0.hasPrefix(".") }) else { return nil }
        return components.joined(separator: "/")
    }
}
