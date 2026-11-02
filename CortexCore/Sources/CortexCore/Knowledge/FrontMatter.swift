import Foundation

/// The YAML front matter of a knowledge file, the block between two `---`
/// lines at its very start.
///
/// Only the subset the files use is understood: `key: value`, inline lists
/// (`[a, b]`), block lists (`- a` lines), quoted strings, `~` or nothing for
/// null, and comments after a value. Anything else under a key (a nested
/// map) is kept as written, so rewriting a file an agent wrote loses nothing.
/// Keys keep their order.
public struct FrontMatter: Equatable, Sendable {
    public enum Value: Equatable, Sendable {
        case text(String)
        case list([String])
        case null
        /// Indented lines that are not a list, kept verbatim (without the key line).
        case raw(String)
    }

    public struct Entry: Equatable, Sendable {
        public var key: String
        public var value: Value
    }

    public private(set) var entries: [Entry]

    public init(_ entries: [Entry] = []) {
        self.entries = entries
    }

    public var isEmpty: Bool { entries.isEmpty }

    public subscript(key: String) -> Value? {
        entries.first { $0.key == key }?.value
    }

    /// A text value; a list's items joined with ", ".
    public func string(_ key: String) -> String? {
        switch self[key] {
        case .text(let text): text
        case .list(let items): items.joined(separator: ", ")
        default: nil
        }
    }

    /// A list, or a single text value as a list of one (`tags: cli`).
    public func list(_ key: String) -> [String] {
        switch self[key] {
        case .list(let items): items
        case .text(let text) where !text.isEmpty: [text]
        default: []
        }
    }

    /// A timestamp (`2026-10-22T10:12:00Z`) or a day (`2026-10-30`, midnight UTC).
    public func date(_ key: String) -> Date? {
        string(key).flatMap(Self.parseDate)
    }

    /// Replaces the value in place or appends the key; nil removes it.
    public mutating func set(_ key: String, _ value: Value?) {
        let index = entries.firstIndex { $0.key == key }
        switch (index, value) {
        case (let index?, let value?): entries[index].value = value
        case (let index?, nil): entries.remove(at: index)
        case (nil, let value?): entries.append(Entry(key: key, value: value))
        case (nil, nil): break
        }
    }

    public mutating func set(_ key: String, text: String?) {
        set(key, text.map(Value.text))
    }

    public mutating func set(_ key: String, date: Date?) {
        set(key, date.map { .text(Self.format($0)) })
    }

    // MARK: - Reading

    /// The front matter and the body after it. Text without front matter is
    /// all body.
    public static func split(_ text: String) -> (frontMatter: FrontMatter?, body: String) {
        var text = text
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.hasSuffix("\r") ? line.dropLast() : line
        }
        guard lines.first == "---" else { return (nil, text) }
        guard let end = lines.dropFirst().firstIndex(where: { $0 == "---" || $0 == "..." }) else { return (nil, text) }
        let frontMatter = parse(lines[1..<end].map(String.init))
        let body = lines[(end + 1)...].joined(separator: "\n")
        return (frontMatter, body)
    }

    static func parse(_ lines: [String]) -> FrontMatter {
        var entries: [Entry] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            guard !line.isEmpty, !line.hasPrefix(" "), !line.hasPrefix("\t"), !line.hasPrefix("#"),
                  let colon = line.firstIndex(of: ":")
            else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let rest = String(line[line.index(after: colon)...])
            // The indented lines below belong to this key.
            var nested: [String] = []
            while index < lines.count, lines[index].isEmpty || lines[index].first == " " || lines[index].first == "\t"
                || lines[index].hasPrefix("- ") {
                nested.append(lines[index])
                index += 1
            }
            while nested.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { nested.removeLast() }
            let value = parseValue(rest, nested: nested)
            if let existing = entries.firstIndex(where: { $0.key == key }) {
                entries[existing].value = value
            } else {
                entries.append(Entry(key: key, value: value))
            }
        }
        return FrontMatter(entries)
    }

    private static func parseValue(_ text: String, nested: [String]) -> Value {
        let inline = stripComment(text).trimmingCharacters(in: .whitespaces)
        if inline.isEmpty || inline == "~" || inline == "null" {
            guard !nested.isEmpty else { return .null }
            let trimmed = nested.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if trimmed.allSatisfy({ $0.hasPrefix("- ") || $0 == "-" }) {
                return .list(trimmed.map { unquote(stripComment(String($0.dropFirst())).trimmingCharacters(in: .whitespaces)) })
            }
            return .raw(nested.joined(separator: "\n"))
        }
        if inline.hasPrefix("["), inline.hasSuffix("]") {
            return .list(splitList(String(inline.dropFirst().dropLast())))
        }
        if inline == "|" || inline == ">" || inline.hasPrefix("|") || inline.hasPrefix(">") {
            return .raw(([rest(of: text)] + nested).joined(separator: "\n"))
        }
        return .text(unquote(inline))
    }

    private static func rest(of text: String) -> String {
        " " + text.trimmingCharacters(in: .whitespaces)
    }

    /// Drops ` # comment` outside quotes.
    static func stripComment(_ text: String) -> String {
        var quote: Character?
        var previous: Character = " "
        for index in text.indices {
            let character = text[index]
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "#", previous == " " || previous == "\t" {
                return String(text[..<index])
            }
            previous = character
        }
        return text
    }

    private static func splitList(_ text: String) -> [String] {
        var items: [String] = []
        var current = ""
        var quote: Character?
        for character in text {
            if let open = quote {
                current.append(character)
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
                current.append(character)
            } else if character == "," {
                items.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        items.append(current)
        return items.map { unquote($0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty }
    }

    static func unquote(_ text: String) -> String {
        if text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") {
            var result = ""
            var escaped = false
            for character in text.dropFirst().dropLast() {
                if escaped {
                    switch character {
                    case "n": result.append("\n")
                    case "t": result.append("\t")
                    default: result.append(character)
                    }
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else {
                    result.append(character)
                }
            }
            return result
        }
        if text.count >= 2, text.hasPrefix("'"), text.hasSuffix("'") {
            return String(text.dropFirst().dropLast()).replacing("''", with: "'")
        }
        return text
    }

    // MARK: - Writing

    /// `---`, one line per key, `---`, each line ending in a newline.
    public func rendered() -> String {
        var lines = ["---"]
        for entry in entries {
            switch entry.value {
            case .text(let text): lines.append("\(entry.key): \(Self.quoteIfNeeded(text))")
            case .list(let items): lines.append("\(entry.key): [\(items.map { Self.quoteIfNeeded($0, inList: true) }.joined(separator: ", "))]")
            case .null: lines.append("\(entry.key): ~")
            case .raw(let raw):
                if raw.hasPrefix(" |") || raw.hasPrefix(" >") {
                    lines.append("\(entry.key):\(raw)")
                } else {
                    lines.append("\(entry.key):")
                    lines.append(raw)
                }
            }
        }
        lines.append("---")
        return lines.joined(separator: "\n") + "\n"
    }

    /// The file: front matter (if any), then the body.
    public static func compose(_ frontMatter: FrontMatter?, body: String) -> String {
        guard let frontMatter, !frontMatter.isEmpty else { return body }
        return frontMatter.rendered() + body
    }

    /// Plain when YAML would read it back as the same string, double-quoted
    /// otherwise (`yes`, `12`, `a: b`, `#tag`, leading or trailing spaces).
    static func quoteIfNeeded(_ text: String, inList: Bool = false) -> String {
        let lowered = text.lowercased()
        let needsQuotes = text.isEmpty
            || text != text.trimmingCharacters(in: .whitespaces)
            || ["true", "false", "yes", "no", "on", "off", "null", "~"].contains(lowered)
            || Double(text) != nil
            || text.contains(": ") || text.hasSuffix(":") || text.contains(" #")
            || text.contains(where: { $0.isNewline || $0 == "\t" })
            || "-?:,[]{}#&*!|>'\"%@`".contains(text.first!)
            || (inList && text.contains(where: { ",[]{}".contains($0) }))
        guard needsQuotes else { return text }
        let escaped = text
            .replacing("\\", with: "\\\\")
            .replacing("\"", with: "\\\"")
            .replacing("\n", with: "\\n")
            .replacing("\t", with: "\\t")
        return "\"\(escaped)\""
    }

    // MARK: - Dates

    /// `2026-10-22T10:12:00Z`
    public static func format(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    /// `2026-10-30`
    public static func formatDay(_ date: Date, timeZone: TimeZone = .current) -> String {
        date.formatted(Date.ISO8601FormatStyle(dateSeparator: .dash, timeZone: timeZone).year().month().day())
    }

    public static func parseDate(_ text: String) -> Date? {
        let text = text.trimmingCharacters(in: .whitespaces)
        if let date = try? Date(text, strategy: .iso8601) { return date }
        if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
        return try? Date(text, strategy: Date.ISO8601FormatStyle().year().month().day())
    }
}
