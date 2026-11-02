import Foundation
import Testing
@testable import CortexCore

/// `$` commands from action files with a `trigger`.
@Suite struct UserCommandTests {
    func command(_ toml: String) throws -> UserCommand {
        UserCommand(definition: try UserActionDefinition.parse(toml), file: URL(filePath: "/tmp/cmd.toml"))
    }

    func context() -> ActionContext {
        ActionContext(fallbackOutputDirectory: FileManager.default.temporaryDirectory,
                      temporaryDirectory: FileManager.default.temporaryDirectory)
    }

    @Test func aQuicklinkIsPreviewedAndOpened() async throws {
        let gh = try command("name = 'GitHub'\ntrigger = 'gh'\nurl = 'https://github.com/{argument}'\nexample = 'owner/repo'")
        #expect(gh.id == "user.cmd")
        #expect(gh.name == "gh")
        #expect(gh.usage == "gh owner/repo")
        #expect(gh.symbol == "link")
        #expect(!gh.matches(.text("apple/swift")), "never offered in >")
        #expect(!gh.accepts(.none))
        #expect(!gh.accepts(.files([URL(filePath: "/tmp")])))
        #expect(try await gh.resolve(.text("apple/swift")) == .open(.url(URL(string: "https://github.com/apple/swift")!)))
        #expect(try await gh.output(.text("apple/swift"), context: context()) == .open(URL(string: "https://github.com/apple/swift")!))
    }

    @Test func theArgumentIsEncodedIntoTheURL() async throws {
        let search = try command("name = 'Google'\ntrigger = 'g'\nurl = 'https://www.google.com/search?q={argument}'")
        #expect(try await search.resolve(.text("swift async & let=1#x"))
            == .open(.url(URL(string: "https://www.google.com/search?q=swift%20async%20%26%20let%3D1%23x")!)))
        #expect(search.usage == "g …")
    }

    @Test func theArgumentFollowsTheFile() throws {
        let gh = try command("name = 'GitHub'\ntrigger = 'gh'\nurl = 'https://github.com/{argument}'\nexample = 'owner/repo'\nmatches = '^[\\w-]+/[\\w.-]+$'")
        #expect(gh.argument == CommandArgument(
            title: "Argument", placeholder: "owner/repo", kind: .text, isRequired: true, suggestions: .clips(matching: #"^[\w-]+/[\w.-]+$"#)))
        let deploy = try command("name = 'Deploy'\ntrigger = 'deploy'\ncommand = 'deploy.sh {argument}'\nargument = 'optional'")
        #expect(deploy.argument?.isRequired == false)
        #expect(deploy.argument?.suggestions == CommandSuggestions.none)
        #expect(deploy.accepts(.none) && deploy.accepts(.text("staging")))
        let lock = try command("name = 'Lock'\ntrigger = 'lock'\ncommand = 'pmset displaysleepnow'")
        #expect(lock.argument == nil)
        #expect(lock.usage == "lock")
        #expect(lock.accepts(.none))
        let open = try command("name = 'Open'\ntrigger = 'o'\naccepts = ['files']\ncommand = 'open {input}'")
        #expect(open.argument?.kind == .path)
        #expect(open.input(typed: "/") == .files([URL(filePath: "/")]))
        #expect(open.input(typed: "/does/not/exist") == .text("/does/not/exist"))
        #expect(!open.accepts(.text("/does/not/exist")), "⏎ beeps on a path that is not there")
    }

    @Test func aShellCommandIsAJobThatShowsTheLine() async throws {
        let say = try command("name = 'Say'\ntrigger = 'say'\ncommand = 'say {argument}'")
        #expect(say.symbol == "terminal")
        let outcome = try await say.resolve(.text("it's me"))
        #expect(outcome == .job(plan: #"say 'it'\''s me'"#, run: { _ in .handled }), "nothing has run")
        #expect(outcome.kind == .job)
    }

    @Test func runsAndPastesOrNotifies() async throws {
        let echo = try command("name = 'Echo'\ntrigger = 'echo'\ncommand = 'echo {argument}; echo \"[$1]\"'\noutput = 'text'")
        #expect(try await echo.output(.text("a  b"), context: context()) == .text("a  b\n[a  b]"), "the output is pasted")
        let quiet = try command("name = 'Quiet'\ntrigger = 'quiet'\ncommand = 'true'")
        #expect(try await quiet.output(.none, context: context()) == .done("Done"))
        let talk = try command("name = 'Talk'\ntrigger = 'talk'\ncommand = 'echo deployed'")
        #expect(try await talk.output(.text("ignored"), context: context()) == .done("deployed"), "no {argument}: the text is not used")
        #expect(talk.accepts(.none))
        #expect(!talk.accepts(.text("x")), "it takes no argument")
    }

    @Test func failuresSayWhy() async throws {
        let fail = try command("name = 'Fail'\ntrigger = 'fail'\ncommand = 'echo nope >&2; exit 3'")
        await #expect(throws: QuickActionError("Fail failed (exit 3): nope")) { try await fail.output(.none, context: context()) }
    }

    @Test func confirmedCommandsAskFirst() async throws {
        let directory = try temporaryDirectory()
        let marker = directory.appending(path: "ran")
        let touch = try command("""
            name = "Touch"
            trigger = "touch"
            command = "touch \(marker.path)-{argument}"
            argument = "optional"
            confirm = true
            """)
        guard case .act(let confirmation) = try await touch.resolve(.text("x")) else {
            Issue.record("expected a question")
            return
        }
        #expect(confirmation.title == "Run Touch?")
        #expect(confirmation.message == "touch \(marker.path)-'x'")
        #expect(confirmation.confirmTitle == "Run")
        #expect(!FileManager.default.fileExists(atPath: marker.path + "-x"), "nothing ran yet")
        #expect(try await confirmation.perform() == .done("Done"))
        #expect(FileManager.default.fileExists(atPath: marker.path + "-x"))

        let link = try command("name = 'Docs'\ntrigger = 'docs'\nurl = 'https://example.com'\nconfirm = true")
        guard case .act(let open) = try await link.resolve(.none) else {
            Issue.record("expected a question")
            return
        }
        #expect(open.title == "Open Docs?")
        #expect(try await open.perform() == .open(URL(string: "https://example.com")!))
    }

    @Test func aFileThatIsAlsoAnActionRunsAsOne() async throws {
        let shout = try command("name = 'Shout'\ntrigger = 'shout'\naccepts = ['text']\ncommand = 'tr a-z A-Z'")
        #expect(shout.name == "shout")
        guard case .job(let plan, _) = try await shout.resolve(.text("hi")) else {
            Issue.record("expected a job")
            return
        }
        #expect(plan == "tr a-z A-Z", "it runs on the text as a file and on standard input")
        #expect(try await shout.output(.text("hello"), context: context()) == .text("HELLO"))
    }

    @Test func aConfirmedFileThatIsAlsoAnActionAsksOnceAndRunsWithItsOwnScratchSpace() async throws {
        let shout = try command("name = 'Shout'\ntrigger = 'shout'\naccepts = ['text']\ncommand = 'tr a-z A-Z'\nconfirm = true")
        guard case .act(let confirmation) = try await shout.resolve(.text("hi")) else {
            Issue.record("expected a question")
            return
        }
        #expect(confirmation.title == "Run Shout?" && confirmation.message == "tr a-z A-Z")
        #expect(try await confirmation.perform() == .text("HI"), "no second question")
    }

    @Test func aCommandThatIsOnlyAnActionHasNoOutcomeBeforeItIsAsked() async throws {
        let open = try command("name = 'Open'\ntrigger = 'o'\naccepts = ['files']\ncommand = 'open {input}'")
        guard case .job(let plan, _) = try await open.resolve(.files([URL(filePath: "/tmp")])) else {
            Issue.record("expected a job")
            return
        }
        #expect(plan == "open {input}", "the placeholder stays: it is filled in per file")
    }

    @Test func rankedWithTheBuiltIns() throws {
        let gh = try command("name = 'GitHub Repository'\ntrigger = 'gh'\nurl = 'https://github.com/{argument}'")
        let commands = CommandCatalog.builtIns + [gh]
        let names = Set(commands.map { SnippetSearch.fold($0.name) })
        let ranked = CommandCatalog.rank(commands, for: CommandQuery("gh apple/swift", names: names))
        #expect(ranked.first?.id == "user.cmd")
    }
}

@Suite struct UserCommandLibraryTests {
    @Test func commandsAndActionsLoadFromTheSameFolder() throws {
        let directory = try temporaryDirectory()
        try "name = 'Upper'\naccepts = ['text']\ncommand = 'tr a-z A-Z'".write(to: directory.appending(path: "upper.toml"), atomically: true, encoding: .utf8)
        try "name = 'GitHub'\ntrigger = 'gh'\nurl = 'https://github.com/{argument}'".write(to: directory.appending(path: "gh.toml"), atomically: true, encoding: .utf8)
        try "name = 'Shout'\ntrigger = 'shout'\naccepts = ['text']\ncommand = 'tr a-z A-Z'".write(to: directory.appending(path: "shout.toml"), atomically: true, encoding: .utf8)

        let contents = UserActionLibrary.load(from: directory)
        #expect(contents.actions.map(\.title) == ["Shout", "Upper"])
        #expect(contents.commands.map(\.title) == ["GitHub", "Shout"], "a file with both is in both")
        #expect(contents.problems.isEmpty)
    }

    @Test func namesAreUniqueAmongAllCommands() throws {
        let directory = try temporaryDirectory()
        try "name = 'GitHub'\ntrigger = 'gh'\nurl = 'https://github.com/{argument}'".write(to: directory.appending(path: "gh.toml"), atomically: true, encoding: .utf8)
        try "name = 'Again'\ntrigger = 'GH'\nurl = 'https://x'".write(to: directory.appending(path: "gh2.toml"), atomically: true, encoding: .utf8)
        try "name = 'Mine'\ntrigger = 'kill'\naccepts = ['text']\ncommand = 'true'".write(to: directory.appending(path: "kill.toml"), atomically: true, encoding: .utf8)

        let contents = UserActionLibrary.load(from: directory)
        #expect(contents.commands.map(\.title) == ["GitHub"])
        #expect(contents.actions.isEmpty, "a file with a problem is skipped whole")
        #expect(contents.problems.map(\.message) == [
            "“GH” is already the trigger of gh.toml",
            "“kill” is the name of a built-in command",
        ])

        #expect(UserActionLibrary.load(from: directory, reserved: []).problems.count == 1,
                "reserved: the built-ins by default, and contributed commands")
    }
}
