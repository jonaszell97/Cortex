import AppKit
import Carbon.HIToolbox
import Testing
@testable import Cortex
import CortexCore

/// The palette's `>` scope: input, filtering, previews.
@MainActor
@Suite struct ActionsScopeTests {
    let scope: ActionsScope
    let service: ActionsService
    let directory: URL
    let palette = FakePaletteHost()
    final class Resolver {
        var input = ResolvedActionInput(input: .text("{\"b\":1,\"a\":2}"), source: .pasteboard)
        var calls = 0
    }
    let resolver = Resolver()
    let defaults = UserDefaults(suiteName: "CortexTests-\(UUID().uuidString)")!

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "CortexTests-actions-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        service = ActionsService(directory: directory, defaults: defaults)
        let (resolver, palette) = (resolver, palette)
        scope = ActionsScope(
            service: service,
            resolveInput: {
                resolver.calls += 1
                return resolver.input
            },
            palette: { palette })
    }

    @Test func listsTheActionsForTheResolvedInput() {
        scope.search("")
        #expect(resolver.calls == 1)
        #expect(scope.context?.source == .pasteboard)
        #expect(scope.list.items.first?.id == "text.json.pretty")
        #expect(!scope.list.items.contains { $0.id == "file.video.gif" }, "only actions that take text")
        #expect(scope.list.selected?.id == "text.json.pretty")
    }

    @Test func longTextIsPreviewedOffTheMainThread() async {
        let long = String(repeating: "word ", count: 10_000)
        resolver.input = ResolvedActionInput(input: .text(long), source: .pasteboard)
        scope.search("upper")
        #expect(scope.list.selected?.id == "text.uppercase")
        #expect(service.preview(action("text.uppercase"), input: .text(long)) == nil, "too long to transform here")
        await scope.previewLoaded()
        #expect(scope.preview?.result == .success(.text(long.uppercased())))
    }

    func action(_ id: String) -> any QuickAction {
        service.allActions.first { $0.id == id }!
    }

    @Test func typingFiltersAndKeepsTheInput() {
        scope.search("")
        scope.search("mini")
        #expect(scope.list.items.first?.id == "text.json.minify")
        #expect(scope.list.selected?.id == "text.json.minify")
        #expect(resolver.calls == 1, "the input is read once per palette show")
    }

    @Test func instantActionsArePreviewed() {
        scope.search("json")
        #expect(scope.preview?.actionID == "text.json.pretty")
        guard case .success(.text(let text)) = scope.preview?.result else {
            Issue.record("expected a text preview")
            return
        }
        #expect(text == "{\n  \"b\": 1,\n  \"a\": 2\n}")

        scope.move(.vertical(1))
        #expect(scope.list.selected?.id == "text.json.minify")
        guard case .success(.text(let minified)) = scope.preview?.result else {
            Issue.record("expected a text preview")
            return
        }
        #expect(minified == #"{"b":1,"a":2}"#)
    }

    @Test func previewShowsErrors() {
        resolver.input = ResolvedActionInput(input: .text("not json"), source: .pasteboard)
        scope.search("format json")
        guard case .failure(let error) = scope.preview?.result else {
            Issue.record("expected an error")
            return
        }
        #expect(error.message.hasPrefix("Not valid JSON"))
    }

    @Test func backgroundActionsHaveNoPreview() {
        scope.handIn(ResolvedActionInput(input: .files([URL(filePath: "/tmp/IMG_1.HEIC")]), source: .finder))
        scope.search("")
        #expect(resolver.calls == 0, "a given input is not replaced")
        #expect(scope.list.items.first?.id == "file.image.jpg")
        #expect(scope.preview == nil)
    }

    @Test func aHandedInInputIsKeptUntilThePaletteHides() {
        scope.handIn(ResolvedActionInput(input: .text("hello"), source: .clip))
        scope.search("")
        #expect(scope.context?.source == .clip)
        // Leaving and coming back keeps the clip as input.
        scope.didLeave()
        scope.search("")
        #expect(scope.context?.source == .clip)
        #expect(resolver.calls == 0)

        scope.clear()
        #expect(scope.context == nil)
        #expect(scope.list.isEmpty)
        scope.search("")
        #expect(resolver.calls == 1)
    }

    @Test func handingInWhileShowingListsAgain() {
        scope.search("")
        scope.handIn(ResolvedActionInput(input: .files([URL(filePath: "/tmp/a.mov")]), source: .dropped))
        #expect(scope.context?.source == .dropped)
        #expect(scope.list.items.contains { $0.id == "file.video.gif" })
    }

    @Test func nothingToWorkOn() {
        resolver.input = ResolvedActionInput(input: .none, source: .pasteboard)
        scope.search("")
        #expect(scope.list.items.map(\.id) == ["generate.uuid", "generate.isodate"])
    }

    @Test func optionsChangeThePreviewAndAreRemembered() throws {
        resolver.input = ResolvedActionInput(input: .text("42"), source: .pasteboard)
        scope.search("pad")
        #expect(scope.list.selected?.id == "text.pad")
        #expect(scope.options[PadOptions.length] == "10")
        #expect(scope.preview?.result == .success(.text("0000000042")))
        #expect(scope.keys.map(\.hint) == ["Options"], "⇥ moves into the options")

        scope.setOption(PadOptions.length, to: "4")
        scope.setOption(PadOptions.character, to: " ")
        #expect(scope.preview?.result == .success(.text("  42")))
        scope.setOption(PadOptions.length, to: "")
        #expect(scope.preview?.result == .failure(QuickActionError("Length must be a whole number from 1 to 1000")))
        scope.setOption(PadOptions.length, to: "5")

        // Another action has its own (no) options; coming back restores these.
        scope.search("upper")
        #expect(scope.options == ActionOptionValues())
        scope.search("pad")
        #expect(scope.options[PadOptions.length] == "5")

        // Remembered across palette shows and launches.
        scope.clear()
        let relaunched = ActionsService(directory: directory, defaults: defaults)
        let pad = try #require(relaunched.allActions.first { $0.id == "text.pad" })
        #expect(relaunched.preview(pad, input: .text("42"))?.result == .success(.text("   42")))
    }

    @Test func aNewSelectionMovesFocusBackToTheSearchField() {
        scope.search("json")
        let before = palette.focusRequests
        scope.move(.vertical(1))
        #expect(palette.focusRequests == before + 1)
    }

    @Test func returnRunsTheAction() async {
        // A `.done` result touches no pasteboard.
        scope.search("count words")
        #expect(scope.list.selected?.id == "text.count")
        #expect(scope.activate(.option, target: .selected))
        #expect(palette.deliveries.map(\.action) == [.copyOnly])
        await palette.delivered()
        #expect(service.rank(for: .text("x"), query: "").first?.id == "text.count", "it ran and counts as used")
    }

    @Test func resultsReplaceASelection() {
        #expect(ActionsScope.delivery(copyOnly: false, source: .selection, target: nil) == .replaceSelection(nil))
        #expect(ActionsScope.delivery(copyOnly: false, source: .clip, target: nil) == .paste(nil))
        #expect(ActionsScope.delivery(copyOnly: true, source: .selection, target: nil) == .copy)
    }

    @Test func commandKOpensActions() {
        let event = PaletteKeyMap.event(keyCode: kVK_ANSI_K, modifiers: .command, characters: "k")
        #expect(event == .combo(.command("k")))
    }
}

@MainActor
@Suite struct ActionsServiceTests {
    let directory: URL
    let defaults: UserDefaults

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "CortexTests-actions-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "CortexTests-\(UUID().uuidString)")!
    }

    @Test func loadsAndReloadsUserActions() async throws {
        let service = ActionsService(directory: directory, defaults: defaults)
        try "name = 'Sort lines'\naccepts = ['text']\ncommand = 'sort'".write(
            to: directory.appending(path: "sort.toml"), atomically: true, encoding: .utf8)
        service.start()
        #expect(service.userActions.map(\.title) == ["Sort lines"])
        #expect(service.rank(for: .text("b\na"), query: "sort").first?.id == "user.sort")

        // Edited in place (as most editors save): the watcher reloads it.
        let handle = try FileHandle(forWritingTo: directory.appending(path: "sort.toml"))
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("name = 'Sort'\naccepts = ['text']\ncomand = 'sort'".utf8))
        try handle.close()
        for _ in 0..<50 where service.problems.isEmpty {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(service.userActions.isEmpty)
        #expect(service.problems.map(\.message) == ["Unknown key “comand”"])
    }

    @Test func usageIsRememberedAcrossLaunches() async {
        let service = ActionsService(directory: directory, defaults: defaults)
        // A `.done` result touches no pasteboard.
        let count = service.allActions.first { $0.id == "text.count" }!
        await service.run(count, input: .text("a b"), delivery: .copy)

        let again = ActionsService(directory: directory, defaults: defaults)
        #expect(again.rank(for: .text("x"), query: "").first?.id == "text.count")
    }

    @Test func createSnippetOpensTheEditor() async {
        let service = ActionsService(directory: directory, defaults: defaults)
        #expect(!service.allActions.contains { $0.id == TextAction.createSnippetID }, "hidden without snippets")

        var requests: [SnippetEditRequest] = []
        service.editSnippet = { requests.append($0) }
        let create = service.rank(for: .text("Hi {name}"), query: "create snippet").first!
        #expect(create.id == TextAction.createSnippetID)
        let changeCount = NSPasteboard.general.changeCount
        await service.run(create, input: .text("Hi {name}"), delivery: .paste(nil))
        #expect(requests == [.new(body: "Hi {name}")])
        #expect(NSPasteboard.general.changeCount == changeCount, "nothing is pasted or copied")
    }

    @Test func saveAsCommandAsksForANameThenConfirms() async throws {
        let service = ActionsService(directory: directory, defaults: defaults)
        var requests: [ActionsService.CommandNameRequest] = []
        var names = ["kill", "up"]
        service.askCommandName = { requests.append($0); return names.removeFirst() }
        var questions: [ActionConfirmation] = []
        service.confirm = { questions.append($0); return true }
        let save = service.rank(for: .text("$ docker compose up -d"), query: "save as command").first!
        #expect(save.id == TextAction.saveCommandID)
        #expect(!service.shortcutActions.contains { $0.id == save.id }, "it asks for a name")
        let changeCount = NSPasteboard.general.changeCount

        await service.run(save, input: .text("$ docker compose up -d"), delivery: .replaceSelection(nil))
        #expect(requests == [
            .init(command: "docker compose up -d"),
            .init(command: "docker compose up -d", name: "kill", problem: "“kill” is the name of a built-in command"),
        ])
        #expect(questions.map(\.title) == ["Save $up?"])
        #expect(questions.first?.isDestructive == false)
        for job in service.jobs { await job.task?.value }
        #expect(NSPasteboard.general.changeCount == changeCount, "nothing is pasted or copied")

        service.reload()
        #expect(service.problems.isEmpty)
        #expect(service.userCommands.map(\.name) == ["up"])
        #expect(service.userCommands.first?.file.lastPathComponent == "up.toml")
    }

    @Test func saveAsCommandCancelledSavesNothing() async throws {
        let service = ActionsService(directory: directory, defaults: defaults)
        var asked = 0
        service.askCommandName = { _ in asked += 1; return nil }
        service.confirm = { _ in Issue.record("not confirmed without a name"); return true }
        let save = try #require(service.allActions.first { $0.id == TextAction.saveCommandID })
        await service.run(save, input: .text("ls"), delivery: .copy)
        #expect(asked == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func shortcutsUseTheRememberedOptions() async throws {
        let service = ActionsService(directory: directory, defaults: defaults)
        await #expect(throws: QuickActionError("Quick Actions are switched off in Cortex Settings")) {
            try await service.runForIntent(actionID: "text.pad", input: .text("7"))
        }
        service.start()
        defer { service.stop() }
        let pad = try #require(service.allActions.first { $0.id == "text.pad" })
        #expect(try await service.runForIntent(actionID: pad.id, input: .text("7")) == .text("0000000007"))
        var options = service.options(for: pad)
        options[PadOptions.side] = "right"
        options[PadOptions.length] = "3"
        options.values["unknown"] = "dropped"
        service.setOptions(options, for: pad)
        #expect(service.options(for: pad).values == ["side": "right", "length": "3"])
        #expect(try await service.runForIntent(actionID: pad.id, input: .text("7")) == .text("700"))
    }

    @Test func previewSkipsHugeText() {
        let service = ActionsService(directory: directory, defaults: defaults)
        let upper = service.allActions.first { $0.id == "text.uppercase" }!
        #expect(service.preview(upper, input: .text("abc")) != nil)
        #expect(service.preview(upper, input: .text(String(repeating: "a", count: ActionsService.previewLimit + 1))) == nil)
        let gif = service.allActions.first { $0.id == "file.video.gif" }!
        #expect(service.preview(gif, input: .files([URL(filePath: "/tmp/a.mov")])) == nil)
    }
}

/// Turning clips and pasteboard content into action input.
@MainActor
@Suite struct ActionInputTests {
    let board = TestPasteboard()

    @Test func textAndRichTextBecomeText() {
        board.write([(.rtf, rtfData("Bold")), (.string, Data("Bold".utf8))])
        #expect(ResolvedActionInput.pasteboard(board.pasteboard).input == .text("Bold"))
    }

    @Test func filesBecomeFiles() {
        let urls = [URL(filePath: "/tmp/a.heic"), URL(filePath: "/tmp/b c.mov")]
        board.pasteboard.clearContents()
        board.pasteboard.writeObjects(urls as [NSURL])
        #expect(ResolvedActionInput.pasteboard(board.pasteboard).input == .files(urls))
    }

    @Test func imagesBecomeImages() {
        let png = imageData(.png)
        board.write([(.png, png)])
        #expect(ResolvedActionInput.pasteboard(board.pasteboard).input == .image(png))
    }

    @Test func emptyIsNothing() {
        board.pasteboard.clearContents()
        #expect(ResolvedActionInput.pasteboard(board.pasteboard).input == .none)
    }

    @Test func passwordManagerCopiesAreSensitive() {
        board.write([(.string, Data("hunter2".utf8)), (Paster.concealedType, Data())])
        #expect(ResolvedActionInput.pasteboard(board.pasteboard).isSensitive)
        board.write([(.string, Data("plain".utf8))])
        #expect(!ResolvedActionInput.pasteboard(board.pasteboard).isSensitive)
    }

    @Test func textThatLooksLikeAKeyIsSensitive() {
        board.write([(.string, Data("q8Zr3TfL0pW7xYv2Nc5Ka9Hd".utf8))])
        #expect(ResolvedActionInput.pasteboard(board.pasteboard).isSensitive)
    }

    @Test func imageResultsGoOnThePasteboardAsPNGAndTIFF() {
        Paster.write(image: imageData(.png), recording: .record(sensitive: false), to: board.pasteboard)
        let types = Set((board.pasteboard.types ?? []).map(\.rawValue))
        #expect(types.isSuperset(of: ["public.png", "public.tiff"]))
    }
}

/// Reading the selection of another app by copying it.
@MainActor
@Suite struct SelectionReaderTests {
    let board = TestPasteboard()

    func reader(copying content: [(NSPasteboard.PasteboardType, Data)]?) -> SelectionReader {
        let board = board
        return SelectionReader(
            activity: PasteboardActivity(), pasteboard: board.pasteboard,
            copy: { if let content { board.write(content) } },
            timeout: .milliseconds(50))
    }

    @Test func readsTheSelectionAndPutsTheClipboardBack() async throws {
        let rtf = rtfData("Before")
        board.write([(.rtf, rtf), (.string, Data("Before".utf8))])

        let result = try await reader(copying: [(.string, Data("selected".utf8))]).read().get()

        #expect(result.input == .text("selected"))
        #expect(result.source == .selection)
        #expect(board.pasteboard.string(forType: .string) == "Before")
        #expect(board.pasteboard.data(forType: .rtf) == rtf)
        let types = (board.pasteboard.types ?? []).map(\.rawValue)
        #expect(types.contains(Paster.ownMarkerType.rawValue), "putting it back is not recorded")
    }

    @Test func nothingSelectedLeavesTheClipboardAlone() async {
        board.write([(.string, Data("Before".utf8))])
        let changeCount = board.pasteboard.changeCount

        let result = await reader(copying: nil).read()

        #expect(throws: QuickActionError.self) { try result.get() }
        #expect(board.pasteboard.changeCount == changeCount)
    }

    @Test func selectedFilesAreNotText() async {
        let url = URL(filePath: "/tmp/a.txt")
        let content = { () -> [(NSPasteboard.PasteboardType, Data)] in
            [(.fileURL, Data(url.absoluteString.utf8))]
        }
        let result = await reader(copying: content()).read()
        #expect(throws: QuickActionError.self) { try result.get() }
    }

    @Test func passwordManagerSelectionsAreSensitive() async throws {
        let result = try await reader(copying: [(.string, Data("hunter2".utf8)), (Paster.concealedType, Data())]).read().get()
        #expect(result.isSensitive)
    }
}

/// What `>` makes of typed text and commands now that `$` takes typed input.
@MainActor
@Suite struct ActionsWithoutTypedInputTests {
    let directory: URL
    let service: ActionsService
    let scope: ActionsScope
    final class Resolver {
        var input = ResolvedActionInput(input: .text("clipboard"), source: .pasteboard)
    }
    let resolver = Resolver()

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "CortexTests-actions-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "name = 'GitHub Repository'\ntrigger = 'gh'\nurl = 'https://github.com/{argument}'"
            .write(to: directory.appending(path: "gh.toml"), atomically: true, encoding: .utf8)
        try "name = 'Track'\naccepts = ['text']\ntrigger = 'track'\nmatches = '^1Z[0-9A-Z]+$'\nurl = 'https://ups.com/{argument}'"
            .write(to: directory.appending(path: "track.toml"), atomically: true, encoding: .utf8)
        service = ActionsService(directory: directory, defaults: UserDefaults(suiteName: "CortexTests-\(UUID().uuidString)")!)
        service.reload()
        let resolver = resolver
        scope = ActionsScope(service: service, resolveInput: { resolver.input }, palette: { FakePaletteHost() })
    }

    @Test func whatIsTypedOnlySearches() {
        scope.search("port 3000")
        #expect(scope.list.isEmpty, "no trigger words in >")
        scope.search("kill")
        #expect(!scope.list.items.contains { $0.id == "command.kill" }, "commands wait for $")
        #expect(scope.input?.source == .pasteboard, "the input is still the clipboard")
    }

    @Test func aCopiedPortNumberOffersKillProcessOnPort() throws {
        resolver.input = ResolvedActionInput(input: .text("3000"), source: .pasteboard)
        scope.search("")
        #expect(scope.list.items.contains { $0.id == "command.port" })
        #expect(scope.input?.source == .pasteboard)
    }

    @Test func aCopiedPathOffersOpenInFinder() throws {
        let folder = FileManager.default.temporaryDirectory.path(percentEncoded: false)
        resolver.input = ResolvedActionInput(input: .text(folder), source: .pasteboard)
        scope.search("")
        #expect(scope.list.items.map(\.id).contains("command.open"))
        scope.clear()
        resolver.input = ResolvedActionInput(input: .files([URL(filePath: folder)]), source: .finder)
        scope.search("")
        #expect(scope.list.items.contains { $0.id == "command.open" }, "selected in Finder too")
        scope.clear()
        resolver.input = ResolvedActionInput(input: .text("hello"), source: .pasteboard)
        scope.search("")
        #expect(!scope.list.items.contains { $0.id == "command.open" || $0.id == "command.port" })
    }

    @Test func commandsInActionsAreTheirAdapters() throws {
        resolver.input = ResolvedActionInput(input: .text("3000"), source: .pasteboard)
        scope.search("")
        let port = try #require(scope.list.items.first { $0.id == "command.port" })
        #expect(port is CommandAction)
        #expect(ActionRowView.detail(for: port) == nil, "a lookup, not a background job")
    }

    @Test func userFilesWithATriggerAreCommands() {
        #expect(service.userCommands.map(\.title) == ["GitHub Repository", "Track"])
        #expect(service.userActions.map(\.title) == ["Track"], "only the file that also accepts text")
        #expect(!service.allActions.contains { $0.id == "user.gh" })
        #expect(!service.rank(for: .text("hello"), query: "track").contains { $0.id == "user.track" }, "only text it matches")
        #expect(service.rank(for: .text("1Z999AA1"), query: "").contains { $0.id == "user.track" })
    }

    @Test func shortcutsGetNoCommands() {
        #expect(!service.shortcutActions.contains { $0 is CommandAction })
        #expect(service.allActions.contains { $0.id == "command.port" }, "> has them")
        #expect(service.shortcutActions.contains { $0.id == "user.track" })
    }
}

/// Results that ask before going ahead.
@MainActor
@Suite struct ActionConfirmationTests {
    actor Runs {
        var count = 0
        func add() { count += 1 }
    }

    struct Confirming: QuickAction {
        let id = "test.confirm"
        let title = "Confirming"
        let symbol = "questionmark"
        let runs: Runs
        var isInstant: Bool { true }
        func accepts(_ input: ActionInput) -> Bool { true }
        func run(_ input: ActionInput, context: ActionContext) async throws -> ActionOutput {
            .confirm(ActionConfirmation(title: "Really?", message: "It cannot be undone.", confirmTitle: "Do It") { [runs] in
                await runs.add()
                return .done("Done")
            })
        }
    }

    let service: ActionsService

    init() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "CortexTests-actions-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        service = ActionsService(directory: directory, defaults: UserDefaults(suiteName: "CortexTests-\(UUID().uuidString)")!)
    }

    @Test func cancelledRunsNothing() async {
        let runs = Runs()
        var questions: [String] = []
        service.confirm = { questions.append($0.title); return false }
        await service.run(Confirming(runs: runs), input: .none, delivery: .paste(nil))
        #expect(questions == ["Really?"])
        #expect(await runs.count == 0)
    }

    /// A confirmed step runs as a job.
    func finishJobs() async {
        for job in service.jobs { await job.task?.value }
    }

    @Test func confirmedRunsOnceAsAJob() async {
        let runs = Runs()
        service.confirm = { _ in true }
        let changeCount = NSPasteboard.general.changeCount
        await service.run(Confirming(runs: runs), input: .none, delivery: .paste(nil))
        #expect(service.jobs.map(\.title) == ["Confirming"])
        #expect(service.jobs.first?.inputSummary == "Really")
        await finishJobs()
        #expect(service.jobs.isEmpty)
        #expect(await runs.count == 1)
        #expect(NSPasteboard.general.changeCount == changeCount, "a `.done` result is only a notification")
    }

    @Test func thePreviewedConfirmationIsTheOneAsked() async throws {
        let runs = Runs()
        let action = Confirming(runs: runs)
        let preview = try #require(await service.previewAsync(action, input: .none))
        #expect(preview.result == .success(.confirm(ActionConfirmation(title: "Really?", message: "It cannot be undone.", confirmTitle: "Do It") { .done("") })))
        var questions: [String] = []
        service.confirm = { questions.append($0.message); return true }
        await service.run(action, input: .none, preview: preview, delivery: .copy)
        await finishJobs()
        #expect(questions == ["It cannot be undone."])
        #expect(await runs.count == 1)
    }
}
