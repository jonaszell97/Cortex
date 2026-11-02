import Foundation

/// A command whose name an earlier one already has.
public struct CommandProblem: Sendable, Equatable {
    /// The command left out.
    public var id: String
    public var message: String

    public init(id: String, message: String) {
        self.id = id
        self.message = message
    }
}

public enum CommandCatalog {
    /// The built-in commands: `$kill node`, `$port 3000`,
    /// `$disk Macintosh HD`, `$mem`, `$open ~/Downloads`,
    /// `$code cortex`, `$term cortex`, `$clip`, `$sound airhorn`, `$uuid`, `$token 32`.
    public static var builtIns: [any Command] {
        #if os(macOS)
        [KillCommand(), PortCommand(), DiskSpaceCommand(), MemoryUsageCommand(), CPUUsageCommand(), GPUUsageCommand(), OpenCommand(), CodeCommand(), TermCommand(), ClipCommand(), SoundCommand(), UUIDCommand(), TokenCommand()]
        #else
        []
        #endif
    }

    /// The commands for `query`: the one it names first, then the others
    /// matching the word (or the whole text, when it names none) like
    /// `ActionCatalog.rank`. Without a query, the most used first, then in
    /// catalog order.
    public static func rank(
        _ commands: [any Command], for query: CommandQuery, usage: [String: ActionUsage] = [:]
    ) -> [any Command] {
        let ranked = ActionCatalog.rank(commands, query: query.search, usage: usage) { command in
            ActionCatalog.Searchable(id: command.id, title: command.title, keywords: command.keywords, name: command.name)
        }
        guard query.isNamed else { return ranked }
        let word = SnippetSearch.fold(query.word)
        let isNamed = { (command: any Command) in SnippetSearch.fold(command.name) == word }
        return ranked.filter(isNamed) + ranked.filter { !isNamed($0) }
    }

    /// Each command whose name (folded) an earlier one already has: it
    /// cannot be typed, so it is left out and reported.
    public static func problems(in commands: [any Command]) -> [CommandProblem] {
        var named: [String: any Command] = [:]
        var problems: [CommandProblem] = []
        for command in commands {
            let folded = SnippetSearch.fold(command.name)
            guard let earlier = named[folded] else {
                named[folded] = command
                continue
            }
            let owner = (earlier as? UserCommand).map { "already the trigger of \($0.file.lastPathComponent)" }
                ?? "the name of a built-in command"
            problems.append(CommandProblem(id: command.id, message: "“\(command.name)” is \(owner)"))
        }
        return problems
    }
}
