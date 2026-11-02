import Foundation

/// A value a `$` form offers for its argument (docs/modules/COMMANDS.md,
/// "Suggestions"): the clipboard, a recent clip or one of the argument's choices.
/// Picking one only puts its value into the field; nothing runs on a suggestion.
public struct CommandSuggestion: Sendable, Equatable, Identifiable {
    public enum Source: Sendable, Equatable {
        /// On the pasteboard now.
        case clipboard
        /// A clip from the history, last copied then.
        case history(Date)
        /// One of a `.choice` argument's choices.
        case choice
    }

    /// What goes into the field.
    public var value: String
    public var source: Source

    public var id: String { value }

    public init(_ value: String, source: Source) {
        self.value = value
        self.source = source
    }

    /// At most this many clips are suggested.
    public static let clipLimit = 5

    /// `.clips(matching:)`: the pasteboard's text, then the history's,
    /// each whose trimmed text matches `pattern`, newest first, without
    /// duplicates. The history's newest clip is the pasteboard when it has
    /// the same text. For a number argument the value is the number in the
    /// clip (`:3000` is 3000).
    public static func clips(
        pasteboard: String?, history: [RecentClipText], matching pattern: String, for kind: CommandArgument.Kind,
        limit: Int = clipLimit
    ) -> [CommandSuggestion] {
        guard let regex = try? Regex(pattern) else { return [] }
        let candidates = [pasteboard.map { (text: $0, source: Source.clipboard) }].compactMap { $0 }
            + history.map { (text: $0.text, source: Source.history($0.copiedAt)) }
        var suggestions: [CommandSuggestion] = []
        for candidate in candidates where suggestions.count < limit {
            let trimmed = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, (try? regex.firstMatch(in: trimmed)) != nil else { continue }
            let value: String
            if case .number = kind {
                guard let number = Self.number(in: trimmed) else { continue }
                value = String(number)
            } else {
                value = trimmed
            }
            guard !suggestions.contains(where: { $0.value == value }) else { continue }
            suggestions.append(CommandSuggestion(value, source: candidate.source))
        }
        return suggestions
    }

    /// `.clipboardText`: the pasteboard's text as one entry.
    public static func clipboardText(_ pasteboard: String?) -> [CommandSuggestion] {
        guard let pasteboard, !pasteboard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return [CommandSuggestion(pasteboard, source: .clipboard)]
    }

    /// `.choices`: the choices by title, which is what the field shows.
    public static func choices(_ choices: [ActionOption.Choice]) -> [CommandSuggestion] {
        choices.map { CommandSuggestion($0.title, source: .choice) }
    }

    /// The suggestions whose value contains `typed` (ignoring case and
    /// diacritics); all of them while nothing is typed.
    public static func filter(_ suggestions: [CommandSuggestion], by typed: String) -> [CommandSuggestion] {
        let typed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return suggestions }
        return suggestions.filter { $0.value.range(of: typed, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    /// The digits of `3000` or `:3000`, as a number.
    private static func number(in text: String) -> Int? {
        let digits = text.drop { !$0.isASCII || !$0.isNumber }.prefix { $0.isASCII && $0.isNumber }
        return Int(digits)
    }
}

public extension CommandArgument {
    /// Why a form's argument cannot run yet.
    enum Problem: Error, Sendable, Equatable {
        /// A required field is empty: ⏎ marks it.
        case missing
        /// Shown in red under the fields.
        case invalid(String)
    }

    /// What the form's field holds as the command's input
    /// (docs/modules/COMMANDS.md, "The form"): a whole number in range, one or
    /// more existing files or folders (`~/` allowed, shell-style quoting), one of
    /// `choices` by title or value (case-insensitively; its value) or, where the
    /// choices allow it, one existing file or folder (as typed), otherwise the
    /// text. An empty field is `.none` when the argument is optional.
    func input(
        from text: String, choices: [ActionOption.Choice]? = nil,
        home: URL = URL.homeDirectory,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Result<ActionInput, Problem> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return isRequired ? .failure(.missing) : .success(.none) }
        switch kind {
        case .text, .prompt:
            return .success(.text(trimmed))
        case .number(let range):
            guard trimmed.allSatisfy(\.isASCII), let number = Int(trimmed), range.contains(number) else {
                return .failure(.invalid("\(title): a whole number from \(range.lowerBound) to \(range.upperBound)"))
            }
            return .success(.text(String(number)))
        case .path:
            let input = ActionInput.typed(trimmed, home: home, fileExists: fileExists)
            guard case .files = input else {
                return .failure(.invalid("\(title): no file or folder at \(trimmed)"))
            }
            return .success(input)
        case .choice(let source):
            if source.allowsPaths, ActionInput.startsLikePath(trimmed) {
                guard case .files(let urls) = ActionInput.typed(trimmed, home: home, fileExists: fileExists), urls.count == 1 else {
                    return .failure(.invalid("\(title): no file or folder at \(trimmed)"))
                }
                return .success(.text(trimmed))
            }
            guard let choices else { return .failure(.invalid("\(title): the list is still loading")) }
            guard let match = CommandChoices.match(trimmed, in: choices) else { return .failure(.invalid("\(title): “\(trimmed)” is not in the list")) }
            return .success(.text(match.value))
        }
    }
}
