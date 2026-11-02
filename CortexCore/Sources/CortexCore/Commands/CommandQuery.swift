import Foundation

/// What is typed after `$` (docs/modules/COMMANDS.md, "Reading the query"), split
/// at the first whitespace into a word and, if anything follows, an argument.
/// Only a word that is exactly a command's name (folded like snippet keywords)
/// makes the rest an argument: `port 3000`. Otherwise the whole text searches
/// names, titles and keywords, and `kil node` matches nothing.
///
/// For a command that runs on hosts, a word `@pi` anywhere in the rest names
/// the host (`mem @pi`, `disk /mnt/usb @pi`) and is not part of the
/// argument.
public struct CommandQuery: Sendable, Equatable {
    /// The first word, as typed.
    public var word: String
    /// What follows the word, trimmed, without the `@host` words, when the
    /// word is a command's name and something follows; nil otherwise.
    public var argument: String?
    /// The `@host` words after the name, in order, without the `@`: `["pi"]`
    /// for `mem @pi`, `[""]` for a bare `@`. Whether they name hosts is
    /// for `Machine.named(by:in:)` to say.
    public var hosts: [String]
    /// The word is exactly a command's name.
    public var isNamed: Bool
    /// What the list is ranked by: the word when it names a command,
    /// otherwise the whole text.
    public var search: String

    public init(word: String, argument: String?, hosts: [String] = [], isNamed: Bool, search: String) {
        self.word = word
        self.argument = argument
        self.hosts = hosts
        self.isNamed = isNamed
        self.search = search
    }

    /// `names` are folded (`SnippetSearch.fold`), like the typed word;
    /// `hostNames` are those of the names that run on hosts.
    public init(_ text: String, names: Set<String>, hostNames: Set<String> = []) {
        let trimmed = text.drop { $0.isWhitespace }
        let word = String(trimmed.prefix { !$0.isWhitespace })
        var rest = trimmed.dropFirst(word.count).trimmingCharacters(in: .whitespaces)
        self.word = word
        isNamed = !word.isEmpty && names.contains(SnippetSearch.fold(word))
        hosts = []
        if isNamed, hostNames.contains(SnippetSearch.fold(word)) {
            (rest, hosts) = Self.takeHosts(from: rest)
        }
        argument = isNamed && !rest.isEmpty ? rest : nil
        search = isNamed ? word : text
    }

    /// `text` without its whitespace-separated words that start with `@`,
    /// and those words without the `@`. The spacing of what is left is kept.
    private static func takeHosts(from text: String) -> (rest: String, hosts: [String]) {
        var rest = ""
        var hosts: [String] = []
        // The first whitespace after the last word kept, written once the
        // next one is.
        var gap: Substring?
        var index = text.startIndex
        while index < text.endIndex {
            let isSpace = text[index].isWhitespace
            let end = text[index...].firstIndex { $0.isWhitespace != isSpace } ?? text.endIndex
            let chunk = text[index..<end]
            index = end
            if isSpace {
                gap = gap ?? chunk
            } else if chunk.hasPrefix("@") {
                hosts.append(String(chunk.dropFirst()))
            } else {
                if !rest.isEmpty { rest += gap ?? "" }
                rest += chunk
                gap = nil
            }
        }
        return (rest, hosts)
    }
}
