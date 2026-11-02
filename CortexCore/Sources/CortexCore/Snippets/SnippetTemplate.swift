import Foundation

/// A snippet body split into text and placeholders.
///
/// | Placeholder | Becomes |
/// | --- | --- |
/// | `{clipboard}` | The text on the clipboard. `{clipboard offset=1}` is the text clip before it (up to 100; sensitive clips paste nothing). |
/// | `{cursor}` | Nothing; the cursor is put here after pasting. Only the first one counts. |
/// | `{uuid}` | A new UUID, a different one for each occurrence. |
/// | `{date}`, `{time}`, `{datetime}`, `{day}` | Now, formatted for the user's locale (`{day}` is the weekday). |
/// | `{date:yyyy-MM-dd}` | Now, with a custom format (Unicode date pattern). |
/// | `{name}` | A named fill-in, asked for before pasting. The same name twice is asked once. |
///
/// Raycast's spelling is understood as well, so imported snippets work
/// unchanged: `{date format="yyyy-MM-dd" offset="+1d"}`, `{argument name="name"
/// default="x"}`, and modifiers after a bar such as `{clipboard | uppercase}`
/// (uppercase, lowercase, trim, percent-encode, json-stringify, raw).
///
/// `{clipboard}` also takes a regular expression after a bar, as in
/// `{clipboard|plans/.*\.md}`: the clipboard is only pasted there if the
/// expression matches somewhere in it (anchor with `^` and `$` to match all of
/// it). Otherwise it becomes the text `{placeholder}`, to be filled in by hand. Modifiers can follow the
/// expression; a `}` or `{` can't be part of it.
///
/// Braces that hold anything else (JSON, code, a name with leading spaces)
/// stay as they are.
public struct SnippetTemplate: Sendable, Equatable {
    public enum Segment: Sendable, Equatable {
        case text(String)
        case placeholder(Placeholder)
    }

    public struct Placeholder: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            case clipboard(offset: Int)
            case cursor
            case uuid
            case date(DateFormat, offset: DateComponents)
            case fillIn(name: String, defaultValue: String?)
        }

        public var kind: Kind
        public var modifiers: [Modifier] = []
        /// A regular expression the clipboard has to match (`{clipboard}` only).
        public var filter: String?
    }

    public enum DateFormat: Sendable, Equatable {
        case date, time, dateTime, weekday
        /// A Unicode date pattern such as `yyyy-MM-dd`.
        case custom(String)
    }

    public enum Modifier: String, Sendable, Equatable {
        case uppercase, lowercase, trim, raw
        case percentEncode = "percent-encode"
        case jsonStringify = "json-stringify"
    }

    public struct FillIn: Sendable, Equatable, Identifiable {
        public var name: String
        public var defaultValue: String?
        public var id: String { name }
    }

    public let segments: [Segment]

    /// The furthest back `{clipboard offset=n}` reaches; a larger offset
    /// stays as text.
    public static let maxClipboardOffset = 100

    public init(_ body: String) {
        var segments: [Segment] = []
        var start = body.startIndex
        for (range, placeholder) in Self.scan(body) {
            if start < range.lowerBound { segments.append(.text(String(body[start..<range.lowerBound]))) }
            segments.append(.placeholder(placeholder))
            start = range.upperBound
        }
        if start < body.endIndex { segments.append(.text(String(body[start...]))) }
        self.segments = segments
    }

    /// Where the placeholders are in `body`, braces included, in order. The
    /// editor highlights them.
    public static func placeholderRanges(in body: String) -> [Range<String.Index>] {
        scan(body).map(\.range)
    }

    private static func scan(_ body: String) -> [(range: Range<String.Index>, placeholder: Placeholder)] {
        var found: [(range: Range<String.Index>, placeholder: Placeholder)] = []
        var index = body.startIndex
        while index < body.endIndex {
            if body[index] == "{", let close = closingBrace(in: body, after: index),
               let placeholder = placeholder(String(body[body.index(after: index)..<close])) {
                let end = body.index(after: close)
                found.append((index..<end, placeholder))
                index = end
            } else {
                index = body.index(after: index)
            }
        }
        return found
    }

    private var placeholders: [Placeholder] {
        segments.compactMap { if case .placeholder(let placeholder) = $0 { placeholder } else { nil } }
    }

    /// The fill-ins in order of first appearance, one per name.
    public var fillIns: [FillIn] {
        var seen = Set<String>()
        return placeholders.compactMap { placeholder in
            guard case .fillIn(let name, let defaultValue) = placeholder.kind, seen.insert(name).inserted else { return nil }
            return FillIn(name: name, defaultValue: defaultValue)
        }
    }

    /// Which clips the template reads: 0 is the current clipboard.
    public var clipboardOffsets: Set<Int> {
        Set(placeholders.compactMap { if case .clipboard(let offset) = $0.kind { offset } else { nil } })
    }

    public var hasPlaceholders: Bool { !placeholders.isEmpty }

    // MARK: - Rendering

    public func render(in context: SnippetContext) -> RenderedSnippet {
        var output = ""
        var cursor: Int?
        for segment in segments {
            switch segment {
            case .text(let text):
                output += text
            case .placeholder(let placeholder):
                if case .cursor = placeholder.kind {
                    if cursor == nil { cursor = output.count }
                } else if let value = Self.value(of: placeholder, in: context) {
                    output += Self.apply(placeholder.modifiers, to: value)
                } else {
                    output += Self.unmatchedFilter
                }
            }
        }
        return RenderedSnippet(text: output, cursorPosition: cursor)
    }

    /// What a clipboard placeholder becomes when its filter doesn't match.
    static let unmatchedFilter = "{placeholder}"

    /// What the placeholder becomes, or nil for a clipboard that its filter
    /// doesn't match.
    private static func value(of placeholder: Placeholder, in context: SnippetContext) -> String? {
        if case .clipboard(let offset) = placeholder.kind, let filter = placeholder.filter {
            let text = context.clipboard[offset] ?? ""
            guard let expression = try? NSRegularExpression(pattern: filter),
                  expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
            else { return nil }
            return text
        }
        return value(of: placeholder.kind, in: context)
    }

    private static func value(of kind: Placeholder.Kind, in context: SnippetContext) -> String {
        switch kind {
        case .clipboard(let offset):
            return context.clipboard[offset] ?? ""
        case .cursor:
            return ""
        case .uuid:
            return context.makeUUID().uuidString
        case .date(let format, let offset):
            let date = context.calendar.date(byAdding: offset, to: context.now) ?? context.now
            return Self.format(date, format, in: context)
        case .fillIn(let name, let defaultValue):
            return context.fillIns[name] ?? defaultValue ?? ""
        }
    }

    private static func format(_ date: Date, _ format: DateFormat, in context: SnippetContext) -> String {
        let formatter = DateFormatter()
        formatter.locale = context.locale
        formatter.calendar = context.calendar
        formatter.timeZone = context.calendar.timeZone
        switch format {
        case .date:
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
        case .time:
            formatter.dateStyle = .none
            formatter.timeStyle = .short
        case .dateTime:
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
        case .weekday:
            formatter.dateFormat = "EEEE"
        case .custom(let pattern):
            formatter.dateFormat = pattern
        }
        return formatter.string(from: date)
    }

    private static func apply(_ modifiers: [Modifier], to value: String) -> String {
        modifiers.reduce(value) { value, modifier in
            switch modifier {
            case .uppercase: value.uppercased()
            case .lowercase: value.lowercased()
            case .trim: value.trimmingCharacters(in: .whitespacesAndNewlines)
            case .raw: value
            case .percentEncode: value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
            case .jsonStringify: jsonString(value)
            }
        }
    }

    /// RFC 3986 unreserved characters.
    private static let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    private static func jsonString(_ value: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? value
    }

    // MARK: - Parsing

    /// The `}` closing the brace at `open`, unless another `{` or a line break
    /// comes first or the content gets long: then it is not a placeholder.
    private static func closingBrace(in body: String, after open: String.Index) -> String.Index? {
        var index = body.index(after: open)
        var length = 0
        while index < body.endIndex, length <= 200 {
            let character = body[index]
            if character == "}" { return index }
            if character == "{" || character.isNewline { return nil }
            index = body.index(after: index)
            length += 1
        }
        return nil
    }

    /// Parses what is between the braces, or returns nil for literal text.
    static func placeholder(_ content: String) -> Placeholder? {
        guard let first = content.first, !first.isWhitespace else { return nil }
        var parts = content.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let head = parts.removeFirst()
        guard let kind = kind(head) else { return nil }
        // Modifiers; for `{clipboard}` the first part that isn't one starts a
        // regular expression, which runs up to the modifiers at the end (so it
        // can hold a `|`).
        var filter: String?
        if case .clipboard = kind, let start = parts.firstIndex(where: { Modifier(rawValue: $0.lowercased()) == nil }) {
            var end = parts.endIndex
            while end > start + 1, Modifier(rawValue: parts[end - 1].lowercased()) != nil { end -= 1 }
            let pattern = parts[start..<end].joined(separator: "|")
            guard (try? NSRegularExpression(pattern: pattern)) != nil else { return nil }
            filter = pattern
            parts.removeSubrange(start..<end)
        }
        var modifiers: [Modifier] = []
        for part in parts {
            guard let modifier = Modifier(rawValue: part.lowercased()) else { return nil }
            modifiers.append(modifier)
        }
        return Placeholder(kind: kind, modifiers: modifiers, filter: filter)
    }

    private static func kind(_ head: String) -> Placeholder.Kind? {
        // Raycast style: a word followed by key=value attributes.
        if let space = head.firstIndex(where: \.isWhitespace),
           let attributes = attributes(head[space...]) {
            return kind(word: head[..<space].lowercased(), attributes: attributes)
        }
        // {date:format}
        if let colon = head.firstIndex(of: ":") {
            let word = head[..<colon].lowercased()
            let pattern = String(head[head.index(after: colon)...])
            guard ["date", "time", "datetime"].contains(word), !pattern.allSatisfy(\.isWhitespace) else { return nil }
            return .date(.custom(pattern), offset: DateComponents())
        }
        if let kind = kind(word: head.lowercased(), attributes: [:]) {
            return kind
        }
        return isFillInName(head) ? .fillIn(name: head, defaultValue: nil) : nil
    }

    private static func kind(word: String, attributes: [String: String]) -> Placeholder.Kind? {
        switch word {
        case "clipboard":
            guard let offset = Int(attributes["offset"] ?? "0"), (0...maxClipboardOffset).contains(offset) else { return nil }
            return .clipboard(offset: offset)
        case "cursor":
            return .cursor
        case "uuid":
            return .uuid
        case "date", "time", "datetime", "day":
            guard let offset = dateOffset(attributes["offset"] ?? "") else { return nil }
            let format: DateFormat = if let pattern = attributes["format"], !pattern.isEmpty {
                .custom(pattern)
            } else {
                switch word {
                case "time": .time
                case "datetime": .dateTime
                case "day": .weekday
                default: .date
                }
            }
            return .date(format, offset: offset)
        case "argument":
            guard let name = attributes["name"], !name.isEmpty else { return nil }
            return .fillIn(name: name, defaultValue: attributes["default"])
        default:
            return nil
        }
    }

    /// Letters, digits, `_`, `-` and inner spaces, starting with a letter or
    /// `_`, at most 40 characters.
    private static func isFillInName(_ name: String) -> Bool {
        guard let first = name.first, first.isLetter || first == "_", name.count <= 40,
              name.last?.isWhitespace == false
        else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == " " }
    }

    /// `key=value key2="quoted value"`; nil if the text is anything else.
    private static func attributes(_ text: Substring) -> [String: String]? {
        var result: [String: String] = [:]
        var rest = text.drop(while: \.isWhitespace)
        guard !rest.isEmpty else { return nil }
        while !rest.isEmpty {
            guard let equals = rest.firstIndex(of: "=") else { return nil }
            let key = rest[..<equals]
            guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0 == "-" || $0 == "_" }) else { return nil }
            rest = rest[rest.index(after: equals)...]
            let value: Substring
            if rest.first == "\"" {
                let start = rest.index(after: rest.startIndex)
                guard let end = rest[start...].firstIndex(of: "\"") else { return nil }
                value = rest[start..<end]
                rest = rest[rest.index(after: end)...]
            } else {
                let end = rest.firstIndex(where: \.isWhitespace) ?? rest.endIndex
                value = rest[..<end]
                guard !value.isEmpty else { return nil }
                rest = rest[end...]
            }
            guard rest.isEmpty || rest.first!.isWhitespace else { return nil }
            result[key.lowercased()] = String(value)
            rest = rest.drop(while: \.isWhitespace)
        }
        return result
    }

    /// Raycast's offsets: `+1d`, `-2w`, `+1M +3h`; units m h d w M y.
    private static func dateOffset(_ text: String) -> DateComponents? {
        var components = DateComponents()
        for part in text.split(whereSeparator: \.isWhitespace) {
            guard let unit = part.last, let amount = Int(part.dropLast()) else { return nil }
            switch unit {
            case "m": components.minute = (components.minute ?? 0) + amount
            case "h": components.hour = (components.hour ?? 0) + amount
            case "d": components.day = (components.day ?? 0) + amount
            case "w": components.day = (components.day ?? 0) + 7 * amount
            case "M": components.month = (components.month ?? 0) + amount
            case "y": components.year = (components.year ?? 0) + amount
            default: return nil
            }
        }
        return components
    }
}

/// What placeholders are filled with.
public struct SnippetContext: Sendable {
    public var now: Date
    public var locale: Locale
    /// Its time zone is used for dates.
    public var calendar: Calendar
    /// Clip texts by offset: 0 is the clipboard, 1 the clip before it.
    public var clipboard: [Int: String]
    /// Fill-in values by name. Missing ones use their default or stay empty.
    public var fillIns: [String: String]
    public var makeUUID: @Sendable () -> UUID

    public init(
        now: Date = .now,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent,
        clipboard: [Int: String] = [:],
        fillIns: [String: String] = [:],
        makeUUID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.now = now
        self.locale = locale
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = timeZone
        self.calendar = calendar
        self.clipboard = clipboard
        self.fillIns = fillIns
        self.makeUUID = makeUUID
    }
}

public struct RenderedSnippet: Sendable, Equatable {
    public var text: String
    /// Characters from the start where `{cursor}` was; nil without one.
    public var cursorPosition: Int?

    public init(text: String, cursorPosition: Int? = nil) {
        self.text = text
        self.cursorPosition = cursorPosition
    }

    /// How far the cursor has to move left after pasting.
    public var charactersAfterCursor: Int {
        cursorPosition.map { text.count - $0 } ?? 0
    }
}
