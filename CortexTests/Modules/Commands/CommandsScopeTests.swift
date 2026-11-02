import AppKit
import SwiftUI
import Testing
@testable import Cortex
import CortexCore

/// Quick Actions as the Commands module sees it, over a real
/// `ActionsService`; counts the resolutions it is asked for.
@MainActor
final class ServiceActions: ActionsAPI {
    let service: ActionsService
    private(set) var resolutions = 0
    private var handlers: [@MainActor () -> Void] = []

    init(service: ActionsService) {
        self.service = service
    }

    func showActions(on input: ResolvedActionInput?) {}

    func resolve(_ command: any Command, input: ActionInput, options: ActionOptionValues?, machine: Machine) async -> CommandResolution? {
        resolutions += 1
        return await service.resolve(command, input: input, options: options, machine: machine)
    }

    func run(_ command: any Command, input: ActionInput, machine: Machine, resolution: CommandResolution?, delivery: ActionDelivery, summary: String?) async -> Bool {
        await service.run(command, input: input, machine: machine, resolution: resolution, delivery: delivery, summary: summary)
    }

    func options(for command: any Command) -> ActionOptionValues { service.options(for: command) }
    func setOptions(_ values: ActionOptionValues, for command: any Command) { service.setOptions(values, for: command) }
    var usage: [String: ActionUsage] { service.usage }
    var userCommands: [UserCommand] { service.userCommands }
    func onUserFilesChanged(_ handler: @escaping @MainActor () -> Void) { handlers.append(handler) }

    func commandPane(for command: any Command, typed: String?, resolution: CommandResolution?, loading: String?, refreshProblem: String?) -> AnyView {
        AnyView(EmptyView())
    }

    /// What Quick Actions does after reading the folder again.
    func reload() {
        service.reload()
        for handler in handlers { handler() }
    }
}

/// `$` in the palette: reading the query, listing, resolving and running.
@MainActor
@Suite struct CommandsScopeTests {
    let directory: URL
    let service: ActionsService
    let actions: ServiceActions
    let palette = FakePaletteHost()
    let scope: CommandsScope
    final class Contributed {
        var commands: [any Command] = []
    }
    let contributed = Contributed()
    /// What `.open` results would have opened: nothing reaches the browser.
    final class Opened {
        var urls: [URL] = []
    }
    let opened = Opened()

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "CortexTests-commands-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "name = 'GitHub Repository'\ntrigger = 'gh'\nurl = 'https://github.com/{argument}'\nexample = 'owner/repo'"
            .write(to: directory.appending(path: "gh.toml"), atomically: true, encoding: .utf8)
        try "name = 'Nap'\ntrigger = 'nap'\ncommand = 'sleep 0.1'\nargument = 'optional'"
            .write(to: directory.appending(path: "nap.toml"), atomically: true, encoding: .utf8)
        try "name = 'Hello'\ntrigger = 'hello'\nurl = 'https://example.com/hello'"
            .write(to: directory.appending(path: "hello.toml"), atomically: true, encoding: .utf8)
        service = ActionsService(
            directory: directory, defaults: UserDefaults(suiteName: "CortexTests-\(UUID().uuidString)")!,
            openURL: { [opened] in opened.urls.append($0) })
        service.reload()
        actions = ServiceActions(service: service)
        let (actions, palette, contributed) = (actions, palette, contributed)
        scope = CommandsScope(
            commands: { CommandCatalog.builtIns + contributed.commands + actions.userCommands },
            actions: { actions },
            palette: { palette },
            hosts: { ["raspberrypi", "linode"] },
            openURL: { [opened] in opened.urls.append($0) })
        scope.previewDelay = .zero
        // As the module does.
        actions.onUserFilesChanged { [scope] in scope.commandsDidChange() }
    }

    // MARK: - Listing

    @Test func everyCommandIsListedForAnEmptyQuery() {
        scope.search("")
        #expect(scope.list.items.map(\.id) == [
            "command.kill", "command.port", "command.diskspace", "command.memuse", "command.cpuuse", "command.gpuuse", "command.open", "command.code", "command.term", "command.clip", "command.sound", "command.uuid", "command.token", "user.gh", "user.hello", "user.nap",
        ])
        #expect(scope.list.items.map { CommandsModule.prefix + $0.usage }
            == ["$kill node", "$port 3000", "$disk Macintosh HD", "$mem", "$cpu", "$gpu", "$open ~/Downloads", "$code cortex", "$term cortex", "$clip https://youtu.be/… 1:23 4 airhorn", "$sound airhorn", "$uuid", "$token 32", "$gh owner/repo", "$hello", "$nap …"])
    }

    @Test func theExactNameComesFirstAndTakesTheArgument() {
        scope.search("port 3000")
        #expect(scope.list.selected?.id == "command.port")
        #expect(scope.query.argument == "3000")
        #expect(scope.input(for: scope.list.selected!) == .text("3000"))
        scope.search("kill node")
        #expect(scope.list.items.map(\.id) == ["command.kill", "command.port"], "the named command comes first")
        #expect(scope.input(for: scope.list.items[1]) == .none, "the argument is only the named command's")
    }

    @Test func theRowShowsWhatWasTypedInsteadOfTheExample() throws {
        scope.search("code mathical")
        let code = try #require(scope.list.selected)
        #expect(CommandRowView.title(for: code, typedArgument: scope.query.argument) == ("$code mathical", nil))
        scope.search("code")
        #expect(CommandRowView.title(for: code, typedArgument: scope.query.argument) == ("$code", "cortex"), "the example, dimmed")
        scope.search("uuid")
        let uuid = try #require(scope.list.selected)
        #expect(CommandRowView.title(for: uuid, typedArgument: nil) == ("$uuid", nil))
    }

    @Test func aPartialNameSearches() {
        scope.search("po")
        #expect(scope.list.items.first?.id == "command.port")
        #expect(!scope.query.isNamed)
        scope.search("kil node")
        #expect(scope.list.isEmpty, "the rest is part of the search")
        scope.search("github")
        #expect(scope.list.selected?.id == "user.gh", "titles are searched too")
    }

    @Test func typingTheArgumentKeepsTheSelection() {
        scope.search("kill n")
        scope.move(.vertical(1))
        #expect(scope.list.selected?.id == "command.port")
        scope.search("kill node")
        #expect(scope.list.selected?.id == "command.port")
    }

    @Test func mostUsedFirst() async throws {
        let hello = try #require(actions.userCommands.first { $0.name == "hello" })
        await service.run(hello, input: .none, delivery: .paste(nil))
        #expect(opened.urls == [URL(string: "https://example.com/hello")!])
        scope.search("")
        #expect(scope.list.selected?.id == "user.hello")
    }

    @Test func otherModulesCommandsAreListed() {
        scope.search("ask")
        #expect(scope.list.isEmpty)
        contributed.commands = AICommand.all(vendor: .openAI, textModel: "t", imageModel: "i") { _ in
            throw QuickActionError("not sent")
        }
        scope.search("ask why")
        #expect(scope.list.selected?.id == "ai.ask")
        #expect(scope.input(for: scope.list.selected!) == .text("why"))
    }

    // MARK: - Resolving

    @Test func nothingIsResolvedUntilTheArgumentIsTyped() async {
        scope.search("port")
        await scope.previewLoaded()
        #expect(scope.list.selected?.id == "command.port")
        #expect(scope.resolution == nil)
        #expect(actions.resolutions == 0)
    }

    @Test func theTypedArgumentIsResolved() async throws {
        let port = try unusedPort()
        scope.search("port \(port)")
        await scope.previewLoaded()
        #expect(scope.resolution?.commandID == "command.port")
        #expect(scope.resolution?.input == .text(String(port)))
        #expect(scope.resolution?.result == .failure(.notice("Nothing is listening on port \(port) (only your own processes are checked)")))

        scope.search("port x")
        await scope.previewLoaded()
        #expect(scope.resolution?.result == .failure(QuickActionError("“x” is not a port number (1–65535)")))
    }

    @Test func onlyTheLastTypedArgumentIsResolved() async throws {
        scope.previewDelay = .milliseconds(100)
        let port = try unusedPort()
        scope.search("port 1")
        scope.search("port 12")
        scope.search("port \(port)")
        await scope.previewLoaded()
        #expect(scope.resolution?.input == .text(String(port)))
        #expect(actions.resolutions == 1, "looked up once, after the pause")
    }

    @Test func aCommandThatTakesNothingIsResolvedAtOnce() async {
        scope.search("hello")
        await scope.previewLoaded()
        #expect(scope.resolution?.result == .success(.open(.url(URL(string: "https://example.com/hello")!))))
    }

    @Test func everyCommandHasAnOutcome() async throws {
        // No more "instant or not": a job and a handoff are shown too.
        scope.search("nap")
        await scope.previewLoaded()
        guard case .success(.job(let plan, _)) = scope.resolution?.result else { throw QuickActionError("not a job") }
        #expect(plan == "sleep 0.1")
        scope.search("clip https://youtu.be/abc 1:23 4")
        await scope.previewLoaded()
        #expect(scope.resolution?.outcome?.kind == .job)
        scope.search("uuid")
        await scope.previewLoaded()
        #expect(scope.resolution?.outcome?.kind == .value)
        scope.search("token")
        await scope.previewLoaded()
        #expect(scope.resolution?.outcome?.kind == .value)
        #expect(scope.resolution?.outcome?.secret != nil)

        contributed.commands = [HandoffCommand()]
        scope.search("handoff")
        await scope.previewLoaded()
        guard case .success(.handoff(let description, _)) = scope.resolution?.result else { throw QuickActionError("not a handoff") }
        #expect(description == "Hands over")
    }

    @Test func aFailedResolveIsTheError() async {
        scope.search("clip https://youtu.be/abc")
        await scope.previewLoaded()
        #expect(scope.resolution?.result == .failure(QuickActionError("Type where the clip starts and how long it is after the link: 1:23 4")))
        scope.search("clip")
        #expect(scope.activate(.primary, target: .selected), "the form opens")
        #expect(palette.overlays.count == 1)
    }

    @Test func leavingTheNameCancelsTheLookup() async {
        scope.previewDelay = .milliseconds(100)
        scope.search("port 3000")
        scope.search("gh")
        await scope.previewLoaded()
        #expect(actions.resolutions == 0)
        #expect(scope.resolution == nil, "gh still needs its argument")
    }

    // MARK: - Running

    @Test func returnCarriesOutTheOutcomeThatWasShown() async throws {
        contributed.commands = [CountingCommand()]
        scope.search("count x")
        await scope.previewLoaded()
        #expect(actions.resolutions == 1)
        #expect(scope.resolution?.result == .success(.open(.url(URL(string: "https://example.com/1")!))))
        #expect(scope.activate(.primary, target: .selected))
        #expect(palette.deliveries.map(\.action) == [.paste(.plainText)])
        #expect(service.usage["test.count"] == nil, "runs once the palette has closed")
        await palette.delivered()
        #expect(service.usage["test.count"]?.count == 1)
        #expect(actions.resolutions == 1, "the outcome that was shown, not a second lookup")
        #expect(opened.urls == [URL(string: "https://example.com/1")!], "exactly what the pane named")
    }

    @Test func returnBeforeTheOutcomeIsThereResolvesOnce() async throws {
        contributed.commands = [CountingCommand()]
        scope.previewDelay = .seconds(30)
        scope.search("count x")
        #expect(scope.resolution == nil, "still waiting for the pause")
        #expect(scope.activate(.primary, target: .selected))
        await palette.delivered()
        #expect(actions.resolutions == 0, "the scope never resolved; the run did")
        #expect(opened.urls.count == 1 && opened.urls[0].lastPathComponent == "1")
        scope.clear()
    }

    @Test func aCommandThatCannotResolveIsAFailedRunNotACrash() async throws {
        let command = try #require(CommandCatalog.builtIns.first { $0.name == "clip" })
        await service.run(command, input: .text("nonsense"), delivery: .copy)
        #expect(service.usage["command.clip"]?.count == 1, "counted like any run")
        #expect(opened.urls.isEmpty && service.jobs.isEmpty)
    }

    @Test func optionReturnOnlyCopies() async {
        scope.search("gh apple/swift")
        #expect(scope.activate(.option, target: .selected))
        await scope.runLoaded()
        #expect(palette.deliveries.map(\.action) == [.copyOnly])
    }

    @Test func aCommandThatNeedsItsArgumentOpensItsForm() {
        scope.search("gh")
        #expect(scope.activate(.primary, target: .selected))
        #expect(palette.deliveries.isEmpty)
        #expect(palette.overlays.count == 1)
        #expect(scope.forms["user.gh"] != nil)
        scope.search("kill")
        #expect(scope.activate(.primary, target: .selected))
        #expect(palette.deliveries.isEmpty)
        #expect(palette.overlays.count == 2)
    }

    @Test func tabOpensTheFormOfACommandWithFields() {
        scope.search("hello")
        #expect(scope.keys.isEmpty, "nothing to fill in")
        scope.search("gh apple/swift")
        #expect(scope.keys.map(\.hint) == ["Fill in"])
    }

    @Test func commandEOpensTheSettingsFileOfTheCommandTyped() throws {
        let file = directory.appending(path: "config/notes.toml")
        contributed.commands = [SettingsCommand(settingsFile: file)]
        scope.search("not")
        #expect(scope.list.selected?.id == "test.notes")
        #expect(scope.keys.map(\.hint) == ["Fill in"], "only once the command is typed")
        scope.search("notes")
        #expect(scope.keys.map(\.hint) == ["Fill in", "Edit notes.toml"])
        scope.search("notes x")
        let key = try #require(scope.keys.first { $0.combo == CommandsScope.settingsKey })
        #expect(key.perform?() == true)
        #expect(palette.closes == 1)
        #expect(opened.urls.map(\.absoluteString) == ["vscode://file" + file.path(percentEncoded: false)])
        #expect(try String(contentsOf: file, encoding: .utf8) == "# notes\n", "written when missing")
        #expect(palette.deliveries.isEmpty, "the command does not run")

        scope.search("notes")
        #expect(scope.activate(.primary, target: .selected))
        #expect(palette.overlays.count == 1, "⏎ without the argument opens the form")
        #expect(palette.overlays[0].keys.contains { $0.combo == CommandsScope.settingsKey && $0.hint == "Edit notes.toml" }, "the form has it too")
        scope.search("code")
        #expect(scope.keys.map(\.hint) == ["Fill in", "Edit projects.toml"], "the built-in ones")
        scope.search("port")
        #expect(scope.keys.map(\.hint) == ["Fill in"])
    }

    @Test func aFailedResolveBeepsInsteadOfRunning() async {
        scope.search("port abc")
        await scope.previewLoaded()
        #expect(scope.activate(.primary, target: .selected))
        #expect(palette.deliveries.isEmpty)
    }

    @Test func aCommandThatTakesNothingRunsOnReturn() async {
        scope.search("hello")
        #expect(scope.activate(.primary, target: .selected))
        #expect(palette.deliveries.count == 1)
    }

    @Test func theJobSaysWhatWasTyped() async throws {
        scope.search("nap 20 minutes")
        #expect(scope.list.selected?.id == "user.nap")
        #expect(scope.activate(.primary, target: .selected))
        await palette.delivered()
        #expect(service.jobs.map(\.inputSummary) == ["$nap 20 minutes"])
        for job in service.jobs { await job.task?.value }
        #expect(CommandsScope.summary(of: PortCommand(), argument: "3000") == "$port 3000")
    }

    @Test func memuseIsResolvedAtOnceAndRunsOnReturn() async throws {
        scope.search("mem")
        await scope.previewLoaded()
        let resolution = try #require(scope.resolution)
        guard case .success(.value(.report(let report), let refresh)) = resolution.result else { throw QuickActionError("no report") }
        #expect(refresh == .seconds(2))
        #expect(report.text.hasPrefix("Physical memory"))
        #expect(report.content is MemorySnapshot, "the pane draws it")
        #expect(scope.keys.map(\.hint) == ["Host"], "⇥ picks a host")
        #expect(scope.activate(.primary, target: .selected))
        #expect(palette.overlays.isEmpty)
        #expect(palette.deliveries.map(\.action) == [.paste(.plainText)])
    }

    @Test func diskspaceTakesAVolumeByNameOrMountPoint() async throws {
        scope.search("disk /")
        await scope.previewLoaded()
        guard case .success(.value(.report(let report), _)) = scope.resolution?.result else { throw QuickActionError("no table") }
        #expect(report.text.contains("Total") && report.text.contains("Free"))
        #expect((report.content as? VolumeSpace)?.path == "/")

        scope.search("disk Floppy")
        await scope.previewLoaded()
        guard case .failure(let error) = scope.resolution?.result else { throw QuickActionError("no error") }
        #expect(error.message.hasPrefix("“Floppy” is not a mounted volume"))
        #expect(scope.activate(.primary, target: .selected), "beeps")
        #expect(palette.deliveries.isEmpty)

        scope.search("disk")
        #expect(scope.keys.map(\.hint) == ["Fill in"])
        let tab = try #require(scope.keys.first { $0.combo == .tab })
        #expect(tab.perform?() == true)
        let form = try #require(scope.forms["command.diskspace"])
        await form.loaded()
        #expect(form.shownSuggestions.first?.source == .choice, "the volumes, the startup volume first")
        #expect(form.text == "")
    }

    // MARK: - Hosts

    /// The report commands over canned hosts ("raspberrypi" and "linode").
    private func hostScope(_ shell: HostShell) -> CommandsScope {
        let (actions, palette) = (actions, palette)
        let startup = VolumeSpace(name: "Macintosh HD", path: "/", total: 1_000_000, available: 400_000)
        let scope = CommandsScope(
            commands: {
                [MemoryUsageCommand(shell: shell.shell), DiskSpaceCommand(volumes: { [startup] }, shell: shell.shell),
                 KillCommand(shell: shell.shell)]
            },
            actions: { actions },
            palette: { palette },
            hosts: { ["raspberrypi", "linode"] })
        scope.previewDelay = .zero
        return scope
    }

    @Test func anAtWordPicksTheHostAndIsNotTheArgument() async throws {
        let shell = HostShell()
        let scope = hostScope(shell)
        scope.search("mem @rasp")
        let mem = try #require(scope.list.selected)
        #expect(scope.query.hosts == ["rasp"] && scope.query.argument == nil)
        #expect(scope.machine == .ssh("raspberrypi"), "the only alias that starts with it")
        #expect(scope.input(for: mem) == .none)
        #expect(scope.loadingTitle(for: mem) == "Memory Usage on raspberrypi")
        await scope.previewLoaded()
        #expect(scope.resolution?.machine == .ssh("raspberrypi"))
        guard case .success(.value(.report(let report), _)) = scope.resolution?.result, let snapshot = report.content as? MemorySnapshot else {
            throw QuickActionError("no snapshot")
        }
        #expect(snapshot.host == "raspberrypi")
        #expect(shell.machines == [.ssh("raspberrypi")])

        scope.search("mem  @RASP")
        await scope.previewLoaded()
        #expect(shell.machines.count == 1, "the same machine: the result is kept")
        scope.search("mem @linode")
        await scope.previewLoaded()
        #expect(scope.resolution?.machine == .ssh("linode") && shell.machines.count == 2)
    }

    @Test func theHostComesAfterTheArgumentOrBeforeIt() async throws {
        let shell = HostShell()
        let scope = hostScope(shell)
        scope.search("disk /mnt/usb @linode")
        let disk = try #require(scope.list.selected)
        #expect(scope.input(for: disk) == .text("/mnt/usb") && scope.machine == .ssh("linode"))
        #expect(CommandRowView.title(for: disk, typedArgument: scope.query.argument, typedHosts: scope.query.hosts)
            == ("$disk /mnt/usb @linode", nil), "the row shows what was typed")
        await scope.previewLoaded()
        guard case .success(.value(.report(let report), _)) = scope.resolution?.result, let volume = report.content as? VolumeSpace else {
            throw QuickActionError("no volume")
        }
        #expect(volume.path == "/mnt/usb" && volume.host == "linode", "a path on the host, not a local volume")

        scope.search("disk @linode /mnt/usb")
        #expect(scope.input(for: disk) == .text("/mnt/usb") && scope.machine == .ssh("linode"))
        scope.search("disk @linode")
        #expect(scope.input(for: disk) == .none)
        #expect(CommandRowView.title(for: disk, typedArgument: nil, typedHosts: ["linode"]) == ("$disk @linode", nil))
        #expect(CommandRowView.title(for: disk, typedArgument: nil) == ("$disk", "Macintosh HD"))
        #expect(scope.keys.map(\.hint) == ["Fill in"])
    }

    @Test func otherCommandsKeepAtWordsInTheirArgument() {
        scope.search("token 32 @raspberrypi")
        #expect(scope.query.hosts.isEmpty && scope.query.argument == "32 @raspberrypi")
        #expect(scope.machine == .local && scope.hostProblem == nil)
        #expect(scope.input(for: scope.list.selected!) == .text("32 @raspberrypi"))
    }

    @Test func killAndPortRunOnHostsToo() async throws {
        let shell = HostShell()
        let scope = hostScope(shell)
        scope.search("kill node @rasp")
        #expect(scope.query.hosts == ["rasp"] && scope.query.argument == "node")
        #expect(scope.machine == .ssh("raspberrypi"))
        #expect(scope.loadingTitle(for: scope.list.selected!) == "Kill Process on raspberrypi")
        await scope.previewLoaded()
        guard case .success(.act(let confirmation)) = scope.resolution?.result else { throw QuickActionError("no question") }
        #expect(confirmation.title == "Kill node on raspberrypi?")
        #expect(shell.machines == [.ssh("raspberrypi")] && scope.resolution?.machine == .ssh("raspberrypi"))
        #expect(CommandsScope.summary(of: PortCommand(), argument: "3000", machine: .ssh("pi")) == "$port 3000 @pi")
        #expect(CommandsScope.summary(of: KillCommand(), argument: "node server.js", machine: .ssh("pi")) == "$kill node server.js @pi")
        #expect(CommandRowView.title(for: scope.list.selected!, typedArgument: "node", typedHosts: ["rasp"]) == ("$kill node @rasp", nil))
    }

    @Test func aHostThatIsNotInSshConfigIsThePreviewsError() async throws {
        let shell = HostShell()
        let scope = hostScope(shell)
        scope.search("mem @nas")
        await scope.previewLoaded()
        #expect(scope.machine == .local)
        #expect(scope.hostProblem == QuickActionError("“@nas” is not a host in ~/.ssh/config. Hosts: raspberrypi, linode"))
        #expect(scope.resolution?.result == .failure(QuickActionError("“@nas” is not a host in ~/.ssh/config. Hosts: raspberrypi, linode")))
        #expect(scope.activate(.primary, target: .selected), "beeps")
        #expect(palette.deliveries.isEmpty && shell.machines.isEmpty)

        scope.search("mem @")
        #expect(scope.resolution?.result == .failure(QuickActionError("“@” is not a host in ~/.ssh/config. Hosts: raspberrypi, linode")))
        scope.search("disk /mnt @raspberrypi @linode")
        #expect(scope.resolution?.result == .failure(QuickActionError("One host at a time: @raspberrypi and @linode")))
        #expect(scope.input(for: scope.list.selected!) == .text("/mnt"))
        #expect(scope.activate(.primary, target: .selected))
        #expect(palette.deliveries.isEmpty && shell.machines.isEmpty)

        // The error goes with the host.
        scope.search("disk /mnt @linode")
        await scope.previewLoaded()
        #expect(scope.hostProblem == nil && scope.resolution?.machine == .ssh("linode"))
        guard case .success = scope.resolution?.result else { throw QuickActionError("still the error") }
    }

    @Test func theCardNamesTheHost() {
        #expect(CommandsScope.summary(of: MemoryUsageCommand(), argument: nil, machine: .ssh("pi")) == "$mem @pi")
        #expect(CommandsScope.summary(of: DiskSpaceCommand(), argument: "/mnt/usb", machine: .ssh("pi")) == "$disk /mnt/usb @pi")
        #expect(CommandsScope.summary(of: DiskSpaceCommand(), argument: "/") == "$disk /")
    }

    @Test func aResolutionIsOnlyUsedForARunOnTheSameMachine() async throws {
        let shell = HostShell()
        let command = MemoryUsageCommand(shell: shell.shell)
        let resolution = try #require(await service.resolve(command, input: .none, machine: .ssh("raspberrypi")))
        #expect(resolution.machine == .ssh("raspberrypi"))
        await service.run(command, input: .none, machine: .ssh("raspberrypi"), resolution: resolution, delivery: .copy)
        #expect(shell.machines == [.ssh("raspberrypi")], "the resolution was used")
        await service.run(command, input: .none, machine: .ssh("linode"), resolution: resolution, delivery: .copy)
        #expect(shell.machines == [.ssh("raspberrypi"), .ssh("linode")], "another machine: resolved again")
    }

    @Test func aResolutionIsOnlyUsedForTheSameInputAndOptions() async throws {
        let command = CountingCommand()
        let resolution = try #require(await service.resolve(command, input: .text("x")))
        await service.run(command, input: .text("x"), resolution: resolution, delivery: .paste(nil))
        await service.run(command, input: .text("y"), resolution: resolution, delivery: .paste(nil))
        #expect(opened.urls.map(\.lastPathComponent) == ["1", "2"], "another input: resolved again")
        service.setOptions(ActionOptionValues(["flavor": "salty"]), for: command)
        await service.run(command, input: .text("x"), resolution: resolution, delivery: .paste(nil))
        #expect(opened.urls.map(\.lastPathComponent) == ["1", "2", "3"], "other options: resolved again")
    }

    @Test func aSecretIsRecordedAsSensitiveWhateverTheInput() async throws {
        let token = try #require(CommandCatalog.builtIns.first { $0.name == "token" })
        let resolution = try #require(await service.resolve(token, input: .none))
        let action = CommandAction(token, outcome: resolution.outcome)
        #expect(action.hasSensitiveResult && action.isInstant)
    }

    @Test func aJobStartsInTheBackgroundUnderTheCommandsName() async throws {
        let nap = try #require(actions.userCommands.first { $0.name == "nap" })
        let resolution = try #require(await service.resolve(nap, input: .none))
        #expect(resolution.outcome?.kind == .job)
        await service.run(nap, input: .none, resolution: resolution, delivery: .copy, summary: "$nap")
        #expect(service.jobs.map(\.title) == ["Nap"] && service.jobs.map(\.inputSummary) == ["$nap"])
        for job in service.jobs { await job.task?.value }
        #expect(service.usage["user.nap"]?.count == 1)
    }

    // MARK: - User files

    @Test func userFilesAreListedAndReloaded() throws {
        scope.search("")
        #expect(scope.list.items.contains { $0.id == "user.nap" })
        try FileManager.default.removeItem(at: directory.appending(path: "nap.toml"))
        try "name = 'Shout'\naccepts = ['text']\ntrigger = 'shout'\ncommand = 'tr a-z A-Z'"
            .write(to: directory.appending(path: "shout.toml"), atomically: true, encoding: .utf8)
        actions.reload()
        #expect(!scope.list.items.contains { $0.id == "user.nap" })
        #expect(scope.list.items.contains { $0.id == "user.shout" }, "a file that is also an action")
        scope.search("shout hi")
        #expect(scope.input(for: scope.list.selected!) == .text("hi"))
    }

    @Test func nothingIsReloadedWhileHidden() throws {
        scope.search("")
        scope.clear()
        actions.reload()
        #expect(scope.list.isEmpty)
    }

    private func unusedPort() throws -> Int {
        for _ in 0..<20 {
            let port = Int.random(in: 49_152...65_000)
            let probe = Process()
            probe.executableURL = URL(filePath: "/usr/sbin/lsof")
            probe.arguments = ["-nP", "-i:\(port)"]
            probe.standardOutput = FileHandle.nullDevice
            try probe.run()
            probe.waitUntilExit()
            if probe.terminationStatus == 1 { return port }
        }
        throw QuickActionError("no free port")
    }
}

/// A command that opens `https://example.com/<n>` with a new `n` each time
/// it is resolved, and has an option.
private struct CountingCommand: Command {
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int { lock.withLock { value += 1; return value } }
    }

    static let flavor = ActionOption(id: "flavor", title: "Flavor", kind: .text(), defaultValue: "sweet")

    let counter = Counter()
    let id = "test.count"
    let name = "count"
    let title = "Count"
    let symbol = "number"
    let argument: CommandArgument? = CommandArgument(title: "Anything", placeholder: "x")
    var options: [ActionOption] { [Self.flavor] }

    func resolve(_ invocation: CommandInvocation) async throws -> CommandOutcome {
        .open(.url(URL(string: "https://example.com/\(counter.next())")!))
    }
}

/// A command that hands over.
private struct HandoffCommand: Command {
    let id = "test.handoff"
    let name = "handoff"
    let title = "Handoff"
    let symbol = "hand.raised"

    func resolve(_ invocation: CommandInvocation) async throws -> CommandOutcome {
        .handoff(description: "Hands over") {}
    }
}

/// A command with a settings file and a required argument.
private struct SettingsCommand: SettingsFileCommand {
    let id = "test.notes"
    let name = "notes"
    let title = "Notes"
    let symbol = "note"
    let keywords: [String] = []
    let settingsFile: URL
    let settingsStarter = "# notes\n"
    let argument: CommandArgument? = CommandArgument(title: "Note", placeholder: "x")

    func resolve(_ invocation: CommandInvocation) async throws -> CommandOutcome { .value(.text("ran")) }
}
