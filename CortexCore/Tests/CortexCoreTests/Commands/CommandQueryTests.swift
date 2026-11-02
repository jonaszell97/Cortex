import Foundation
import Testing
@testable import CortexCore

/// Reading what is typed after `$`, and ranking the commands for it.
@Suite struct CommandQueryTests {
    let names: Set<String> = ["port", "kill", "gh", "mem", "disk"]
    /// The names that run on hosts.
    let hostNames: Set<String> = ["mem", "disk"]

    func query(_ text: String) -> CommandQuery {
        CommandQuery(text, names: names, hostNames: hostNames)
    }

    @Test func anExactNameTakesWhatFollowsAsItsArgument() {
        #expect(query("port 3000") == CommandQuery(word: "port", argument: "3000", isNamed: true, search: "port"))
        #expect(query("  port   3000 ").argument == "3000")
        #expect(query("gh a b").argument == "a b", "the rest is one argument")
        #expect(query("PORT 1").isNamed, "folded like search")
        #expect(query("PORT 1").word == "PORT")
    }

    @Test func aNameAloneHasNoArgument() {
        #expect(query("port") == CommandQuery(word: "port", argument: nil, isNamed: true, search: "port"))
        #expect(query("port   ").argument == nil)
        #expect(query("mem").isNamed)
    }

    @Test func otherwiseTheWholeTextSearches() {
        #expect(query("po") == CommandQuery(word: "po", argument: nil, isNamed: false, search: "po"))
        #expect(query("kil node") == CommandQuery(word: "kil", argument: nil, isNamed: false, search: "kil node"))
        #expect(query("ports 3000").isNamed == false, "only the exact word")
        #expect(query("") == CommandQuery(word: "", argument: nil, isNamed: false, search: ""))
    }

    @Test func aWordWithAtNamesTheHostOfACommandThatRunsOnHosts() {
        #expect(query("mem @pi") == CommandQuery(word: "mem", argument: nil, hosts: ["pi"], isNamed: true, search: "mem"))
        #expect(query("disk /mnt/usb @pi") == CommandQuery(
            word: "disk", argument: "/mnt/usb", hosts: ["pi"], isNamed: true, search: "disk"))
        #expect(query("disk @pi /mnt/usb").argument == "/mnt/usb", "anywhere after the name")
        #expect(query("disk  @pi  ").argument == nil)
        #expect(query("DISK Macintosh HD @Pi").hosts == ["Pi"], "as typed")
        #expect(query("disk Macintosh HD @pi").argument == "Macintosh HD")
        #expect(query("disk My   Disk  @pi  x").argument == "My   Disk  x", "the spacing of the rest is kept")
    }

    @Test func onlyAWholeWordStartingWithAtIsAHost() {
        #expect(query("disk a@b.com").hosts.isEmpty && query("disk a@b.com").argument == "a@b.com")
        #expect(query("disk /mnt/@pi").hosts.isEmpty)
        #expect(query("mem @").hosts == [""], "a bare @ names no host")
        #expect(query("mem @pi @nas").hosts == ["pi", "nas"], "the scope says one at a time")
        #expect(query("mem@pi").isNamed == false)
    }

    @Test func otherCommandsKeepAtWordsInTheirArgument() {
        #expect(query("gh @pi") == CommandQuery(word: "gh", argument: "@pi", isNamed: true, search: "gh"))
        #expect(query("kill node @pi").argument == "node @pi")
        #expect(query("me @pi").hosts.isEmpty, "a search is not parsed")
        #expect(CommandQuery("mem @pi", names: names).hosts.isEmpty, "unless it is told which names run on hosts")
    }

    // MARK: - Ranking

    struct Fake: Command {
        let id: String
        let name: String
        let title: String
        let symbol = "circle"
        var keywords: [String] = []
        func resolve(_ invocation: CommandInvocation) async throws -> CommandOutcome { .value(.text("")) }
    }

    let commands: [any Command] = [
        Fake(id: "kill", name: "kill", title: "Kill Process", keywords: ["process"]),
        Fake(id: "port", name: "port", title: "Kill Process on Port", keywords: ["kill", "process"]),
        Fake(id: "mem", name: "mem", title: "Memory Usage"),
    ]

    func rank(_ text: String, usage: [String: ActionUsage] = [:]) -> [String] {
        let names = Set(commands.map { SnippetSearch.fold($0.name) })
        return CommandCatalog.rank(commands, for: CommandQuery(text, names: names), usage: usage).map(\.id)
    }

    @Test func everyCommandByUsageThenCatalogOrder() {
        #expect(rank("") == ["kill", "port", "mem"])
        #expect(rank("", usage: ["mem": ActionUsage(count: 2)]) == ["mem", "kill", "port"])
    }

    @Test func theNamedCommandComesFirst() {
        #expect(rank("kill node") == ["kill", "port"], "Kill Process on Port has the keyword too")
        #expect(rank("port") == ["port"])
        #expect(rank("port 3000", usage: ["kill": ActionUsage(count: 9)]) == ["port"])
    }

    @Test func aPartialWordSearchesNamesTitlesAndKeywords() {
        #expect(rank("por") == ["port"])
        #expect(rank("mem") == ["mem"])
        #expect(rank("proc") == ["kill", "port"])
        #expect(rank("kil node").isEmpty, "the rest is part of the search")
    }

    @Test func aNameGivenTwiceIsAProblem() {
        let user = UserCommand(
            definition: UserActionDefinition(name: "Mine", target: .shell("true"), accepts: [.none], takesContext: false, trigger: "Kill"),
            file: URL(filePath: "/tmp/kill.toml"))
        let again = UserCommand(
            definition: UserActionDefinition(name: "Again", target: .shell("true"), accepts: [.none], takesContext: false, trigger: "kill"),
            file: URL(filePath: "/tmp/again.toml"))
        #expect(CommandCatalog.problems(in: commands + [user]) == [
            CommandProblem(id: "user.kill", message: "“Kill” is the name of a built-in command"),
        ])
        #expect(CommandCatalog.problems(in: [user, again]) == [
            CommandProblem(id: "user.again", message: "“kill” is already the trigger of kill.toml"),
        ])
    }
}
