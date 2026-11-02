import AppKit
import SwiftUI
import Testing
@testable import Cortex
import CortexCore

/// Echoes its text in upper or lower case (its option); a value.
struct EchoCommand: Command {
    static let letterCase = ActionOption(
        id: "case", title: "Case",
        kind: .choice([ActionOption.Choice("upper", title: "Upper"), ActionOption.Choice("lower", title: "Lower")]),
        defaultValue: "upper")

    var id: String { "test.echo" }
    var title: String { "Echo" }
    var symbol: String { "text.bubble" }
    var name: String { "echo" }
    var argument: CommandArgument? {
        CommandArgument(title: "Text", placeholder: "hello", suggestions: .clips(matching: "^[a-z]+$"))
    }
    var options: [ActionOption] { [Self.letterCase] }

    func resolve(_ invocation: CommandInvocation) async throws -> CommandOutcome {
        let text = invocation.input.text ?? ""
        guard text != "fail" else { throw QuickActionError("Cannot echo “fail”") }
        return .value(.text(invocation.options[Self.letterCase] == "lower" ? text.lowercased() : text.uppercased()))
    }
}

/// Picks a fruit; the choices load when the form opens.
struct FruitCommand: Command {
    var id: String { "test.fruit" }
    var title: String { "Fruit" }
    var symbol: String { "leaf" }
    var name: String { "fruit" }
    var argument: CommandArgument? {
        CommandArgument(
            title: "Fruit", placeholder: "Apple",
            kind: .choice(CommandChoices(id: "fruits") {
                [ActionOption.Choice("apple", title: "Apple"), ActionOption.Choice("pear", title: "Pear")]
            }))
    }

    func resolve(_ invocation: CommandInvocation) async throws -> CommandOutcome {
        .value(.text("picked \(invocation.input.text ?? "")"))
    }
}

/// Opens a file or folder that has to exist.
struct RevealCommand: Command {
    var id: String { "test.reveal" }
    var title: String { "Reveal" }
    var symbol: String { "folder" }
    var name: String { "reveal" }
    var argument: CommandArgument? { CommandArgument(title: "File", placeholder: "~/a.txt", kind: .path) }

    func resolve(_ invocation: CommandInvocation) async throws -> CommandOutcome {
        .value(.text(invocation.input.summary))
    }
}

/// Answers the report commands and `$kill` as two Linux hosts would, and
/// records which machines were asked.
final class HostShell: @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [Machine] = []

    var machines: [Machine] { lock.withLock { asked } }

    var shell: MachineShell {
        { [self] machine, script in
            lock.withLock { asked.append(machine) }
            if script.contains("uid=$(id -u)") {
                return "@@ system\nLinux\n@@ self\n9 8\n@@ uid\n1000\n@@ ps\n  812  1000 node\n@@ commands\n812 node server.js\n"
            }
            if script.contains("/proc/meminfo") {
                return "@@ system\nLinux\n@@ meminfo\nMemTotal: 1000 kB\nMemFree: 500 kB\n@@ ps\n    1     0  9000 systemd\n"
            }
            let path = script.contains("'/mnt/usb'") ? "/mnt/usb" : "/"
            return "Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/sda1 1000 400 600 40% \(path)\n---\next4"
        }
    }
}

/// Quick Actions for the form: resolutions and options from a real service,
/// runs only recorded.
@MainActor
final class RecordingActions: ActionsAPI {
    struct Run {
        var id: String
        var input: ActionInput
        var machine: Machine
        var usedResolution: Bool
        var delivery: ActionDelivery
        var summary: String?
    }

    let service: ActionsService
    private(set) var resolutions: [ActionInput] = []
    private(set) var runs: [Run] = []

    init(service: ActionsService) {
        self.service = service
    }

    func showActions(on input: ResolvedActionInput?) {}

    func resolve(_ command: any Command, input: ActionInput, options: ActionOptionValues?, machine: Machine) async -> CommandResolution? {
        resolutions.append(input)
        return await service.resolve(command, input: input, options: options, machine: machine)
    }

    func run(_ command: any Command, input: ActionInput, machine: Machine, resolution: CommandResolution?, delivery: ActionDelivery, summary: String?) async -> Bool {
        runs.append(Run(id: command.id, input: input, machine: machine, usedResolution: resolution != nil, delivery: delivery, summary: summary))
        return true
    }

    func options(for command: any Command) -> ActionOptionValues { service.options(for: command) }
    func setOptions(_ values: ActionOptionValues, for command: any Command) { service.setOptions(values, for: command) }
    var usage: [String: ActionUsage] { [:] }
    var userCommands: [UserCommand] { [] }
    func onUserFilesChanged(_ handler: @escaping @MainActor () -> Void) {}

    func commandPane(for command: any Command, typed: String?, resolution: CommandResolution?, loading: String?, refreshProblem: String?) -> AnyView {
        AnyView(EmptyView())
    }
}

/// The `$` form: opening, suggestions, keys, running and resolving
/// (docs/modules/COMMANDS.md, "The form" and "Suggestions").
@MainActor
@Suite struct CommandFormTests {
    let actions: RecordingActions
    let palette = FakePaletteHost()
    let scope: CommandsScope
    final class Sources {
        var pasteboard: String?
        var history: [RecentClipText] = []
        var pasteboardReads = 0
    }
    let sources = Sources()

    init() {
        let service = ActionsService(
            directory: FileManager.default.temporaryDirectory.appending(path: "CortexTests-form-\(UUID().uuidString)"),
            defaults: UserDefaults(suiteName: "CortexTests-\(UUID().uuidString)")!)
        actions = RecordingActions(service: service)
        let (actions, palette, sources) = (actions, palette, sources)
        scope = CommandsScope(
            commands: { CommandCatalog.builtIns + [EchoCommand(), FruitCommand(), RevealCommand()] },
            actions: { actions },
            palette: { palette },
            sources: CommandSuggestionSources(
                pasteboardText: {
                    sources.pasteboardReads += 1
                    return sources.pasteboard
                },
                recentTexts: { limit in Array(sources.history.prefix(limit)) }))
        scope.previewDelay = .zero
    }

    private func history(_ texts: String...) -> [RecentClipText] {
        texts.enumerated().map { RecentClipText(text: $1, copiedAt: .now.addingTimeInterval(-Double($0 + 1) * 60)) }
    }

    /// Types `$text` and presses ⏎ (or ⇥): the form that opened.
    private func open(_ text: String, tab: Bool = false) async throws -> CommandForm {
        scope.search(text)
        if tab {
            let key = try #require(scope.keys.first { $0.combo == .tab })
            #expect(key.perform?() == true)
        } else {
            #expect(scope.activate(.primary, target: .selected))
        }
        let command = try #require(scope.list.selected)
        let form = try #require(scope.forms[command.id])
        await form.loaded()
        await form.previewLoaded()
        return form
    }

    private var overlay: PaletteOverlay {
        get throws { try #require(palette.overlays.last) }
    }

    // MARK: - Opening

    @Test func returnWithoutTheArgumentOpensTheFormEmpty() async throws {
        sources.pasteboard = "3000"
        let form = try await open("port")
        #expect(palette.overlays.count == 1)
        #expect(palette.deliveries.isEmpty, "nothing runs on a suggestion")
        #expect(form.text == "", "the clipboard is never filled in")
        #expect(form.focus == .argument)
        #expect(form.shownSuggestions.map(\.value) == ["3000"])
        #expect(form.resolution == nil)
        #expect(try overlay.activationHints == [PaletteHint(.primary, "Run"), PaletteHint(.option, "Run and copy")])
    }

    @Test func tabOpensTheFormWithWhatWasTyped() async throws {
        let form = try await open("echo hi", tab: true)
        #expect(form.text == "hi")
        #expect(form.resolution?.result == .success(.value(.text("HI"))))
        #expect(scope.keys.first?.hint == "Fill in")
        #expect(try overlay.keys.map(\.hint) == ["Next field", nil], "⇥ and ⇧⇥ between the text and the case")
    }

    @Test func aTypedArgumentRunsWithoutTheForm() async throws {
        scope.search("echo hi")
        await scope.previewLoaded()
        #expect(scope.activate(.primary, target: .selected))
        #expect(palette.overlays.isEmpty)
        await palette.delivered()
        #expect(actions.runs.map(\.input) == [.text("hi")])
    }

    @Test func aPathThatIsNotThereOpensTheFormWithTheProblem() async throws {
        let form = try await open("reveal ~/surely-not-here-\(UUID().uuidString)")
        #expect(form.problem?.hasPrefix("File: no file or folder at ~/surely-not-here-") == true)
        #expect(try overlay.dropFiles != nil, "a dropped file fills the field")
    }

    // MARK: - Suggestions

    @Test func suggestionsListThePasteboardThenTheHistory() async throws {
        sources.pasteboard = "zebra"
        sources.history = history("zebra", "Not lowercase", "apple", "banana", "apple")
        let form = try await open("echo")
        #expect(form.shownSuggestions.map(\.value) == ["zebra", "apple", "banana"])
        #expect(form.shownSuggestions.first?.source == .clipboard)
        #expect(sources.pasteboardReads == 1)

        // Esc and ⏎ again: the same form, the pasteboard not read again.
        scope.search("echo")
        #expect(scope.activate(.primary, target: .selected))
        await form.loaded()
        #expect(scope.forms["test.echo"] === form)
        #expect(sources.pasteboardReads == 1)
    }

    @Test func downPutsASuggestionIntoTheFieldAndUpGoesBack() async throws {
        sources.history = history("apple", "banana", "cherry")
        let form = try await open("echo")
        let overlay = try overlay
        let move = try #require(overlay.move)
        #expect(!move(.vertical(-1)), "nothing above the field: it gets the key")

        #expect(move(.vertical(1)))
        #expect(form.text == "apple")
        #expect(move(.vertical(1)))
        #expect(form.text == "banana")
        await form.previewLoaded()
        #expect(form.resolution?.result == .success(.value(.text("BANANA"))), "the preview follows the field")
        #expect(move(.vertical(5)))
        #expect(form.text == "cherry", "stays on the last")
        #expect(move(.vertical(-1)) && move(.vertical(-1)) && move(.vertical(-1)))
        #expect(form.text == "", "back to what was typed")

        form.text = "an"
        #expect(form.shownSuggestions.map(\.value) == ["banana"], "typing filters")
        #expect(move(.vertical(1)))
        #expect(form.text == "banana")
        form.pick(0)
        #expect(form.text == "banana")
    }

    @Test func aChoiceArgumentListsItsChoicesAndMatchesByTitle() async throws {
        let form = try await open("fruit")
        #expect(form.shownSuggestions.map(\.value) == ["Apple", "Pear"])
        form.text = "pear"
        await form.previewLoaded()
        #expect(form.value == .success(.text("pear")))
        #expect(form.resolution?.result == .success(.value(.text("picked pear"))))
        form.text = "Plum"
        #expect(form.problem == "Fruit: “Plum” is not in the list")
        #expect(try overlay.move?(.vertical(1)) == false, "no suggestion matches")
    }

    // MARK: - Running

    @Test func returnOnAnEmptyRequiredFieldRunsNothing() async throws {
        let form = try await open("echo")
        try overlay.activate(.primary)
        #expect(form.isMarked)
        #expect(palette.deliveries.isEmpty)
        form.text = "x"
        #expect(!form.isMarked, "typing clears the mark")
    }

    @Test func returnRunsWithTheValueAndRemembersTheOptions() async throws {
        let form = try await open("echo")
        form.text = "Hello"
        form.setOption(EchoCommand.letterCase, to: "lower")
        #expect(actions.options(for: EchoCommand())[EchoCommand.letterCase] == "upper", "not remembered while typing")
        await form.previewLoaded()
        #expect(form.resolution?.result == .success(.value(.text("hello"))))

        try overlay.activate(.option)
        #expect(palette.deliveries.map(\.action) == [.copyOnly])
        #expect(actions.options(for: EchoCommand())[EchoCommand.letterCase] == "lower")
        await palette.delivered()
        let run = try #require(actions.runs.first)
        #expect(run.input == .text("Hello"))
        #expect(run.usedResolution, "the previewed result")
        #expect(run.delivery == .copy)
        #expect(run.summary == "$echo Hello")
    }

    @Test func aFailedPreviewBeepsInsteadOfRunning() async throws {
        let form = try await open("echo")
        form.text = "fail"
        await form.previewLoaded()
        #expect(form.resolution?.result == .failure(QuickActionError("Cannot echo “fail”")))
        try overlay.activate(.primary)
        #expect(palette.deliveries.isEmpty)
    }

    @Test func choicesMoveWithTheSideArrows() async throws {
        let form = try await open("echo")
        let move = try #require(try overlay.move)
        #expect(!move(.sideways(1)), "the text field moves its cursor")
        form.focusNext()
        #expect(form.focus == .option("case"))
        #expect(move(.sideways(1)))
        #expect(form.options[EchoCommand.letterCase] == "lower")
        #expect(move(.sideways(1)))
        #expect(form.options[EchoCommand.letterCase] == "lower", "stays on the last")
        form.focusNext()
        #expect(form.focus == .argument, "⇥ wraps around")
        form.focusNext(false)
        #expect(form.focus == .option("case"))
    }

    @Test func shiftReturnBreaksALineInAPrompt() async throws {
        let ask = AICommand.all(vendor: .openAI, textModel: "t", imageModel: "i") { _ in throw QuickActionError("not sent") }[0]
        let scope = CommandsScope(commands: { [ask] }, actions: { actions }, palette: { palette })
        scope.search("ask")
        #expect(scope.activate(.primary, target: .selected))
        let form = try #require(scope.forms["ai.ask"])
        #expect(form.breaksLines)
        try overlay.activate(.shift)
        #expect(palette.deliveries.isEmpty, "⇧⏎ only breaks the line")
        form.text = "why"
        try overlay.activate(.shift)
        #expect(palette.deliveries.isEmpty)
        try overlay.activate(.primary)
        #expect(palette.deliveries.count == 1)
    }

    // MARK: - Hosts

    private func hostScope(_ shell: HostShell) -> CommandsScope {
        let (actions, palette) = (actions, palette)
        let startup = VolumeSpace(name: "Macintosh HD", path: "/", total: 1_000_000, available: 400_000)
        let scope = CommandsScope(
            commands: { [MemoryUsageCommand(shell: shell.shell), DiskSpaceCommand(volumes: { [startup] }, shell: shell.shell)] },
            actions: { actions },
            palette: { palette },
            hosts: { ["raspberrypi", "linode"] })
        scope.previewDelay = .zero
        return scope
    }

    private func openForm(_ text: String, in scope: CommandsScope) async throws -> CommandForm {
        scope.search(text)
        let key = try #require(scope.keys.first { $0.combo == .tab })
        #expect(key.perform?() == true)
        let command = try #require(scope.list.selected)
        let form = try #require(scope.forms[command.id])
        await form.loaded()
        await form.previewLoaded()
        return form
    }

    @Test func theHostFieldComesAfterTheArgumentAndStartsAtThisMac() async throws {
        let shell = HostShell()
        let scope = hostScope(shell)
        let disk = try await openForm("disk", in: scope)
        #expect(disk.fields == [.argument, .host], "⇥ order: argument, host, options")
        #expect(disk.focus == .argument)
        #expect(disk.machine == .local && disk.hostValue == "")
        #expect(disk.hostOption.kind == .choice([
            ActionOption.Choice("", title: "This Mac"), ActionOption.Choice("raspberrypi", title: "raspberrypi"),
            ActionOption.Choice("linode", title: "linode"),
        ]))
        let mem = try await openForm("mem", in: scope)
        #expect(mem.fields == [.host] && mem.focus == .host && mem.argument == nil)
        #expect(scope.keys.map(\.hint) == ["Host"])
        #expect(try overlay.keys.isEmpty, "one field: nothing to tab to")
        #expect(shell.machines.isEmpty, "this Mac is read directly")

        let echo = try await open("echo", tab: true)
        #expect(echo.fields == [.argument, .option("case")], "no host for a command that does not run on hosts")
    }

    @Test func aTypedHostFillsItIn() async throws {
        let shell = HostShell()
        let scope = hostScope(shell)
        let form = try await openForm("disk /mnt/usb @linode", in: scope)
        #expect(form.machine == .ssh("linode") && form.hostValue == "linode")
        #expect(form.text == "/mnt/usb")
        #expect(form.argument?.title == "Path", "a path on the host, not a volume")
        #expect(form.value == .success(.text("/mnt/usb")))
        #expect(form.problem == nil && form.suggestions.isEmpty)
        guard case .success(.value(.report(let report), _)) = form.resolution?.result, let volume = report.content as? VolumeSpace else {
            throw QuickActionError("no volume")
        }
        #expect(volume.path == "/mnt/usb" && volume.host == "linode")
        #expect(form.resolution?.machine == .ssh("linode") && form.currentResolution != nil)

        let mem = try await openForm("mem @raspberrypi", in: scope)
        #expect(mem.machine == .ssh("raspberrypi"))
        scope.clear()
        let nothing = try await openForm("disk @nas", in: scope)
        #expect(nothing.machine == .local, "a host that is not there fills in nothing; the pane said so")
    }

    @Test func theHostIsPickedWithTheSideArrows() async throws {
        let shell = HostShell()
        let scope = hostScope(shell)
        let form = try await openForm("mem", in: scope)
        let move = try #require(try overlay.move)
        #expect(move(.sideways(1)) && form.machine == .ssh("raspberrypi"))
        #expect(move(.sideways(1)) && form.machine == .ssh("linode"))
        #expect(move(.sideways(1)) && form.machine == .ssh("linode"), "stays on the last")
        await form.previewLoaded()
        #expect(form.currentResolution?.machine == .ssh("linode"))
        #expect(move(.sideways(-1)) && move(.sideways(-1)) && form.machine == .local)
        #expect(form.currentResolution == nil, "the result of another machine is not the form's")
        form.setHost("nas")
        #expect(form.machine == .local, "only an alias in ~/.ssh/config")
        form.setHost("linode")
        #expect(form.machine == .ssh("linode"))
    }

    @Test func theArgumentFollowsTheHost() async throws {
        let shell = HostShell()
        let scope = hostScope(shell)
        let form = try await openForm("disk", in: scope)
        #expect(form.argument?.title == "Volume" && form.shownSuggestions.map(\.value) == ["Macintosh HD"])
        form.text = "/mnt/usb"
        #expect(form.problem == "Volume: “/mnt/usb” is not in the list")
        form.setHost("raspberrypi")
        await form.loaded()
        await form.previewLoaded()
        #expect(form.problem == nil && form.shownSuggestions.isEmpty)
        #expect(form.currentResolution?.machine == .ssh("raspberrypi"))
        form.setHost("")
        await form.loaded()
        #expect(form.problem == "Volume: “/mnt/usb” is not in the list")
        #expect(form.suggestions.map(\.value) == ["Macintosh HD"], "the volumes again")
    }

    @Test func theHostIsPassedToTheRunAndNeverRemembered() async throws {
        let shell = HostShell()
        let scope = hostScope(shell)
        let form = try await openForm("disk", in: scope)
        form.setHost("raspberrypi")
        form.text = "/mnt/usb"
        await form.loaded()
        await form.previewLoaded()
        try overlay.activate(.primary)
        await palette.delivered()
        let run = try #require(actions.runs.first)
        #expect(run.machine == .ssh("raspberrypi") && run.input == .text("/mnt/usb"))
        #expect(run.usedResolution, "made for the same machine")
        #expect(run.summary == "$disk /mnt/usb @raspberrypi")
        #expect(actions.options(for: DiskSpaceCommand()).values.isEmpty, "not an option")

        // The palette hid: the next form starts at This Mac.
        scope.clear()
        let again = try await openForm("disk", in: scope)
        #expect(again.machine == .local && again !== form)
        try overlay.activate(.primary)
        await palette.delivered()
        #expect(actions.runs.last?.machine == .local && actions.runs.last?.summary == "$disk")
    }

    // MARK: - Keeping values

    @Test func escKeepsTheValuesAndClearDropsThem() async throws {
        let form = try await open("echo")
        form.text = "30"
        // Esc: the palette drops the overlay; the scope keeps the form.
        scope.search("echo")
        #expect(scope.activate(.primary, target: .selected))
        #expect(scope.forms["test.echo"]?.text == "30")
        #expect(palette.overlays.count == 2)

        scope.clear()
        #expect(scope.forms.isEmpty)
        scope.search("echo")
        #expect(scope.activate(.primary, target: .selected))
        #expect(scope.forms["test.echo"]?.text == "")
    }

    @Test func aDroppedFileFillsAPathField() async throws {
        let form = try await open("reveal")
        let drop = try #require(try overlay.dropFiles)
        let home = URL.homeDirectory
        #expect(drop([home.appending(path: "Read Me.txt")]))
        #expect(form.text == "'~/Read Me.txt'")
        #expect(CommandForm.typedPath(URL(filePath: "/tmp/a.txt"), home: home) == "/tmp/a.txt")
        #expect(CommandForm.typedPath(home.appending(path: "Desktop"), home: home) == "~/Desktop")

        #expect(drop([URL(filePath: "/tmp")]))
        #expect(form.value == .success(.files([URL(filePath: "/tmp")])))
        try overlay.activate(.primary)
        #expect(palette.deliveries.count == 1)
    }

    @Test func otherFormsTakeNoFiles() async throws {
        _ = try await open("echo")
        #expect(try overlay.dropFiles == nil)
    }
}
