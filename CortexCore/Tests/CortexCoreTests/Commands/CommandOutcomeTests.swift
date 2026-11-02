import Foundation
import Testing
@testable import CortexCore

/// What ⏎ does for a command (docs/modules/COMMANDS.md, "The command
/// protocol"): the outcome each one resolves to, and the adapter that carries
/// it out as a quick action.
@Suite struct CommandOutcomeTests {
    func context(options: ActionOptionValues = ActionOptionValues(), machine: Machine = .local) -> ActionContext {
        ActionContext(
            fallbackOutputDirectory: URL(filePath: "/tmp"), temporaryDirectory: URL(filePath: "/tmp"), options: options, machine: machine)
    }

    // MARK: - Each built-in has its outcome

    @Test func everyBuiltInResolvesToItsKind() async throws {
        let pi = Machine.ssh("pi")
        let linuxHost = CannedHosts { _, script in
            if script.contains("uid=$(id -u)") { return ProcessToolsTests.linuxOwn }
            if script.contains("/proc/meminfo") { return "@@ system\nLinux\n@@ meminfo\nMemTotal: 1000 kB\nMemFree: 500 kB\n@@ ps\n    1     0  9000 systemd\n" }
            return HostCommandTests.piPort()
        }
        let startup = VolumeSpace(name: "Macintosh HD", path: "/", total: 1_000_000, available: 400_000)
        let folder = FileManager.default.temporaryDirectory.path(percentEncoded: false)
        let existing: Set<String> = [folder, "/Applications/Terminal.app", "/s/airhorn.mp4"]
        let terminal = TermCommand(
            folders: { TerminalFolders.Contents(app: "/Applications/Terminal.app", folders: []) },
            home: URL(filePath: "/Users/me"), fileExists: { existing.contains($0) }, isDirectory: { _ in true })
        let sound = SoundCommand(
            library: { SoundLibrary.Contents(folder: URL(filePath: "/s"), sounds: [Sound(name: "airhorn", file: URL(filePath: "/s/airhorn.mp4"))]) },
            fileExists: { existing.contains($0) })
        let code = CodeCommand(
            projects: { [FolderShortcut(name: "cortex", location: .local("/Users/me/Developer/Cortex"))] }, home: URL(filePath: "/Users/me"))

        let expected: [(any Command, ActionInput, Machine, CommandOutcome.Kind)] = [
            (KillCommand(shell: linuxHost.shell), .text("node"), pi, .act),
            (PortCommand(shell: linuxHost.shell), .text("3000"), pi, .act),
            (DiskSpaceCommand(volumes: { [startup] }, shell: linuxHost.shell), .none, .local, .value),
            (MemoryUsageCommand(shell: linuxHost.shell), .none, pi, .value),
            (OpenCommand(), .text(folder), .local, .open),
            (code, .text("cortex"), .local, .open),
            (terminal, .none, .local, .open),
            (sound, .text("airhorn"), .local, .open),
            (ClipCommand(), .text("https://youtu.be/abc 1:23 4 horn"), .local, .job),
            (UUIDCommand(), .none, .local, .value),
            (TokenCommand(), .none, .local, .value),
        ]
        for (command, input, machine, kind) in expected {
            let outcome = try await command.resolve(input, machine: machine)
            #expect(outcome.kind == kind, "\(command.name)")
        }
        #expect(Set(expected.map { $0.3 }) == [.value, .open, .act, .job], "all but the handoff, which the app's commands make")
    }

    @Test func theUsageReportsAreValuesThatRefreshEveryTwoSeconds() async throws {
        let host = Machine.ssh("pi")
        let memory = MemoryUsageCommand { _, _ in "@@ system\nLinux\n@@ meminfo\nMemTotal: 1000 kB\nMemFree: 500 kB\n@@ ps\n    1     0  9000 systemd\n" }
        guard case .value(.report(let report), let refresh) = try await memory.resolve(.none, machine: host) else {
            throw QuickActionError("not a report")
        }
        #expect(refresh == .seconds(2) && report.text.hasPrefix("pi\n"))

        let cpu = CPUUsageCommand { _, _ in
            "@@ system\nLinux\n@@ model\nmodel name\t: ARM\n@@ load\n0.07 0.05 0.00 1/100 5\n@@ stat1\ncpu  100 0 100 800\n@@ procs1\n@@ stat2\ncpu  200 0 100 900\n@@ procs2\n"
        }
        guard case .value(.report, let cpuRefresh) = try await cpu.resolve(.none, machine: host) else { throw QuickActionError("not a report") }
        #expect(cpuRefresh == .seconds(2))

        let gpu = GPUUsageCommand { _, _ in "@@ system\nLinux\n@@ nvidia\nNVIDIA T4, 45, 1234, 15360, 61, 70\n@@ nvidia-apps\n" }
        guard case .value(.report, let gpuRefresh) = try await gpu.resolve(.none, machine: host) else { throw QuickActionError("not a report") }
        #expect(gpuRefresh == .seconds(2))
    }

    @Test func aTokenIsASecretAndAUUIDIsNot() async throws {
        let token = try await TokenCommand().resolve(.none)
        #expect(token.secret?.count == 32)
        guard case .value(let uuid, nil) = try await UUIDCommand().resolve(.none) else { throw QuickActionError("not a plain value") }
        #expect(!uuid.isSecret && uuid.text.flatMap(UUID.init(uuidString:)) != nil)
    }

    @Test func resolvingDoesNotDoWhatTheOutcomeDoes() async throws {
        // A clip is a job: the link is parsed and described, nothing is
        // downloaded and no folder is made.
        let folder = FileManager.default.temporaryDirectory.appending(path: "cortex-outcome-\(UUID().uuidString)")
        let clip = ClipCommand(folder: { folder })
        guard case .job(let plan, _) = try await clip.resolve(.text("https://youtu.be/abc 1:23 4 horn")) else { throw QuickActionError("not a job") }
        #expect(plan.hasPrefix("Cuts 0:04 from 1:23 of https://youtu.be/abc"))
        #expect(!FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)))

        // Killing is an act: looking up ends nothing until the question is confirmed.
        let hosts = CannedHosts { _, script in script.contains("echo '@@ ending'") ? "@@ ending\nended 812\n" : ProcessToolsTests.linuxOwn }
        let kill = try await KillCommand(shell: hosts.shell).resolve(.text("node server"), machine: .ssh("pi"))
        #expect(kill.kind == .act)
        #expect(!hosts.scripts.contains { $0.script.contains("kill -") }, "nothing was ended")
    }

    // MARK: - The outcome as a value

    @Test func outcomesAreEqualWhenTheySayTheSame() {
        let report = ActionReport(text: "table", content: 1)
        #expect(CommandOutcome.value(.report(report), refresh: .seconds(2)) == .value(.report(ActionReport(text: "table", content: 2)), refresh: .seconds(2)))
        #expect(CommandOutcome.value(.text("a")) != .value(.secret("a")))
        #expect(CommandOutcome.value(.text("a")) != .value(.text("a"), refresh: .seconds(2)))
        #expect(CommandOutcome.job(plan: "p", run: { _ in .handled }) == .job(plan: "p", run: { _ in .done("") }))
        #expect(CommandOutcome.handoff(description: "d", run: {}) != .job(plan: "d", run: { _ in .handled }))
        #expect(CommandOutcome.open(.play(URL(filePath: "/a"))).kind == .open)
        #expect(Set(CommandOutcome.Kind.allCases.map(\.rawValue)) == ["value", "open", "act", "job", "handoff"])
    }

    // MARK: - What ⏎ and ⌥⏎ are called

    private func keys(_ outcome: CommandOutcome, of command: any Command = Stub(outcome: .value(.text("")))) -> CommandOutcome.Keys {
        outcome.keys(of: command)
    }

    @Test func aValueIsPastedAndCopied() {
        #expect(keys(.value(.text("a"))) == CommandOutcome.Keys("Paste", option: "Copy"))
        #expect(keys(.value(.secret("a"), refresh: .seconds(2))) == CommandOutcome.Keys("Paste", option: "Copy"))
    }

    @Test func anOpenOutcomeNamesWhatOpensAndCopiesTheLinkOrPath() async throws {
        let url = URL(string: "https://github.com/apple/swift")!
        let folder = URL(filePath: "/Users/me/Developer")
        let app = URL(filePath: "/Applications/Ghostty.app")
        #expect(keys(.open(.url(url))) == CommandOutcome.Keys("Open", option: "Copy link"))
        #expect(keys(.open(.reveal(folder))) == CommandOutcome.Keys("Show in Finder", option: "Copy path"))
        #expect(keys(.open(.openWith(folder, app: app))) == CommandOutcome.Keys("Open in Ghostty", option: "Copy path"))
        #expect(keys(.open(.play(folder))) == CommandOutcome.Keys("Play", option: "Copy path"))
        // A command may name it better: $code opens a vscode:// link.
        let code = CodeCommand(
            projects: { [FolderShortcut(name: "cortex", location: .local("/Users/me/Developer/Cortex"))] }, home: URL(filePath: "/Users/me"))
        let outcome = try await code.resolve(.text("cortex"))
        #expect(keys(outcome, of: code) == CommandOutcome.Keys("Open in VS Code", option: "Copy link"))
    }

    @Test func whatOptionReturnCopiesIsTheLinkOrThePath() {
        #expect(OpenTarget.url(URL(string: "https://example.com/a?b=1")!).copyText == "https://example.com/a?b=1")
        #expect(OpenTarget.reveal(URL(filePath: "/Users/me/My Files/a.txt")).copyText == "/Users/me/My Files/a.txt", "a path, not a file: link")
        #expect(OpenTarget.openWith(URL(filePath: "/Users/me/dev"), app: URL(filePath: "/Applications/Terminal.app")).copyText == "/Users/me/dev")
        #expect(OpenTarget.play(URL(filePath: "/s/air horn.mp4")).copyText == "/s/air horn.mp4")
    }

    @Test func anActAsksFirstAndHasNoOptionReturn() async throws {
        let confirmation = ActionConfirmation(title: "Kill node?", message: "m", confirmTitle: "Kill") { .done("") }
        #expect(keys(.act(confirmation)) == CommandOutcome.Keys("Kill…"))
        let hosts = CannedHosts { _, _ in ProcessToolsTests.linuxOwn }
        let outcome = try await KillCommand(shell: hosts.shell).resolve(.text("node"), machine: .ssh("pi"))
        let confirmTitle = try #require(outcome.confirmation?.confirmTitle)
        #expect(keys(outcome) == CommandOutcome.Keys(confirmTitle + "…"))
        let two = ActionConfirmation(title: "Kill 2 processes?", message: "m", confirmTitle: "Kill 2 Processes") { .done("") }
        #expect(keys(.act(two)).primary == "Kill 2 Processes…")
        #expect(keys(.act(two)).option == nil)
    }

    @Test func aJobStartsAndMayCopyItsResult() {
        #expect(keys(.job(plan: "p", run: { _ in .handled })) == CommandOutcome.Keys("Start", option: "Start and copy"))
    }

    @Test func aHandoffUsesTheCommandsVerbAndHasNoOptionReturn() {
        struct Picker: Command {
            let id = "test.picker"
            let name = "picker"
            let title = "Picker"
            let symbol = "eyedropper"
            let verb: String? = "Pick Colour"
            func resolve(_ invocation: CommandInvocation) async throws -> CommandOutcome { .handoff(description: "", run: {}) }
        }
        let handoff = CommandOutcome.handoff(description: "d", run: {})
        #expect(keys(handoff, of: Picker()) == CommandOutcome.Keys("Pick Colour"))
        #expect(keys(handoff) == CommandOutcome.Keys("Run"), "a command without a verb")
    }

    // MARK: - Nothing to do

    @Test func aNoticeIsAnErrorThatSaysThereIsNothingToDo() {
        let notice = QuickActionError.notice("Nothing is listening on port 3000")
        #expect(notice.isNotice && notice.message == "Nothing is listening on port 3000")
        #expect(!QuickActionError("Nothing is listening on port 3000").isNotice)
        #expect(notice != QuickActionError("Nothing is listening on port 3000"))
        #expect(notice == QuickActionError.notice("Nothing is listening on port 3000"))
    }

    @Test func portAndKillResolveToNoticesWhenThereIsNothingToEnd() async throws {
        let hosts = CannedHosts { _, script in
            script.contains("@@ ss") || script.contains("lsof") ? HostCommandTests.piPort(ss: "") : ProcessToolsTests.linuxOwn
        }
        let pi = Machine.ssh("pi")
        for (name, command, input) in [("port", PortCommand(shell: hosts.shell) as any Command, "3000"), ("kill", KillCommand(shell: hosts.shell), "nope")] {
            do {
                _ = try await command.resolve(.text(input), machine: pi)
                Issue.record("\(name) should have had nothing to do")
            } catch let error as QuickActionError {
                #expect(error.isNotice, "\(name): \(error.message)")
            }
        }
        // A real failure stays an error.
        await #expect(throws: QuickActionError("“abc” is not a port number (1–65535)")) {
            try await PortCommand(shell: hosts.shell).resolve(.text("abc"), machine: pi)
        }
    }

    @Test func fromActionsANoticeIsTheSentenceNotAFailure() async throws {
        let hosts = CannedHosts { _, _ in ProcessToolsTests.linuxOwn }
        let kill = CommandAction(KillCommand(shell: hosts.shell))
        #expect(try await kill.run(.text("nope"), context: context(machine: .ssh("pi"))) == .done("None of your processes on pi is called “nope”"))
        await #expect(throws: QuickActionError.self, "an error is still thrown") {
            try await CommandAction(PortCommand(shell: hosts.shell)).run(.text("abc"), context: context())
        }
    }

    // MARK: - The adapter

    private struct Stub: Command {
        let id = "test.stub"
        let name = "stub"
        let title = "Stub"
        let symbol = "circle"
        var outcome: CommandOutcome
        var isRemote = false
        func resolve(_ invocation: CommandInvocation) async throws -> CommandOutcome { outcome }
    }

    private func perform(_ outcome: CommandOutcome) async throws -> ActionOutput {
        try await CommandAction(Stub(outcome: outcome), outcome: outcome).run(.none, context: context())
    }

    @Test func theAdapterMapsEachOutcomeToAnOutput() async throws {
        let report = ActionReport(text: "table", content: 1)
        let png = Data([1, 2, 3])
        let url = URL(string: "https://example.com")!
        let file = URL(filePath: "/tmp/a.txt")
        let app = URL(filePath: "/Applications/Terminal.app")

        #expect(try await perform(.value(.text("a"))) == .text("a"))
        #expect(try await perform(.value(.secret("s"))) == .text("s"))
        #expect(try await perform(.value(.report(report))) == .report(report))
        #expect(try await perform(.value(.image(png))) == .image(png))
        #expect(try await perform(.open(.url(url))) == .open(url))
        #expect(try await perform(.open(.reveal(file))) == .reveal(file))
        #expect(try await perform(.open(.openWith(file, app: app))) == .openWith(file, app: app))
        #expect(try await perform(.open(.play(file))) == .play(file))
        let confirmation = ActionConfirmation(title: "Kill?", message: "m", confirmTitle: "Kill") { .done("ended") }
        #expect(try await perform(.act(confirmation)) == .confirm(confirmation))
        #expect(try await perform(.job(plan: "p", run: { _ in .text("job output") })) == .text("job output"))
        nonisolated(unsafe) var handedOver = false
        #expect(try await perform(.handoff(description: "d", run: { handedOver = true })) == .handled)
        #expect(handedOver, "the handoff ran")
    }

    @Test func theAdapterKeepsTheCommandsIdentity() {
        let command = TokenCommand()
        let action = CommandAction(command)
        #expect(action.id == "command.token" && action.title == command.title && action.symbol == command.symbol)
        #expect(action.keywords == command.keywords && action.options == command.options)
        #expect(action.accepts(.text("64")) == command.accepts(.text("64")) && action.accepts(.none) == command.accepts(.none))
        #expect(CommandAction(PortCommand()).id == "command.port")
        #expect(CommandAction(Stub(outcome: .value(.text("")), isRemote: true)).isRemote)
    }

    @Test func onlyABoundJobIsNotInstantAndOnlyASecretIsSensitive() {
        let stub = Stub(outcome: .value(.text("")))
        let job = CommandOutcome.job(plan: "p", run: { _ in .handled })
        #expect(CommandAction(stub).isInstant, "unbound: it resolves when it runs")
        #expect(CommandAction(stub, outcome: .value(.text("a"))).isInstant)
        #expect(CommandAction(stub, outcome: .act(ActionConfirmation(title: "", message: "", confirmTitle: "") { .handled })).isInstant)
        #expect(CommandAction(stub, outcome: .handoff(description: "", run: {})).isInstant)
        #expect(!CommandAction(stub, outcome: job).isInstant)
        #expect(CommandAction(stub, outcome: .value(.secret("s"))).hasSensitiveResult)
        #expect(!CommandAction(stub, outcome: .value(.text("s"))).hasSensitiveResult)
        #expect(!CommandAction(stub).hasSensitiveResult)
    }

    @Test func withoutAnOutcomeTheAdapterResolvesWhenItRuns() async throws {
        let token = CommandAction(TokenCommand())
        guard case .text(let text) = try await token.run(.text("40"), context: context()) else { throw QuickActionError("no text") }
        #expect(text.count == 40, "on the input and options of the run")
        let options = ActionOptionValues([TokenCommand.format.id: "hex"])
        guard case .text(let hex) = try await token.run(.text("40"), context: context(options: options)) else { throw QuickActionError("no text") }
        #expect(hex.allSatisfy { "0123456789abcdef".contains($0) })
        await #expect(throws: QuickActionError.self) { try await token.run(.text("abc"), context: context()) }
    }

    @Test func theAdapterRunsTheOutcomeItWasGivenAndDoesNotResolveAgain() async throws {
        let resolved = Counter()
        let command = CountingCommand(counter: resolved)
        let outcome = try await command.resolve(.none)
        #expect(resolved.count == 1)
        let action = CommandAction(command, outcome: outcome)
        #expect(try await action.run(.none, context: context()) == .text("#1"), "what was shown")
        #expect(try await action.run(.none, context: context()) == .text("#1"))
        #expect(resolved.count == 1)
        #expect(try await CommandAction(command).run(.none, context: context()) == .text("#2"), "unbound: resolved afresh")
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func next() -> Int { lock.withLock { value += 1; return value } }
    }

    struct CountingCommand: Command {
        let id = "test.counting"
        let name = "counting"
        let title = "Counting"
        let symbol = "number"
        let counter: Counter
        func resolve(_ invocation: CommandInvocation) async throws -> CommandOutcome { .value(.text("#\(counter.next())")) }
    }

    // MARK: - > keeps offering commands

    @Test func actionsOffersPortAndOpenThroughMatches() throws {
        let actions = CommandCatalog.builtIns.map { CommandAction($0) as any QuickAction }
        func offered(_ input: ActionInput) -> [String] {
            ActionCatalog.list(actions, query: "", for: .context(input)).map(\.id)
        }
        #expect(offered(.text("3000")) == ["command.port"], "a copied port number")
        #expect(offered(.text("hello")).isEmpty)
        let folder = FileManager.default.temporaryDirectory.path(percentEncoded: false)
        #expect(offered(.text(folder)) == ["command.open"], "a copied path")
        #expect(offered(.files([URL(filePath: folder)])) == ["command.open"])
        #expect(offered(.none).isEmpty)
    }

    @Test func aCommandIsFoundByItsNameAmongTheActions() {
        let actions = CommandCatalog.builtIns.map { CommandAction($0) as any QuickAction }
        let ranked = ActionCatalog.rank(actions, query: "port", usage: [:])
        #expect(ranked.first?.id == "command.port", "its name ranks first")
    }
}
