import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Cortex
import CortexCore

/// The palette without a trigger: the clipboard history.
@MainActor
@Suite struct ClipboardScopeTests {
    final class Recorder: SnippetsAPI, ActionsAPI {
        var edits: [SnippetEditRequest] = []
        var shown: [ResolvedActionInput?] = []
        func editSnippet(_ request: SnippetEditRequest) { edits.append(request) }
        func showActions(on input: ResolvedActionInput?) { shown.append(input) }
        // The runner `$` uses; not needed here.
        func resolve(_ command: any Command, input: ActionInput, options: ActionOptionValues?, machine: Machine) async -> CommandResolution? { nil }
        func run(_ command: any Command, input: ActionInput, machine: Machine, resolution: CommandResolution?, delivery: ActionDelivery, summary: String?) async -> Bool { true }
        func options(for command: any Command) -> ActionOptionValues { ActionOptionValues() }
        func setOptions(_ values: ActionOptionValues, for command: any Command) {}
        var usage: [String: ActionUsage] { [:] }
        var userCommands: [UserCommand] { [] }
        func onUserFilesChanged(_ handler: @escaping @MainActor () -> Void) {}
        func commandPane(for command: any Command, typed: String?, resolution: CommandResolution?, loading: String?, refreshProblem: String?) -> AnyView { AnyView(EmptyView()) }
    }

    let service: ClipboardService
    let settings: ClipboardSettings
    let palette = FakePaletteHost()
    let recorder = Recorder()
    let scope: ClipboardScope
    var store: ClipStore { service.store }

    init() throws {
        settings = ClipboardSettings(defaults: UserDefaults(suiteName: "CortexTests-\(UUID().uuidString)")!)
        service = ClipboardService(database: try makeTestDatabase(), settings: settings)
        let now = Date.now
        for (offset, text) in ["alpha", "beta", "gamma", "delta"].enumerated() {
            try service.store.record(Self.snapshot(text, copiedAt: now.addingTimeInterval(-Double(offset))), indexSensitive: true)
        }
        let (palette, recorder) = (palette, recorder)
        scope = ClipboardScope(service: service, snippets: { recorder }, actions: { recorder }, palette: { palette })
    }

    static func snapshot(_ text: String, copiedAt: Date = .now, sensitive: Bool = false) -> ClipSnapshot {
        ClipSnapshot(
            representations: [LoadedRepresentation(type: ClipType.plainText, data: Data(text.utf8))],
            plainText: text, isSensitive: sensitive, copiedAt: copiedAt)
    }

    func load(_ query: String = "") async {
        scope.search(query)
        await scope.loaded()
    }

    @Test func showsNewestFirstAndSelectsTop() async {
        await load()
        #expect(scope.list.items.map(\.preview) == ["alpha", "beta", "gamma", "delta"])
        #expect(scope.list.selected?.preview == "alpha")
    }

    @Test func movingSelectionStopsAtTheEnds() async {
        await load()
        scope.move(.vertical(1))
        #expect(scope.list.selected?.preview == "beta")
        scope.move(.vertical(10))
        #expect(scope.list.selected?.preview == "delta")
        scope.move(.vertical(-10))
        #expect(scope.list.selected?.preview == "alpha")
    }

    @Test func typingFiltersAndSelectsFirstMatch() async {
        await load()
        scope.move(.vertical(2))
        await load("del")
        #expect(scope.list.items.map(\.preview) == ["delta"])
        #expect(scope.list.selected?.preview == "delta")
    }

    @Test func anEscapedTriggerSearchesTheHistory() async throws {
        try store.record(Self.snapshot(";sig"), indexSensitive: true)
        let model = PaletteModel(routes: [
            PaletteRoute(id: "clipboard", trigger: .default, placeholder: "clipboard", scope: scope),
            PaletteRoute(id: "snippets", trigger: .prefix(";"), placeholder: "snippets", scope: FakeScope()),
        ])
        model.query = "\\;sig"
        await scope.loaded()
        #expect(model.activeModule == "clipboard")
        #expect(scope.list.items.map(\.preview) == [";sig"])
    }

    @Test func aChangedHistoryKeepsTheSelectionOrMovesToTheNeighbour() async throws {
        await load()
        scope.move(.vertical(1))
        let beta = try #require(scope.list.selectedID)

        try store.delete(ids: [beta])
        scope.historyDidChange()
        await scope.loaded()
        #expect(scope.list.items.map(\.preview) == ["alpha", "gamma", "delta"])
        #expect(scope.list.selected?.preview == "gamma")

        try store.record(Self.snapshot("new"), indexSensitive: true)
        scope.historyDidChange()
        await scope.loaded()
        #expect(scope.list.items.first?.preview == "new")
        #expect(scope.list.selected?.preview == "gamma")
    }

    @Test func deletingTheLastItemSelectsTheNewLast() async throws {
        await load()
        scope.move(.vertical(3))
        try store.delete(ids: [try #require(scope.list.selectedID)])
        scope.historyDidChange()
        await scope.loaded()
        #expect(scope.list.selected?.preview == "gamma")
    }

    @Test func selectionLoadsTheDetail() async {
        await load()
        await scope.detailLoaded()
        #expect(scope.detail?.item.plainText == "alpha")
        scope.move(.vertical(1))
        await scope.detailLoaded()
        #expect(scope.detail?.item.plainText == "beta")
    }

    @Test func clearingDropsEverything() async {
        await load()
        await scope.detailLoaded()
        scope.modifiersChanged(.option)
        #expect(scope.isRevealing)
        scope.clear()
        #expect(scope.list.items.isEmpty)
        #expect(scope.detail == nil)
        #expect(scope.list.selectedID == nil)
        #expect(!scope.isRevealing)

        scope.historyDidChange()
        await scope.loaded()
        #expect(scope.list.items.isEmpty, "nothing is loaded while the palette is hidden")
    }

    @Test func showingStartsWithAnEmptyQuery() async {
        let model = PaletteModel(routes: [PaletteRoute(id: "clipboard", trigger: .default, placeholder: "clipboard", scope: scope)])
        model.query = "beta"
        await scope.loaded()
        model.prepareForShow()
        await scope.loaded()
        #expect(model.query.isEmpty)
        #expect(scope.list.items.count == 4)
    }

    @Test func optionReveals() {
        scope.modifiersChanged([.option, .shift])
        #expect(scope.isRevealing)
        scope.modifiersChanged(.command)
        #expect(!scope.isRevealing)
    }

    // MARK: - Pasting

    @Test func returnPastesRichAndShiftAsPlainText() {
        #expect(scope.pasteAction(.primary) == .paste(.rich))
        #expect(scope.pasteAction(.shift) == .paste(.plainText))
        #expect(scope.pasteAction(.option) == .copyOnly)
        #expect(scope.pasteAction(.optionShift) == .copyOnly)
        #expect(scope.activationHints.map(\.label) == ["Paste", "Paste as text", "Copy"])
    }

    @Test func plainTextByDefaultSwapsThem() {
        settings.pastePlainByDefault = true
        #expect(scope.pasteAction(.primary) == .paste(.plainText))
        #expect(scope.pasteAction(.shift) == .paste(.rich))
        #expect(scope.activationHints.map(\.label) == ["Paste as text", "Paste", "Copy"])
    }

    @Test func returnAndCommandDigitsPasteTheClip() async {
        await load()
        #expect(scope.activate(.primary, target: .position(2)))
        #expect(palette.deliveries.map(\.action) == [.paste(.rich)])
        #expect(palette.closes == 1)
    }

    // MARK: - Keys

    func key(_ combo: KeyCombo) -> PaletteKey? {
        scope.keys.first { $0.combo == combo }
    }

    @Test func hintsInOrder() {
        #expect(scope.keys.compactMap(\.hint) == ["Pin", "Delete", "Save as snippet", "Actions", "Reveal"])
    }

    /// An image clip at the top, its text read if `text` is given.
    @discardableResult
    func recordImage(text: String?) async throws -> Int64 {
        let snapshot = ClipSnapshot(
            representations: [LoadedRepresentation(type: ClipType.png, data: imageData(.png))],
            plainText: nil, isSensitive: false, copiedAt: .now.addingTimeInterval(1))
        guard case .inserted(let id) = try store.record(snapshot, indexSensitive: true) else {
            Issue.record("expected insert")
            throw CancellationError()
        }
        if let text { try store.setRecognizedText(text, id: id, indexSensitive: true) }
        return id
    }

    @Test func imageWithTextOffersToPasteTheText() async throws {
        try await recordImage(text: "Gate B12")
        await load()
        await scope.detailLoaded()
        #expect(scope.activationHints.map(\.label) == ["Paste", "Paste text", "Copy"])
        settings.pastePlainByDefault = true
        #expect(scope.activationHints.map(\.label) == ["Paste text", "Paste", "Copy"])

        #expect(key(.command("e"))?.perform?() == true)
        #expect(recorder.edits == [.new(body: "Gate B12")])
    }

    @Test func imageWithoutTextKeepsTheUsualHints() async throws {
        try await recordImage(text: nil)
        await load()
        await scope.detailLoaded()
        #expect(scope.activationHints.map(\.label) == ["Paste", "Paste as text", "Copy"])
    }

    @Test func textReadLaterReachesTheShownDetail() async throws {
        let id = try await recordImage(text: nil)
        await load()
        await scope.detailLoaded()
        #expect(scope.detail?.item.imageText == nil)

        try store.setRecognizedText("Gate B12", id: id, indexSensitive: true)
        scope.historyDidChange()
        await scope.loaded()
        await scope.detailLoaded()
        #expect(scope.detail?.item.imageText == "Gate B12")
    }

    @Test func pinAndDelete() async throws {
        await load()
        #expect(key(.command("p"))?.perform?() == true)
        for _ in 0..<50 where try await store.summaries(matching: "").first?.isPinned != true {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try await store.summaries(matching: "").first { $0.preview == "alpha" }?.isPinned == true)

        #expect(key(.command(.delete))?.perform?() == true)
        for _ in 0..<50 where try await store.summaries(matching: "").count == 4 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try await store.summaries(matching: "").map(\.preview) == ["beta", "gamma", "delta"])
    }

    @Test func commandESavesTheClipAsASnippetAndCommandNStartsOne() async {
        await load()
        await scope.detailLoaded()
        #expect(key(.command("e"))?.perform?() == true)
        #expect(key(.command("n"))?.perform?() == true)
        #expect(recorder.edits == [.new(body: "alpha"), .new(body: nil)])
        #expect(palette.closes == 2)
    }

    @Test func commandKOpensTheActionsOnTheClip() async {
        await load()
        await scope.detailLoaded()
        #expect(key(.command("k"))?.perform?() == true)
        #expect(recorder.shown.first??.source == .clip)
        #expect(recorder.shown.first??.input == .text("alpha"))
    }

    @Test func withoutSnippetsAndActionsTheirKeysDoNothing() async {
        let scope = ClipboardScope(service: service) { palette }
        #expect(scope.keys.compactMap(\.hint) == ["Pin", "Delete", "Reveal"])
        scope.search("")
        await scope.loaded()
        await scope.detailLoaded()
        #expect(scope.keys.first { $0.combo == .command("e") }?.perform?() == true)
        #expect(palette.closes == 0)
    }
}
