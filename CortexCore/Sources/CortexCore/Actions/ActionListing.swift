import Foundation

public extension ActionInput {
    /// Typed text as a command's main input (docs/modules/COMMANDS.md, "The
    /// command protocol"): one or more paths to existing files or folders
    /// (absolute or starting with `~/`, shell-style quotes or backslashes around
    /// spaces) are `.files`; anything else is `.text`, and nothing is `.none`. A
    /// single path with spaces needs no quotes when it exists as written (a
    /// copied path). A `\` before paths keeps them text. Images cannot be typed.
    static func typed(
        _ text: String,
        home: URL = URL.homeDirectory,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> ActionInput {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .none }
        if trimmed.hasPrefix("\\") {
            let rest = String(trimmed.dropFirst())
            if case .files = typed(rest, home: home, fileExists: fileExists) { return .text(rest) }
            return .text(trimmed)
        }
        func existing(_ word: String) -> URL? {
            let path: String
            if word.hasPrefix("/") {
                path = word
            } else if word.hasPrefix("~/") {
                path = home.appending(path: String(word.dropFirst(2))).path
            } else {
                return nil
            }
            return fileExists(path) ? URL(filePath: path) : nil
        }
        if trimmed.contains(where: \.isWhitespace), let url = existing(trimmed) { return .files([url]) }
        guard let words = ShellWords.split(trimmed), !words.isEmpty else { return .text(trimmed) }
        var urls: [URL] = []
        for word in words {
            guard let url = existing(word) else { return .text(trimmed) }
            urls.append(url)
        }
        return .files(urls)
    }
}

public extension ActionInput {
    /// Whether typed text starts like a path: `/` or `~/`, also after an
    /// opening quote (a dropped file whose name needs quoting).
    static func startsLikePath(_ text: String) -> Bool {
        let unquoted = text.first == "'" || text.first == "\"" ? text.dropFirst() : Substring(text)
        return unquoted.hasPrefix("/") || unquoted.hasPrefix("~/")
    }
}

/// Splitting typed text into words as a shell would: whitespace separates,
/// single and double quotes group, a backslash escapes the next character.
enum ShellWords {
    /// nil when a quote is left open.
    static func split(_ text: String) -> [String]? {
        var words: [String] = []
        var current = ""
        var inWord = false
        var quote: Character?
        var escaped = false
        for character in text {
            if escaped {
                current.append(character)
                escaped = false
                inWord = true
            } else if let open = quote {
                if character == open {
                    quote = nil
                } else if character == "\\" && open == "\"" {
                    escaped = true
                } else {
                    current.append(character)
                }
            } else if character == "\\" {
                escaped = true
            } else if character == "'" || character == "\"" {
                quote = character
                inWord = true
            } else if character.isWhitespace {
                if inWord { words.append(current) }
                current = ""
                inWord = false
            } else {
                current.append(character)
                inWord = true
            }
        }
        guard quote == nil, !escaped else { return nil }
        if inWord { words.append(current) }
        return words
    }
}

/// What `>` lists (docs/modules/COMMANDS.md, "What `>` loses"): the actions that
/// take the input and are meant for it (`matches`). What is typed after `>` only
/// searches.
public enum ActionListing: Sendable, Equatable {
    /// What the palette found: the clipboard or the Finder selection.
    case context(ActionInput)
    /// An input handed in: a clip, dropped files, the selection, Services.
    case handedIn(ActionInput)

    public var input: ActionInput {
        switch self {
        case .context(let input), .handedIn(let input): input
        }
    }
}

public extension ActionCatalog {
    /// The actions for `query` on the listing's input, ranked like `rank`.
    static func list(
        _ actions: [any QuickAction], query: String, for listing: ActionListing, usage: [String: ActionUsage] = [:]
    ) -> [any QuickAction] {
        let input = listing.input
        return rank(actions.filter { $0.matches(input) && $0.accepts(input) }, query: query, usage: usage)
    }
}
