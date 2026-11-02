import Foundation
import GRDB

/// One snippet in Raycast's JSON export ("Export Snippets"): an array of
/// objects with `name`, `text` and an optional `keyword`.
public struct RaycastSnippet: Codable, Sendable, Equatable {
    public var name: String
    public var text: String
    public var keyword: String?

    public init(name: String, text: String, keyword: String? = nil) {
        self.name = name
        self.text = text
        self.keyword = keyword
    }
}

public enum RaycastSnippetFormatError: Error, LocalizedError {
    case notSnippetJSON

    public var errorDescription: String? {
        "The file is not a Raycast snippet export (a JSON list of snippets with name and text)."
    }
}

/// Reading and writing Raycast's snippet JSON, so snippets can move in and
/// out again. Tags and usage counts have no place in the format.
public enum RaycastSnippets {
    public static func decode(_ data: Data) throws -> [RaycastSnippet] {
        let decoder = JSONDecoder()
        if let list = try? decoder.decode([RaycastSnippet].self, from: data) {
            return list
        }
        // Tolerate a wrapping object, in case a later Raycast version adds one.
        struct Wrapped: Decodable { var snippets: [RaycastSnippet] }
        if let wrapped = try? decoder.decode(Wrapped.self, from: data) {
            return wrapped.snippets
        }
        throw RaycastSnippetFormatError.notSnippetJSON
    }

    public static func encode(_ snippets: [Snippet]) throws -> Data {
        let list = snippets
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { RaycastSnippet(name: $0.name, text: $0.body, keyword: $0.keyword) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(list)
    }
}

/// What an import would do, computed without changing anything (the dry run
/// shown before importing). Snippets are matched by name, ignoring case.
public struct SnippetImportPlan: Sendable {
    public enum Action: Sendable, Equatable {
        case add
        /// Same name, different text or keyword.
        case replace(existingID: Int64)
        /// Same name, text and keyword: nothing to do.
        case unchanged
        /// An earlier entry in the file has the same name.
        case duplicateInFile
        case invalid(String)
    }

    public struct Entry: Sendable, Identifiable {
        public var id: Int
        public var snippet: RaycastSnippet
        public var action: Action
        /// The keyword after import: nil when there is none, or when another
        /// snippet already uses it.
        public var keyword: String?
        /// Things to know about this entry (dropped keyword, placeholders
        /// that only Raycast understands).
        public var notes: [String]
    }

    public var entries: [Entry]

    public func count(_ matches: (Action) -> Bool) -> Int {
        entries.count { matches($0.action) }
    }

    public var addCount: Int { count { $0 == .add } }
    public var replaceCount: Int { count { if case .replace = $0 { true } else { false } } }
    public var unchangedCount: Int { count { $0 == .unchanged } }
    public var skippedCount: Int { entries.count - addCount - replaceCount - unchangedCount }

    /// Placeholders Raycast has and Cortex does not; they would turn into
    /// fill-ins or stay as text.
    static let raycastOnlyPlaceholders = ["selection", "browser-tab", "snippet"]

    public init(incoming: [RaycastSnippet], existing: [Snippet]) {
        let existingByName = Dictionary(existing.map { (Self.nameKey($0.name), $0) }, uniquingKeysWith: { first, _ in first })
        // Keyword → name of the snippet holding it after the import so far.
        var keywordOwners = Dictionary(
            existing.compactMap { snippet in snippet.keyword.map { ($0, Self.nameKey(snippet.name)) } },
            uniquingKeysWith: { first, _ in first })
        var seenNames = Set<String>()

        entries = incoming.enumerated().map { index, snippet in
            let name = snippet.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = Self.nameKey(name)
            let keyword = Snippet.normalizedKeyword(snippet.keyword)
            var entry = Entry(id: index, snippet: snippet, action: .add, keyword: keyword, notes: [])

            if name.isEmpty {
                entry.action = .invalid("No name")
                return entry
            }
            if snippet.text.isEmpty {
                entry.action = .invalid("No text")
                return entry
            }
            guard seenNames.insert(key).inserted else {
                entry.action = .duplicateInFile
                return entry
            }

            if let current = existingByName[key] {
                let unchanged = current.body == snippet.text && current.keyword == keyword
                entry.action = unchanged ? .unchanged : .replace(existingID: current.id!)
                if !unchanged, let old = current.keyword, keywordOwners[old] == key {
                    keywordOwners[old] = nil
                }
            }
            if let wanted = keyword {
                if wanted.contains(where: \.isWhitespace) {
                    entry.keyword = nil
                    entry.notes.append("Keyword “\(wanted)” contains a space and is left out.")
                } else if let owner = keywordOwners[wanted], owner != key {
                    entry.keyword = nil
                    entry.notes.append("Keyword “\(wanted)” is already used by another snippet and is left out.")
                } else {
                    keywordOwners[wanted] = key
                }
            }
            let template = SnippetTemplate(snippet.text)
            if template.clipboardOffsets.contains(where: { $0 > 0 }) {
                entry.notes.append("Pastes older clipboard history ({clipboard offset=…}) wherever it is used.")
            }
            let fillIns = Set(template.fillIns.map { $0.name.lowercased() })
            let unsupported = Self.raycastOnlyPlaceholders.filter {
                fillIns.contains($0) || snippet.text.contains("{\($0) ")
            }
            if !unsupported.isEmpty {
                entry.notes.append("Uses Raycast placeholders Cortex does not fill in: "
                                   + unsupported.map { "{\($0)}" }.joined(separator: ", "))
            }
            return entry
        }
    }

    /// Matches SQLite's NOCASE, which the name column uses: ASCII only.
    static func nameKey(_ name: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in name.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars {
            scalars.append(("A"..."Z").contains(scalar) ? Unicode.Scalar(scalar.value + 32)! : scalar)
        }
        return String(scalars)
    }
}

public struct SnippetImportReport: Sendable, Equatable {
    public var added = 0
    public var replaced = 0
    public var unchanged = 0
    public var skipped = 0
}

extension SnippetStore {
    /// Carries out an import plan in one transaction.
    ///
    /// - Parameter replaceChanged: Whether snippets that exist with different
    ///   text or keyword are overwritten; otherwise they are skipped.
    @discardableResult
    public func apply(_ plan: SnippetImportPlan, replaceChanged: Bool, now: Date = .now) throws -> SnippetImportReport {
        let report = try write { db in
            var report = SnippetImportReport()
            for entry in plan.entries {
                switch entry.action {
                case .add:
                    let snippet = Snippet(name: entry.snippet.name, keyword: entry.keyword, body: entry.snippet.text)
                    try Self.saveDroppingTakenKeyword(snippet, now: now, db: db)
                    report.added += 1
                case .replace(let id) where replaceChanged:
                    guard var snippet = try Snippet.fetchOne(db, key: id) else {
                        report.skipped += 1
                        continue
                    }
                    snippet.body = entry.snippet.text
                    snippet.keyword = entry.keyword
                    try Self.saveDroppingTakenKeyword(snippet, now: now, db: db)
                    report.replaced += 1
                case .unchanged:
                    report.unchanged += 1
                case .replace, .duplicateInFile, .invalid:
                    report.skipped += 1
                }
            }
            return report
        }
        Log.logger("import").info("Raycast snippets: \(report.added) added, \(report.replaced) replaced, \(report.unchanged) unchanged, \(report.skipped) skipped")
        return report
    }

    /// The plan assumes changed snippets get replaced. When they are kept,
    /// a keyword the plan moved to another snippet may still be taken; that
    /// snippet is then imported without it.
    private static func saveDroppingTakenKeyword(_ snippet: Snippet, now: Date, db: Database) throws {
        do {
            _ = try save(snippet, now: now, db: db)
        } catch SnippetStoreError.duplicateKeyword {
            var snippet = snippet
            snippet.keyword = nil
            _ = try save(snippet, now: now, db: db)
        }
    }
}
