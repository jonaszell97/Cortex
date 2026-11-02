import Foundation

/// A built-in action on text: fast, pure, previewed in the palette before
/// it runs.
public struct TextAction: QuickAction {
    public enum Accepts: Sendable {
        /// Non-empty text.
        case text
        /// Text or no input at all (generators such as UUID, which ignore
        /// it). Not offered for files and images.
        case anything
    }

    public let id: String
    public let title: String
    public let symbol: String
    public let keywords: [String]
    public let acceptsKind: Accepts
    public let options: [ActionOption]
    private let transform: @Sendable (String, ActionOptionValues) throws -> ActionOutput

    public init(
        id: String,
        title: String,
        symbol: String,
        keywords: [String] = [],
        accepts: Accepts = .text,
        transform: @escaping @Sendable (String) throws -> ActionOutput
    ) {
        self.init(id: id, title: title, symbol: symbol, keywords: keywords, accepts: accepts, options: []) { text, _ in
            try transform(text)
        }
    }

    public init(
        id: String,
        title: String,
        symbol: String,
        keywords: [String] = [],
        accepts: Accepts = .text,
        options: [ActionOption],
        transform: @escaping @Sendable (String, ActionOptionValues) throws -> ActionOutput
    ) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.keywords = keywords
        acceptsKind = accepts
        self.options = options
        self.transform = transform
    }

    public var isInstant: Bool { true }

    public func accepts(_ input: ActionInput) -> Bool {
        switch acceptsKind {
        case .anything: input.kind == .text || input.kind == .none
        case .text: input.text.map { !$0.isEmpty } ?? false
        }
    }

    public func run(_ input: ActionInput, context: ActionContext) async throws -> ActionOutput {
        try perform(input, options: context.options)
    }

    /// The synchronous transformation, for the palette's preview.
    public func perform(_ input: ActionInput, options: ActionOptionValues = ActionOptionValues()) throws -> ActionOutput {
        try transform(input.text ?? "", options)
    }
}

public extension TextAction {
    /// Its `.snippet` result needs the snippet editor; the app hides it
    /// when snippets are unavailable.
    static let createSnippetID = "snippet.create"
    /// Its `.saveCommand` result asks for a name in an alert, so Shortcuts
    /// does not offer it.
    static let saveCommandID = "usercommand.save"

    static let all: [TextAction] = base + caseConversions

    private static let base: [TextAction] = [
        TextAction(id: "text.json.pretty", title: "Format JSON", symbol: "curlybraces", keywords: ["pretty", "json", "beautify"]) {
            .text(try JSONFormatter.pretty($0))
        },
        TextAction(id: "text.json.minify", title: "Minify JSON", symbol: "curlybraces", keywords: ["compact", "json"]) {
            .text(try JSONFormatter.minify($0))
        },
        TextAction(id: "text.base64.encode", title: "Base64 Encode", symbol: "lock.doc", keywords: ["base64", "encode"]) {
            .text(Data($0.utf8).base64EncodedString())
        },
        TextAction(id: "text.base64.decode", title: "Base64 Decode", symbol: "lock.open", keywords: ["base64", "decode"]) {
            try TextTransforms.base64Decode($0)
        },
        TextAction(id: "text.url.encode", title: "URL Encode", symbol: "link", keywords: ["percent", "escape", "url", "encode"]) {
            .text(TextTransforms.urlEncode($0))
        },
        TextAction(id: "text.url.decode", title: "URL Decode", symbol: "link", keywords: ["percent", "unescape", "url", "decode"]) {
            guard let decoded = $0.removingPercentEncoding else { throw QuickActionError("Not valid percent-encoded text") }
            return .text(decoded)
        },
        TextAction(id: "text.trim", title: "Trim Whitespace", symbol: "scissors", keywords: ["strip", "spaces", "trim"]) {
            .text($0.trimmingCharacters(in: .whitespacesAndNewlines))
        },
        TextAction(id: "text.singleline", title: "Single Line", symbol: "arrow.right.to.line", keywords: ["join", "lines", "one", "unwrap", "newlines", "backslash", "continuation", "command", "shell"]) {
            .text(TextTransforms.singleLine($0))
        },
        TextAction(id: "text.uppercase", title: "Uppercase", symbol: "textformat.size.larger", keywords: ["upper", "caps"]) {
            .text($0.uppercased())
        },
        TextAction(id: "text.lowercase", title: "Lowercase", symbol: "textformat.size.smaller", keywords: ["lower"]) {
            .text($0.lowercased())
        },
        TextAction(id: "text.titlecase", title: "Title Case", symbol: "textformat", keywords: ["capitalize", "title"]) {
            .text($0.capitalized)
        },
        TextAction(id: "text.count", title: "Count Words", symbol: "number", keywords: ["count", "characters", "length", "words"]) {
            .done(TextTransforms.counts($0))
        },
        TextAction(id: "text.plain", title: "Strip Formatting", symbol: "textformat.alt", keywords: ["plain", "text", "formatting"]) {
            .text($0)
        },
        TextAction(id: "text.markdown.table", title: "Markdown Table from TSV", symbol: "tablecells", keywords: ["markdown", "table", "tsv", "spreadsheet", "excel", "numbers"]) {
            .text(try TextTransforms.markdownTable(fromTSV: $0))
        },
        TextAction(id: "text.pad", title: "Pad", symbol: "arrow.left.and.right.text.vertical", keywords: ["pad", "fill", "align", "leading", "trailing", "zeros", "left", "right"], options: PadOptions.all) { text, options in
            .text(TextTransforms.pad(
                text,
                to: try options.integer(PadOptions.length),
                with: try options.character(PadOptions.character),
                left: options[PadOptions.side] == PadOptions.left))
        },
        TextAction(id: "text.qrcode", title: "QR Code", symbol: "qrcode", keywords: ["qr", "code", "barcode"]) {
            .image(try QRCode.png(for: $0))
        },
        TextAction(id: createSnippetID, title: "Create Snippet", symbol: "text.badge.plus", keywords: ["snippet", "save", "new", "template"]) {
            .snippet($0)
        },
        TextAction(id: saveCommandID, title: "Save as Command", symbol: "terminal", keywords: ["command", "shell", "save", "trigger", "script", "new"]) {
            .saveCommand(try CommandFile.command(from: $0))
        },
        TextAction(id: "generate.uuid", title: "Generate UUID", symbol: "number.square", keywords: ["uuid", "guid", "random", "id"], accepts: .anything) { _ in
            .text(UUID().uuidString)
        },
        TextAction(id: "generate.isodate", title: "Current ISO Date", symbol: "calendar", keywords: ["date", "time", "now", "iso8601", "timestamp"], accepts: .anything) { _ in
            .text(TextTransforms.isoDate(.now))
        },
    ]
}

/// "Pad": which side, to what length, with what.
public enum PadOptions {
    public static let left = "left"
    public static let side = ActionOption(
        id: "side", title: "Side",
        kind: .choice([.init(left, title: "Left"), .init("right", title: "Right")]), defaultValue: left)
    public static let length = ActionOption(id: "length", title: "Length", kind: .number(1...1000), defaultValue: "10")
    public static let character = ActionOption(id: "character", title: "Character", kind: .text(maxLength: 1), defaultValue: "0")
    public static let all = [side, length, character]
}

/// The text actions' logic, separate so tests can call it directly.
public enum TextTransforms {
    /// Accepts the URL-safe alphabet, missing padding and line breaks.
    /// Decoded data that is an image becomes an image; otherwise it must be
    /// UTF-8 text.
    public static func base64Decode(_ text: String) throws -> ActionOutput {
        var cleaned = text.filter { !$0.isWhitespace }
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        if cleaned.hasPrefix("data:"), let comma = cleaned.firstIndex(of: ",") {
            cleaned = String(cleaned[cleaned.index(after: comma)...])
        }
        cleaned += String(repeating: "=", count: (4 - cleaned.count % 4) % 4)
        guard let data = Data(base64Encoded: cleaned) else { throw QuickActionError("Not valid Base64") }
        if isImage(data) { return .image(data) }
        guard let decoded = String(data: data, encoding: .utf8) else {
            throw QuickActionError("The decoded data is not text (\(data.count) bytes)")
        }
        return .text(decoded)
    }

    /// PNG and TIFF are what the pasteboard takes.
    static func isImage(_ data: Data) -> Bool {
        data.starts(with: [0x89, 0x50, 0x4E, 0x47]) || data.starts(with: [0x49, 0x49, 0x2A, 0x00])
            || data.starts(with: [0x4D, 0x4D, 0x00, 0x2A])
    }

    /// Everything but RFC 3986's unreserved characters is escaped, so the
    /// result is safe as a query value or a path segment.
    public static func urlEncode(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)..<Unicode.Scalar(128)))
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    /// Joins the lines into one, the way a shell reads a command broken
    /// with backslashes: a line that ends in `\` goes on with the next (an
    /// escaped `\\` does not), and every other line break becomes a space.
    /// Indentation and blank lines go; spaces inside a line stay.
    public static func singleLine(_ text: String) -> String {
        var result = ""
        var continued = false
        for var line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            while line.last?.isWhitespace == true { line.removeLast() }
            let continues = line.reversed().prefix { $0 == "\\" }.count % 2 == 1
            if continues { line.removeLast() }
            if continued, result.last?.isWhitespace == false, line.first?.isWhitespace == false {
                // `--out\` then `put`: the shell reads `--output`.
                result += line
            } else {
                // Only the space before a backslash can trail, and it keeps
                // the next line apart.
                let trimmed = line.drop { $0.isWhitespace }
                while result.last?.isWhitespace == true { result.removeLast() }
                if !result.isEmpty, !trimmed.isEmpty { result += " " }
                result += trimmed
            }
            continued = continues
        }
        while result.last?.isWhitespace == true { result.removeLast() }
        return result
    }

    public static func counts(_ text: String) -> String {
        var words = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in
            words += 1
        }
        let characters = text.count
        let lines = text.isEmpty ? 0 : text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
        return [
            words == 1 ? "1 word" : "\(words) words",
            characters == 1 ? "1 character" : "\(characters) characters",
            lines == 1 ? "1 line" : "\(lines) lines",
        ].joined(separator: " · ")
    }

    /// Pads every line to `length` characters; longer and empty lines stay
    /// as they are, and so do the line breaks.
    public static func pad(_ text: String, to length: Int, with character: Character, left: Bool) -> String {
        var result = ""
        var line = ""
        func flush() {
            let padding = line.isEmpty ? "" : String(repeating: character, count: max(length - line.count, 0))
            result += left ? padding + line : line + padding
            line = ""
        }
        for next in text {
            if next.isNewline {
                flush()
                result.append(next)
            } else {
                line.append(next)
            }
        }
        flush()
        return result
    }

    static let maxTableColumns = 200
    static let maxTableCharacters = 10_000_000

    /// Tab-separated rows (as Numbers, Excel and Google Sheets copy them) as
    /// a Markdown table; the first row is the header. Columns are padded so
    /// the table also reads as plain text.
    public static func markdownTable(fromTSV text: String) throws -> String {
        var rows = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { line in line.split(separator: "\t", omittingEmptySubsequences: false).map { cell($0) } }
        while rows.last?.allSatisfy(\.isEmpty) == true { rows.removeLast() }
        guard !rows.isEmpty, rows.contains(where: { $0.count > 1 }) else {
            throw QuickActionError("No tab-separated columns found")
        }
        let columns = rows.map(\.count).max() ?? 0
        // Every row is padded to every column's width, so the output grows
        // with rows × columns: a few KB of tabs and newlines would become
        // hundreds of MB.
        guard columns <= maxTableColumns else {
            throw QuickActionError("Too many columns for a Markdown table (\(columns); at most \(maxTableColumns))")
        }
        rows = rows.map { $0 + Array(repeating: "", count: columns - $0.count) }
        let widths = (0..<columns).map { column in max(3, rows.map { $0[column].count }.max() ?? 0) }
        let lineLength = widths.reduce(0, +) + 3 * columns + 1
        guard lineLength * (rows.count + 1) <= maxTableCharacters else {
            throw QuickActionError("The table would be too large (over \(maxTableCharacters / 1_000_000) million characters)")
        }

        func line(_ cells: [String]) -> String {
            "| " + zip(cells, widths).map { $0 + String(repeating: " ", count: $1 - $0.count) }.joined(separator: " | ") + " |"
        }
        var lines = [line(rows[0]), "| " + widths.map { String(repeating: "-", count: $0) }.joined(separator: " | ") + " |"]
        lines += rows.dropFirst().map(line)
        return lines.joined(separator: "\n")
    }

    /// Pipes would end the cell; spreadsheets quote cells with line breaks.
    private static func cell(_ raw: Substring) -> String {
        var value = raw.trimmingCharacters(in: .whitespaces)
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast()).replacingOccurrences(of: "\"\"", with: "\"")
        }
        return value.replacingOccurrences(of: "|", with: "\\|")
    }

    /// Local time with its offset, to the second: `2026-10-19T14:05:09+02:00`.
    public static func isoDate(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
        return formatter.string(from: date)
    }
}
