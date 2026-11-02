import Foundation

/// A naming convention of identifiers: "To Snake Case" and its siblings.
public enum CaseStyle: CaseIterable, Sendable {
    case snake, camel, pascal, kebab, constant

    public var id: String {
        switch self {
        case .snake: "text.case.snake"
        case .camel: "text.case.camel"
        case .pascal: "text.case.pascal"
        case .kebab: "text.case.kebab"
        case .constant: "text.case.constant"
        }
    }

    public var title: String {
        switch self {
        case .snake: "To Snake Case"
        case .camel: "To Camel Case"
        case .pascal: "To Pascal Case"
        case .kebab: "To Kebab Case"
        case .constant: "To Constant Case"
        }
    }

    public var keywords: [String] {
        switch self {
        case .snake: ["snake_case", "underscore", "identifier", "variable", "rename", "convert"]
        case .camel: ["camelCase", "lower camel", "identifier", "variable", "rename", "convert"]
        case .pascal: ["PascalCase", "UpperCamelCase", "class", "type", "identifier", "rename", "convert"]
        case .kebab: ["kebab-case", "dash", "hyphen", "slug", "css", "identifier", "rename", "convert"]
        case .constant: ["CONSTANT_CASE", "SCREAMING_SNAKE_CASE", "MACRO_CASE", "environment", "env", "identifier", "rename", "convert"]
        }
    }

    /// Joins the words (any case) in this style.
    func join(_ words: [Substring]) -> String {
        switch self {
        case .snake: words.map { $0.lowercased() }.joined(separator: "_")
        case .kebab: words.map { $0.lowercased() }.joined(separator: "-")
        case .constant: words.map { $0.uppercased() }.joined(separator: "_")
        case .pascal: words.map(Self.capitalized).joined()
        case .camel: words.enumerated().map { $0 == 0 ? $1.lowercased() : Self.capitalized($1) }.joined()
        }
    }

    private static func capitalized(_ word: Substring) -> String {
        word.prefix(1).uppercased() + word.dropFirst().lowercased()
    }
}

public extension TextAction {
    /// One action per `CaseStyle`.
    static let caseConversions: [TextAction] = CaseStyle.allCases.map { style in
        TextAction(id: style.id, title: style.title, symbol: "textformat.abc", keywords: style.keywords) {
            .text(try CaseConversion.convert($0, to: style))
        }
    }
}

public enum CaseConversion {
    /// Rewrites every line in `style`, whatever case it was in: `fooBar`,
    /// `foo_bar`, `Foo-Bar`, `FOO BAR` and `foo.bar` all hold the words foo
    /// and bar. Words split at anything that is not a letter or digit, at a
    /// small letter or digit followed by a capital (`fooBar`, `v2Beta`) and
    /// before the last capital of an acronym (`HTTPServer` is HTTP and
    /// Server). Line breaks, indentation and the underscores around a
    /// name (`_private`, `__init__`) stay; a line without words is left empty.
    public static func convert(_ text: String, to style: CaseStyle) throws -> String {
        var foundWords = false
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let converted = lines.map { line -> String in
            let indentation = line.prefix { $0.isWhitespace }
            let rest = line.dropFirst(indentation.count)
            let underscores = rest.prefix { $0 == "_" }
            let body = rest.dropFirst(underscores.count)
            let trailing = body.reversed().prefix { $0 == "_" }.count
            let words = words(in: body.dropLast(trailing))
            guard !words.isEmpty else { return "" }
            foundWords = true
            return indentation + underscores + style.join(words) + String(repeating: "_", count: trailing)
        }
        guard foundWords else { throw QuickActionError("No words found") }
        // `split` drops the line breaks; they are read back from the text.
        var result = ""
        var breaks = text.filter(\.isNewline).makeIterator()
        for (index, line) in converted.enumerated() {
            result += line
            if index < converted.count - 1, let lineBreak = breaks.next() { result.append(lineBreak) }
        }
        return result
    }

    static func words(in text: Substring) -> [Substring] {
        var words: [Substring] = []
        var start: Substring.Index?
        var previous: Character?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            guard character.isLetter || character.isNumber else {
                if let start { words.append(text[start..<index]) }
                start = nil
                previous = nil
                index = next
                continue
            }
            if let startIndex = start, let previous, character.isUppercase {
                let followedBySmall = next < text.endIndex && text[next].isLowercase
                if !previous.isUppercase || followedBySmall {
                    words.append(text[startIndex..<index])
                    start = index
                }
            }
            if start == nil { start = index }
            previous = character
            index = next
        }
        if let start { words.append(text[start...]) }
        return words
    }
}
