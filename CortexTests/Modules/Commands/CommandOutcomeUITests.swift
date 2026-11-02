import AppKit
import SwiftUI
import Testing
@testable import Cortex
import CortexCore

/// Records what is copied or pasted instead of touching the pasteboard.
@MainActor
final class RecordingPasteService: PasteService {
    struct Write: Equatable {
        var text: String
        var recording: Paster.Recording
        var pasted: Bool
    }

    private(set) var writes: [Write] = []

    override func write(_ content: PasteContent, mode: Paster.Mode = .rich, recording: Paster.Recording = .skip) {
        if case .text(let text) = content { writes.append(Write(text: text, recording: recording, pasted: false)) }
    }

    override func deliver(
        _ content: PasteContent, _ action: PasteAction, recording: Paster.Recording = .skip, charactersAfterCursor: Int = 0,
        restoringPasteboard: Bool = false, into target: NSRunningApplication?
    ) async -> Bool {
        if case .text(let text) = content { writes.append(Write(text: text, recording: recording, pasted: action != .copyOnly)) }
        return true
    }
}

/// Records the notifications instead of posting them.
@MainActor
final class RecordingNotifier: Notifier {
    struct Post: Equatable {
        var title: String
        var body: String
    }

    private(set) var posts: [Post] = []

    override func post(title: String, body: String, revealing files: [URL] = []) {
        posts.append(Post(title: title, body: body))
    }
}

/// What the `$` pane and hints do with each kind of outcome: what ⏎ and ⌥⏎
/// are called and do, the value that is refreshed while it is shown, and
/// nothing to do as a notice (docs/modules/COMMANDS.md, "The hints", "Live
/// refresh" and "Nothing to do").
@MainActor
@Suite struct CommandOutcomeUITests {
    final class Contributed {
        var commands: [any Command] = []
    }

    let directory: URL
    let service: ActionsService
    let actions: ServiceActions
    let palette = FakePaletteHost()
    let pasting = RecordingPasteService()
    let notifier = RecordingNotifier()
    let ticks = Ticks()
    let contributed = Contributed()
    let scope: CommandsScope
    final class Opened {
        var urls: [URL] = []
    }
    let opened = Opened()

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "CortexTests-outcomes-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "name = 'GitHub Repository'\ntrigger = 'gh'\nurl = 'https://github.com/{argument}'\nexample = 'owner/repo'"
            .write(to: directory.appending(path: "gh.toml"), atomically: true, encoding: .utf8)
        try "name = 'Nap'\ntrigger = 'nap'\ncommand = 'sleep 0.1'\nargument = 'optional'"
            .write(to: directory.appending(path: "nap.toml"), atomically: true, encoding: .utf8)
        let (pasting, notifier, opened) = (pasting, notifier, opened)
        service = ActionsService(
            directory: directory, defaults: UserDefaults(suiteName: "CortexTests-\(UUID().uuidString)")!, pasting: pasting,
            notifier: notifier, openURL: { opened.urls.append($0) })
        service.reload()
        actions = ServiceActions(service: service)
        let (actions, palette, contributed, ticks) = (actions, palette, contributed, ticks)
        contributed.commands = [
            OpeningCommand(), EditorCommand(), ActingCommand(), PickingCommand(), NothingToDoCommand(), BrokenCommand(), TickingCommand(ticks: ticks),
        ]
        scope = CommandsScope(
            commands: { CommandCatalog.builtIns + contributed.commands + actions.userCommands },
            actions: { actions },
            palette: { palette },
            hosts: { ["raspberrypi", "linode"] })
        scope.previewDelay = .zero
        scope.refresh.interval = .milliseconds(5)
        actions.onUserFilesChanged { [scope] in scope.commandsDidChange() }
    }

    /// Types `text` and waits for the command to be resolved.
    private func search(_ text: String) async {
        scope.search(text)
        await scope.previewLoaded()
    }

    private func hints(_ text: String) async -> [PaletteHint] {
        await search(text)
        return scope.activationHints
    }

    private static let positions = PaletteHint.positions("Run")

    /// The text of the value `scope` has resolved.
    private func shown(_ resolution: CommandResolution?) -> String? {
        if case .success(.value(let value, _)) = resolution?.result { return value.text }
        return nil
    }

    /// Waits until `condition` holds (at most 3 seconds).
    private func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    // MARK: - The hints

    @Test func aValueIsPastedOrCopied() async {
        #expect(await hints("uuid") == [PaletteHint(.primary, "Paste"), PaletteHint(.option, "Copy"), Self.positions])
        #expect(await hints("token 16") == [PaletteHint(.primary, "Paste"), PaletteHint(.option, "Copy"), Self.positions])
        #expect(await hints("tick") == [PaletteHint(.primary, "Paste"), PaletteHint(.option, "Copy"), Self.positions], "a refreshed one too")
    }

    @Test func anOpenOutcomeSaysWhatOpensAndCopiesTheLinkOrPath() async {
        #expect(await hints("gh apple/swift") == [PaletteHint(.primary, "Open"), PaletteHint(.option, "Copy link"), Self.positions], "a user's link")
        #expect(await hints("opening link") == [PaletteHint(.primary, "Open"), PaletteHint(.option, "Copy link"), Self.positions])
        #expect(await hints("opening folder") == [PaletteHint(.primary, "Show in Finder"), PaletteHint(.option, "Copy path"), Self.positions])
        #expect(await hints("opening terminal") == [PaletteHint(.primary, "Open in Ghostty"), PaletteHint(.option, "Copy path"), Self.positions])
        #expect(await hints("opening sound") == [PaletteHint(.primary, "Play"), PaletteHint(.option, "Copy path"), Self.positions])
        #expect(await hints("editor") == [PaletteHint(.primary, "Open in Zed"), PaletteHint(.option, "Copy link"), Self.positions], "the command's own words")
    }

    @Test func anActAsksFirstAndHasNoOptionReturn() async {
        #expect(await hints("acting x") == [PaletteHint(.primary, "Kill 2 Processes…"), Self.positions])
    }

    @Test func aJobStartsAndMayCopyItsResult() async {
        #expect(await hints("nap") == [PaletteHint(.primary, "Start"), PaletteHint(.option, "Start and copy"), Self.positions])
    }

    @Test func aHandoffUsesTheCommandsVerb() async {
        #expect(await hints("picking") == [PaletteHint(.primary, "Pick Colour"), Self.positions])
    }

    @Test func untilItIsResolvedOrWhenItFailedTheHintsAreGeneric() async {
        let generic = [PaletteHint(.primary, "Run and paste"), PaletteHint(.option, "Run and copy"), Self.positions]
        scope.previewDelay = .seconds(30)
        scope.search("opening link")
        #expect(scope.resolution == nil)
        #expect(scope.activationHints == generic, "still waiting for the pause")
        scope.clear()
        scope.previewDelay = .zero
        #expect(await hints("nothing") == generic, "a notice")
        #expect(await hints("broken") == generic, "an error")
        #expect(await hints("gh") == generic, "it still needs its form")
        #expect(await hints("port abc") == generic)
        scope.search("zzz")
        #expect(scope.activationHints == generic, "nothing selected")
    }

    @Test func theHintsFollowWhatIsTyped() async {
        scope.search("opening link")
        await scope.previewLoaded()
        #expect(scope.activationHints.first == PaletteHint(.primary, "Open"))
        scope.search("opening folder")
        #expect(scope.activationHints.first == PaletteHint(.primary, "Run and paste"), "not resolved on this input yet")
        await scope.previewLoaded()
        #expect(scope.activationHints.first == PaletteHint(.primary, "Show in Finder"))
    }

    @Test func theFormsHintsFollowTheFieldsToo() async throws {
        let generic = [PaletteHint(.primary, "Run"), PaletteHint(.option, "Run and copy")]
        scope.search("opening")
        #expect(scope.activate(.primary, target: .selected), "its argument is required: the form opens")
        let form = try #require(scope.forms["test.opening"])
        await form.loaded()
        let overlay = try #require(palette.overlays.last)
        #expect(overlay.currentHints?() == generic, "nothing to resolve yet")
        form.text = "link"
        await form.previewLoaded()
        #expect(overlay.currentHints?() == [PaletteHint(.primary, "Open"), PaletteHint(.option, "Copy link")])
        form.text = "folder"
        #expect(overlay.currentHints?() == generic, "not resolved on the new text yet")
        await form.previewLoaded()
        #expect(overlay.currentHints?() == [PaletteHint(.primary, "Show in Finder"), PaletteHint(.option, "Copy path")])
        form.text = "nothing"
        await form.previewLoaded()
        #expect(form.hints == generic)

        scope.search("acting")
        #expect(scope.activate(.primary, target: .selected))
        let acting = try #require(scope.forms["test.acting"])
        await acting.loaded()
        acting.text = "x"
        await acting.previewLoaded()
        #expect(acting.hints == [PaletteHint(.primary, "Kill 2 Processes…")])

        scope.search("picking")
        #expect(scope.keys.isEmpty, "a handoff takes nothing: ⏎ hands over")
    }

    // MARK: - ⌥⏎

    @Test func optionReturnCopiesTheLinkInsteadOfOpeningIt() async throws {
        await search("opening link")
        #expect(scope.activate(.option, target: .selected))
        #expect(palette.deliveries.map(\.action) == [.copyOnly])
        await palette.delivered()
        #expect(pasting.writes == [.init(text: "https://example.com/a?b=1", recording: .record(sensitive: false), pasted: false)], "a normal clip")
        #expect(opened.urls.isEmpty, "not opened")
        #expect(service.usage["test.opening"]?.count == 1)
    }

    @Test func optionReturnCopiesThePathOfAFolderASoundOrATerminal() async throws {
        for (typed, path) in [("folder", "/Users/me/My Files/a.txt"), ("terminal", "/Users/me/Developer"), ("sound", "/Sounds/air horn.mp4")] {
            await search("opening " + typed)
            #expect(scope.activate(.option, target: .selected))
            await palette.delivered()
            #expect(pasting.writes.last == .init(text: path, recording: .record(sensitive: false), pasted: false), "\(typed): the path, not a file: link")
        }
        #expect(opened.urls.isEmpty)
    }

    @Test func returnStillOpensTheLink() async throws {
        await search("opening link")
        #expect(scope.activate(.primary, target: .selected))
        await palette.delivered()
        #expect(opened.urls == [URL(string: "https://example.com/a?b=1")!])
        #expect(pasting.writes.isEmpty)
    }

    @Test func optionReturnBeepsWhereTheHintsShowNone() async throws {
        for text in ["acting x", "picking"] {
            await search(text)
            #expect(scope.activate(.option, target: .selected), "the key is taken: it beeps")
            #expect(palette.deliveries.isEmpty, "\(text) does nothing")
        }
        // ⏎ on the act still goes ahead (asks first).
        await search("acting x")
        #expect(scope.activate(.primary, target: .selected))
        #expect(palette.deliveries.count == 1)
    }

    @Test func optionReturnOnAJobStartsAndCopiesItsResult() async throws {
        await search("nap")
        #expect(scope.activate(.option, target: .selected))
        #expect(palette.deliveries.map(\.action) == [.copyOnly])
    }

    @Test func theFormsOptionReturnBeepsOrCopiesToo() async throws {
        scope.search("opening")
        #expect(scope.activate(.primary, target: .selected))
        let form = try #require(scope.forms["test.opening"])
        await form.loaded()
        let overlay = try #require(palette.overlays.last)
        form.text = "link"
        await form.previewLoaded()
        overlay.activate(.option)
        #expect(palette.deliveries.map(\.action) == [.copyOnly])
        await palette.delivered()
        #expect(pasting.writes.map(\.text) == ["https://example.com/a?b=1"])
        #expect(opened.urls.isEmpty)

        scope.search("acting")
        #expect(scope.activate(.primary, target: .selected))
        let acting = try #require(scope.forms["test.acting"])
        await acting.loaded()
        acting.text = "x"
        await acting.previewLoaded()
        let actingOverlay = try #require(palette.overlays.last)
        actingOverlay.activate(.option)
        #expect(palette.deliveries.count == 1, "no second delivery: beeped")
        actingOverlay.activate(.primary)
        #expect(palette.deliveries.count == 2)
    }

    // MARK: - The form's host

    @Test func aFormKeptFromBeforeFollowsTheQueryForItsHost() async throws {
        scope.search("tick x @raspberrypi")
        let key = try #require(scope.keys.first { $0.combo == .tab })
        #expect(key.perform?() == true)
        let form = try #require(scope.forms["test.tick"])
        await form.loaded()
        #expect(form.machine == .ssh("raspberrypi") && form.text == "x")
        form.text = "edited"
        try #require(palette.overlays.last).dismissed?()

        // Typed again without a host: not pi.
        scope.search("tick")
        #expect(try #require(scope.keys.first { $0.combo == .tab }).perform?() == true)
        #expect(scope.forms["test.tick"] === form, "the same form")
        #expect(form.machine == .local)
        #expect(form.text == "edited", "its other values stay as left")

        // With a host, and from a search that does not name the command.
        scope.search("tick @linode")
        #expect(try #require(scope.keys.first { $0.combo == .tab }).perform?() == true)
        #expect(form.machine == .ssh("linode"))
        scope.search("tic")
        #expect(try #require(scope.keys.first { $0.combo == .tab }).perform?() == true)
        #expect(form.machine == .local)

        // A host that is not valid is This Mac too.
        scope.search("tick @nas")
        #expect(try #require(scope.keys.first { $0.combo == .tab }).perform?() == true)
        #expect(form.machine == .local)
        scope.clear()
    }

    // MARK: - ⌥⏎ before the pane has resolved

    @Test func optionReturnBeforeTheOutcomeIsThereBeepsForAnActAndAHandoff() async throws {
        for text in ["acting x", "picking"] {
            scope.search(text)
            #expect(scope.resolution == nil, "not resolved yet")
            #expect(scope.activate(.option, target: .selected))
            await scope.runLoaded()
            #expect(palette.deliveries.isEmpty && palette.closes == 0, "\(text): beeped, nothing was carried out")
            #expect(scope.resolution != nil, "the pane carries on")
        }
        await palette.delivered()
        #expect(service.usage["test.acting"] == nil && service.usage["test.picking"] == nil, "never run")
    }

    @Test func optionReturnBeforeTheOutcomeIsThereCopiesAValueWithoutResolvingAgain() async throws {
        scope.search("tick once")
        #expect(scope.activate(.option, target: .selected))
        #expect(palette.deliveries.isEmpty, "waits for the value")
        await scope.runLoaded()
        #expect(palette.deliveries.map(\.action) == [.copyOnly])
        await palette.delivered()
        #expect(pasting.writes.map(\.text) == ["once"])
        #expect(actions.resolutions == 1, "the value that was shown")
    }

    @Test func typingWhileOptionReturnWaitsDropsIt() async throws {
        scope.previewDelay = .milliseconds(20)
        scope.search("tick once")
        #expect(scope.activate(.option, target: .selected))
        scope.search("tick twice")
        await scope.runLoaded()
        await scope.previewLoaded()
        #expect(palette.deliveries.isEmpty, "the key was for what was typed before")
    }

    @Test func theFormsOptionReturnBeforeTheOutcomeIsThereBeepsForAnAct() async throws {
        scope.search("acting")
        #expect(scope.activate(.primary, target: .selected))
        let form = try #require(scope.forms["test.acting"])
        await form.loaded()
        await form.previewLoaded()
        let overlay = try #require(palette.overlays.last)
        form.text = "x"
        #expect(form.isLoadingPreview && form.currentResolution == nil)
        overlay.activate(.option)
        await scope.runLoaded()
        #expect(palette.deliveries.isEmpty, "beeped; the kill alert was not asked for")
        #expect(form.currentResolution != nil)

        // The same for a value: copied, with the resolution that arrived.
        scope.search("tick")
        #expect(try #require(scope.keys.first { $0.combo == .tab }).perform?() == true)
        let tick = try #require(scope.forms["test.tick"])
        await tick.loaded()
        await tick.previewLoaded()
        let tickOverlay = try #require(palette.overlays.last)
        tick.text = "once"
        tickOverlay.activate(.option)
        await scope.runLoaded()
        #expect(palette.deliveries.map(\.action) == [.copyOnly])
    }

    // MARK: - A result of earlier input

    @Test func theResultOfEarlierInputStaysMarkedUntilTheNewOneIsThere() async throws {
        await search("tick a")
        let tick = try #require(scope.list.selected)
        #expect(scope.loading(for: tick) == nil, "what is shown is for what was typed")

        scope.previewDelay = .seconds(30)
        scope.search("tick b")
        #expect(scope.resolution?.input == .text("a"), "stays")
        #expect(scope.loading(for: tick) == "Tick", "but is marked as pending")
        scope.search("tick a")
        #expect(scope.loading(for: tick) == nil, "typed back to what is shown")
        scope.search("tick b")
        scope.previewDelay = .zero
        scope.search("tick c")
        await scope.previewLoaded()
        #expect(scope.resolution?.input == .text("c"))
        #expect(scope.loading(for: tick) == nil)
        scope.clear()
    }

    @Test func theFormMarksTheResultOfEarlierInputToo() async throws {
        scope.search("tick")
        #expect(try #require(scope.keys.first { $0.combo == .tab }).perform?() == true)
        let form = try #require(scope.forms["test.tick"])
        await form.loaded()
        form.text = "a"
        await form.previewLoaded()
        #expect(form.currentResolution != nil)
        form.previewDelay = .seconds(30)
        form.text = "b"
        #expect(form.resolution?.input == .text("a") && form.currentResolution == nil && form.isLoadingPreview)
        form.cancel()
    }

    // MARK: - Refresh

    @Test func aRefreshingValueIsResolvedAgainAndReplacedWithoutALoadingState() async throws {
        await search("tick")
        #expect(shown(scope.resolution) == "tick 1")
        var sawLoading = false
        let replaced = await eventually {
            sawLoading = sawLoading || scope.isLoadingPreview
            return ticks.count >= 4
        }
        #expect(replaced)
        #expect(shown(scope.resolution) != "tick 1")
        #expect(!sawLoading, "swapped in, not reloaded")
        #expect(scope.refresh.problem == nil)
        #expect(scope.activationHints.first == PaletteHint(.primary, "Paste"))
    }

    @Test func aValueWithoutARefreshIsResolvedOnce() async throws {
        await search("uuid")
        let value = shown(scope.resolution)
        try await Task.sleep(for: .milliseconds(60))
        #expect(shown(scope.resolution) == value)
        #expect(!scope.refresh.isRunning)
        await search("tick once")
        #expect(shown(scope.resolution) == "once")
        let count = ticks.count
        try await Task.sleep(for: .milliseconds(60))
        #expect(ticks.count == count, "this one does not ask for it")
    }

    @Test func theNextLookupWaitsForThePreviousToFinish() async throws {
        ticks.latency = .milliseconds(20)
        await search("tick")
        #expect(await eventually { ticks.count >= 4 })
        scope.didLeave()
        #expect(ticks.mostAtOnce == 1)
    }

    @Test func leavingStopsTheRefresh() async throws {
        await search("tick")
        #expect(await eventually { ticks.count >= 3 })
        scope.didLeave()
        try await expectNoMoreLookups()
        #expect(!scope.refresh.isRunning)
    }

    @Test func clearingStopsTheRefresh() async throws {
        await search("tick")
        #expect(await eventually { ticks.count >= 3 })
        scope.clear()
        try await expectNoMoreLookups()
        #expect(scope.resolution == nil)
    }

    @Test func anotherSelectionStopsTheRefresh() async throws {
        await search("tick")
        #expect(await eventually { ticks.count >= 3 })
        scope.search("uuid")
        try await expectNoMoreLookups()
        await scope.previewLoaded()
        #expect(scope.resolution?.commandID == "command.uuid")
        #expect(!scope.refresh.isRunning)
    }

    @Test func otherTextStopsTheRefresh() async throws {
        await search("tick")
        #expect(await eventually { ticks.count >= 3 })
        await search("tick once")
        try await expectNoMoreLookups()
        #expect(shown(scope.resolution) == "once", "the old value did not come back")
    }

    @Test func aHostStopsTheRefresh() async throws {
        await search("tick")
        #expect(await eventually { ticks.count >= 3 })
        scope.search("tick @nope")
        try await expectNoMoreLookups()
        guard case .failure(let error) = scope.resolution?.result else { throw QuickActionError("no host problem") }
        #expect(error.message.hasPrefix("“@nope” is not a host"))
    }

    /// Nothing is looked up for a while, once a lookup that was already under
    /// way has finished.
    private func expectNoMoreLookups() async throws {
        try await Task.sleep(for: .milliseconds(40))
        let count = ticks.count
        try await Task.sleep(for: .milliseconds(100))
        #expect(ticks.count == count)
    }

    @Test func aFailedRefreshKeepsTheLastValueAndSaysSo() async throws {
        ticks.failFrom = 4
        await search("tick")
        #expect(await eventually { scope.refresh.problem != nil })
        #expect(scope.refresh.problem == "host unreachable")
        #expect(shown(scope.resolution) == "tick 3", "the last good one, not an error")
        #expect(scope.resolution?.outcome != nil)
        let failed = ticks.count
        #expect(await eventually { ticks.count > failed + 1 }, "it keeps trying")
        #expect(shown(scope.resolution) == "tick 3")
        #expect(scope.activationHints.first == PaletteHint(.primary, "Paste"))

        ticks.failFrom = 0
        #expect(await eventually { scope.refresh.problem == nil })
        #expect(await eventually { shown(scope.resolution) != "tick 3" })
    }

    @Test func returnPastesExactlyTheValueShown() async throws {
        await search("tick")
        #expect(await eventually { ticks.count >= 3 })
        let value = try #require(shown(scope.resolution))
        #expect(scope.activate(.primary, target: .selected))
        // It carries on refreshing until the palette closes; the paste is the
        // value that was shown when ⏎ was pressed.
        let pressed = ticks.count
        #expect(await eventually { ticks.count > pressed + 1 })
        await palette.delivered()
        #expect(pasting.writes.map(\.text) == [value])
        #expect(pasting.writes.first?.pasted == true)
    }

    @Test func theFormRefreshesItsOwnValueAndTheListResumesWhenItIsLeft() async throws {
        await search("tick")
        let key = try #require(scope.keys.first { $0.combo == .tab })
        #expect(key.perform?() == true)
        let form = try #require(scope.forms["test.tick"])
        await form.loaded()
        await form.previewLoaded()
        #expect(!scope.refresh.isRunning, "the form resolves for itself")
        #expect(form.refresh.isRunning)
        let first = shown(form.resolution)
        #expect(await eventually { shown(form.resolution) != first })

        let overlay = try #require(palette.overlays.last)
        overlay.dismissed?()
        #expect(!form.refresh.isRunning)
        #expect(scope.refresh.isRunning, "back on the list")
        let before = shown(scope.resolution)
        #expect(await eventually { shown(scope.resolution) != before })

        // Showing the form again picks the refresh up again.
        #expect(key.perform?() == true)
        #expect(form.refresh.isRunning && !scope.refresh.isRunning)
        scope.clear()
        #expect(!form.refresh.isRunning)
    }

    @Test func aFailedRefreshOfTheFormKeepsItsValueToo() async throws {
        await search("tick")
        let key = try #require(scope.keys.first { $0.combo == .tab })
        #expect(key.perform?() == true)
        let form = try #require(scope.forms["test.tick"])
        await form.loaded()
        await form.previewLoaded()
        ticks.failFrom = ticks.count + 2
        #expect(await eventually { form.refresh.problem != nil })
        #expect(shown(form.resolution)?.hasPrefix("tick ") == true)
        #expect(form.currentResolution?.outcome != nil)
    }

    // MARK: - Nothing to do

    @Test func aNoticeIsNotAnErrorAndReturnBeeps() async throws {
        await search("nothing")
        guard case .failure(let error) = scope.resolution?.result else { throw QuickActionError("no notice") }
        #expect(error.isNotice && error.message == "Nothing is listening on port 3000")
        #expect(scope.activate(.primary, target: .selected), "the key is taken: it beeps")
        #expect(palette.deliveries.isEmpty)
        #expect(notifier.posts.isEmpty)
        await search("broken")
        guard case .failure(let broken) = scope.resolution?.result else { throw QuickActionError("no error") }
        #expect(!broken.isNotice)
    }

    @Test func portAndKillAnswerNothingToDoWithNotices() async throws {
        let port = try unusedPort()
        await search("port \(port)")
        guard case .failure(let error) = scope.resolution?.result else { throw QuickActionError("no notice") }
        #expect(error == .notice("Nothing is listening on port \(port) (only your own processes are checked)"))
        await search("kill no-such-process-\(UUID().uuidString)")
        guard case .failure(let none) = scope.resolution?.result else { throw QuickActionError("no notice") }
        #expect(none.isNotice)
        await search("port abc")
        guard case .failure(let wrong) = scope.resolution?.result else { throw QuickActionError("no error") }
        #expect(!wrong.isNotice, "a typo is an error")
    }

    @Test func actionsPostsANoticeAsAnOrdinaryNotification() async throws {
        let command = NothingToDoCommand()
        await service.run(CommandAction(command), input: .none, delivery: .copy)
        #expect(notifier.posts == [.init(title: "Nothing", body: "Nothing is listening on port 3000")], "the sentence, not “failed”")
        await service.run(CommandAction(BrokenCommand()), input: .none, delivery: .copy)
        #expect(notifier.posts.last == .init(title: "Broken failed", body: "It broke"))
        // Run from `$` before the resolution was there.
        await service.run(command, input: .none, delivery: .copy)
        #expect(notifier.posts.last == .init(title: "Nothing", body: "Nothing is listening on port 3000"))
        #expect(notifier.posts.count == 3)
        await service.run(BrokenCommand(), input: .none, delivery: .copy)
        #expect(notifier.posts.last == .init(title: "Broken failed", body: "It broke"))
    }

    // MARK: - The pane

    @Test func theHeaderIsTheCommandAsTyped() async {
        scope.search("port 3000 @pi")
        let port = scope.list.selected!
        #expect(scope.typed(port) == "$port 3000 @pi")
        scope.search("mem @raspberrypi")
        #expect(scope.typed(scope.list.selected!) == "$mem @raspberrypi")
        scope.search("uuid")
        #expect(scope.typed(scope.list.selected!) == "$uuid")
        scope.search("code")
        #expect(scope.typed(scope.list.selected!) == "$code", "the dimmed example is not in the header")
        scope.search("code mathical")
        #expect(scope.typed(scope.list.selected!) == "$code mathical")
    }

    @Test func everyKindOfOutcomeRendersInThePane() async throws {
        func render(_ view: CommandOutcomeView) {
            let host = NSHostingView(rootView: view.frame(width: 400, height: 300))
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.width > 0)
        }
        for text in ["uuid", "opening link", "acting x", "nap", "picking", "nothing", "broken", "tick"] {
            await search(text)
            let command = try #require(scope.list.selected)
            render(CommandOutcomeView(
                command: command, typed: scope.typed(command), resolution: scope.resolution,
                refreshProblem: text == "tick" ? "host unreachable" : nil))
        }
        let command = try #require(scope.list.selected)
        render(CommandOutcomeView(command: command, typed: "$tick @pi", resolution: nil, loading: "Tick on pi"))
        scope.clear()
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

// MARK: - Commands for the tests

/// Counts the lookups of `TickingCommand`, and can make them fail or last.
final class Ticks: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var running = 0
    private var most = 0
    private var failing = 0
    private var wait = Duration.zero

    /// How many lookups were started.
    var count: Int { lock.withLock { calls } }
    /// The most lookups that ran at the same time.
    var mostAtOnce: Int { lock.withLock { most } }
    /// Lookups from this number on fail (0: none do).
    var failFrom: Int {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }
    /// How long a lookup takes.
    var latency: Duration {
        get { lock.withLock { wait } }
        set { lock.withLock { wait = newValue } }
    }

    func begin() -> (number: Int, fails: Bool, wait: Duration) {
        lock.withLock {
            calls += 1
            running += 1
            most = max(most, running)
            return (calls, failing > 0 && calls >= failing, wait)
        }
    }

    func end() {
        lock.withLock { running -= 1 }
    }
}

/// A value that asks to be refreshed every 2 seconds, like `$mem`; `tick
/// once` is one that does not. Runs on hosts, so it has a form with a Host
/// field.
private struct TickingCommand: Command {
    let ticks: Ticks
    let id = "test.tick"
    let name = "tick"
    let title = "Tick"
    let symbol = "clock"
    let argument: CommandArgument? = CommandArgument(title: "Text", placeholder: "x", isRequired: false)
    var runsOnHosts: Bool { true }

    func resolve(_ invocation: CommandInvocation) async throws -> CommandOutcome {
        let lookup = ticks.begin()
        defer { ticks.end() }
        if lookup.wait > .zero { try await Task.sleep(for: lookup.wait) }
        if lookup.fails { throw QuickActionError("host unreachable") }
        if invocation.input == .text("once") { return .value(.text("once")) }
        return .value(.text("tick \(lookup.number)"), refresh: .seconds(2))
    }
}

/// Opens what is typed: `link`, `folder`, `terminal`, `sound` or `editor`.
private struct OpeningCommand: Command {
    let id = "test.opening"
    let name = "opening"
    let title = "Opening"
    let symbol = "arrow.up.forward.square"
    let argument: CommandArgument? = CommandArgument(title: "What", placeholder: "link")

    func resolve(_ invocation: CommandInvocation) async throws -> CommandOutcome {
        switch invocation.input.text {
        case "link": .open(.url(URL(string: "https://example.com/a?b=1")!))
        case "folder": .open(.reveal(URL(filePath: "/Users/me/My Files/a.txt")))
        case "terminal": .open(.openWith(URL(filePath: "/Users/me/Developer"), app: URL(filePath: "/Applications/Ghostty.app")))
        case "sound": .open(.play(URL(filePath: "/Sounds/air horn.mp4")))
        default: throw QuickActionError("Nothing called that")
        }
    }
}

/// Opens a link in an editor that it names.
private struct EditorCommand: Command {
    let id = "test.editor"
    let name = "editor"
    let title = "Editor"
    let symbol = "pencil"
    var verb: String? { "Open in Zed" }

    func resolve(_ invocation: CommandInvocation) async throws -> CommandOutcome {
        .open(.url(URL(string: "zed://file/Users/me/a.txt")!))
    }
}

/// Asks before ending two processes.
private struct ActingCommand: Command {
    let id = "test.acting"
    let name = "acting"
    let title = "Acting"
    let symbol = "xmark.circle"
    let argument: CommandArgument? = CommandArgument(title: "What", placeholder: "x")

    func resolve(_ invocation: CommandInvocation) async throws -> CommandOutcome {
        .act(ActionConfirmation(title: "Kill 2 processes?", message: "node, node", confirmTitle: "Kill 2 Processes") { .done("Ended 2") })
    }
}

/// Hands over, and names it.
private struct PickingCommand: Command {
    let id = "test.picking"
    let name = "picking"
    let title = "Picking"
    let symbol = "eyedropper"
    var verb: String? { "Pick Colour" }

    func resolve(_ invocation: CommandInvocation) async throws -> CommandOutcome {
        .handoff(description: "Shows the eyedropper") {}
    }
}

/// Has nothing to do.
private struct NothingToDoCommand: Command {
    let id = "test.nothing"
    let name = "nothing"
    let title = "Nothing"
    let symbol = "circle"

    func resolve(_ invocation: CommandInvocation) async throws -> CommandOutcome {
        throw QuickActionError.notice("Nothing is listening on port 3000")
    }
}

/// Fails.
private struct BrokenCommand: Command {
    let id = "test.broken"
    let name = "broken"
    let title = "Broken"
    let symbol = "exclamationmark.triangle"

    func resolve(_ invocation: CommandInvocation) async throws -> CommandOutcome {
        throw QuickActionError("It broke")
    }
}
