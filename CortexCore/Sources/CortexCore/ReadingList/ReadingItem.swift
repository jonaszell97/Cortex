import Foundation
import GRDB

/// A link saved to read later. Opening it marks it read.
public struct ReadingItem: Codable, Sendable, Identifiable, Hashable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    /// Normalized by `ReadingItem.normalizedURL`, unique. It is also the
    /// record's sync key, so it never changes once saved.
    public var url: String
    /// nil when there was none to take; the list shows the host instead.
    public var title: String?
    public var note: String?
    /// The app the link was saved from, when known.
    public var sourceAppName: String?
    public var addedAt: Date
    /// nil while unread.
    public var readAt: Date?

    public static let databaseTableName = "readingItem"

    public init(
        id: Int64? = nil,
        url: String,
        title: String? = nil,
        note: String? = nil,
        sourceAppName: String? = nil,
        addedAt: Date = .now,
        readAt: Date? = nil
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.note = note
        self.sourceAppName = sourceAppName
        self.addedAt = addedAt
        self.readAt = readAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public var isRead: Bool { readAt != nil }

    /// The host without a leading "www.".
    public var host: String {
        let host = URLComponents(string: url)?.host ?? url
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The title, or a name made from the link for one without.
    public var displayTitle: String { title ?? untitledName }

    /// What a link without a title is called: its last readable path segment
    /// and its site, "Context Window (claude.com)" for
    /// https://code.claude.com/docs/en/context-window. Just the host when the
    /// path has nothing readable.
    public var untitledName: String {
        guard let name = Self.pageName(inPath: URLComponents(string: url)?.percentEncodedPath ?? "") else { return host }
        return "\(name) (\(site))"
    }

    /// The host without its subdomains: "claude.com" for "code.claude.com",
    /// "bbc.co.uk" for "news.bbc.co.uk". IP addresses and single-label hosts
    /// stay whole.
    public var site: String {
        let labels = host.split(separator: ".")
        guard labels.count > 2, !labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return host }
        // "co.uk", "com.au" and the like: a short label under a country code.
        let keep = labels[labels.count - 1].count == 2 && labels[labels.count - 2].count <= 3 ? 3 : 2
        return labels.suffix(keep).joined(separator: ".")
    }

    /// File extensions that say nothing about the page.
    static let pageExtensions: Set<String> = ["html", "htm", "php", "asp", "aspx", "jsp", "shtml"]

    /// The last path segment that reads like a name, with dashes and
    /// underscores as spaces; all-lowercase ones get capitalized words.
    /// Numbers, hashes, UUIDs and "index" are skipped.
    static func pageName(inPath path: String) -> String? {
        for segment in path.split(separator: "/").reversed() {
            var name = segment.removingPercentEncoding ?? String(segment)
            if let dot = name.lastIndex(of: "."), pageExtensions.contains(name[name.index(after: dot)...].lowercased()) {
                name = String(name[..<dot])
            }
            let words = name.split { $0 == "-" || $0 == "_" || $0 == "+" || $0.isWhitespace }
            guard !words.isEmpty, name.lowercased() != "index", !isIdentifier(name) else { continue }
            let readable = name.contains(where: \.isUppercase)
                ? words.joined(separator: " ")
                : words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
            return readable
        }
        return nil
    }

    /// Whether a path segment is an ID rather than a name: no letters, or a
    /// long run of hex digits and dashes (a hash or a UUID).
    static func isIdentifier(_ segment: String) -> Bool {
        guard segment.contains(where: \.isLetter) else { return true }
        let hex = segment.filter { $0 != "-" }
        return hex.count >= 8 && hex.contains(where: \.isNumber) && hex.allSatisfy(\.isHexDigit)
    }

    /// Empty or whitespace-only titles and notes mean "none".
    public static func normalizedText(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    // MARK: - URLs

    /// Whether pasted text is a link to save: a web link that says so with
    /// a scheme or "www.". A bare "file.txt" or "see example.com" is not.
    public static func isPastedLink(_ text: String) -> Bool {
        guard normalizedURL(text) != nil else { return false }
        return text.contains("://") || text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("www.")
    }

    /// Query parameters that only track where a link came from.
    static let trackingParameters: Set<String> = ["fbclid", "gclid", "dclid", "msclkid", "mc_cid", "mc_eid", "igshid"]

    /// The form a link is stored and compared in, or nil if `text` is not a
    /// web link: http or https, a host, no whitespace. A bare "example.com/a"
    /// gets https. The scheme and host are lowercased; tracking parameters
    /// (`utm_*` and the like), a plain `#anchor` and a lone trailing "/" go.
    /// Fragments that look like app routes (`#/inbox`, `#!/page`) stay.
    public static func normalizedURL(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard var components = URLComponents(string: withScheme),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil
        else { return nil }
        // Without a scheme, only something that looks like a domain counts.
        if !trimmed.contains("://"), !host.contains(".") { return nil }

        components.scheme = scheme
        components.host = host
        if let items = components.percentEncodedQueryItems {
            let kept = items.filter { item in
                let name = item.name.lowercased()
                return !name.hasPrefix("utm_") && !trackingParameters.contains(name)
            }
            components.percentEncodedQueryItems = kept.isEmpty ? nil : kept
        }
        if let fragment = components.fragment, !(fragment.hasPrefix("/") || fragment.hasPrefix("!")) {
            components.fragment = nil
        }
        if components.path == "/", components.fragment == nil { components.path = "" }
        return components.string
    }
}
