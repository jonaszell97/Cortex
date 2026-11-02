import Foundation
import Testing
@testable import Cortex
import CortexCore

/// The `:` scope: the emoji grid, moving through it, picking one.
@MainActor
@Suite struct EmojiScopeTests {
    let scope: EmojiScope
    let settings: EmojiSettings
    let defaults: UserDefaults
    let palette = FakePaletteHost()

    init() {
        let suite = "EmojiScopeTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        settings = EmojiSettings(defaults: defaults)
        let palette = palette
        scope = EmojiScope(settings: settings) { palette }
    }

    func open(_ query: String) async {
        scope.search(query)
        await scope.loaded()
    }

    func moveSideways(by delta: Int) { scope.move(.sideways(delta)) }
    func moveVertically(by delta: Int) { scope.move(.vertical(delta)) }

    @Test func emptyQueryShowsEveryCategory() async {
        await open("")
        #expect(scope.grid.sections.map(\.title) == EmojiGroup.allCases.map(\.title))
        #expect(scope.grid.sections.allSatisfy { !$0.items.isEmpty })
        #expect(scope.grid.selection == GridPosition(section: 0, index: 0))
        #expect(scope.selected != nil)
    }

    @Test func frequentlyUsedComesFirst() async throws {
        let thumbs = try #require(EmojiCatalog.shared.search("thumbsup").first)
        settings.recordUse(of: thumbs)
        await open("")
        #expect(scope.grid.sections.first?.title == "Frequently used")
        #expect(scope.grid.sections.first?.items == [thumbs])
        #expect(scope.grid.sections.count == EmojiGroup.allCases.count + 1)
    }

    @Test func searchShowsOneSectionOfMatches() async {
        await open("thumbsup")
        #expect(scope.grid.sections.count == 1)
        #expect(scope.grid.sections.first?.title == nil)
        #expect(scope.selected?.shortcodes.contains("thumbsup") == true)

        await open("thumbsup:")
        #expect(scope.selected?.shortcodes.contains("thumbsup") == true, "a closing colon is ignored")
    }

    @Test func noMatchesLeavesNothingSelected() async {
        await open("zzzzzzzz")
        #expect(scope.grid.sections.isEmpty)
        #expect(scope.selected == nil)
        #expect(scope.hasLoaded)
        // Moving with nothing to move over does nothing.
        moveSideways(by: 1)
        moveVertically(by: 1)
        #expect(scope.selected == nil)
    }

    @Test func typingSelectsTheBestMatchAgain() async {
        await open("")
        moveSideways(by: 5)
        await open("fire")
        #expect(scope.grid.selection == GridPosition(section: 0, index: 0))
    }

    @Test func sidewaysMovementContinuesIntoTheNextSection() async {
        await open("")
        let first = scope.grid.sections[0]
        moveSideways(by: first.items.count - 1)
        #expect(scope.grid.selection == GridPosition(section: 0, index: first.items.count - 1))
        moveSideways(by: 1)
        #expect(scope.grid.selection == GridPosition(section: 1, index: 0))
        moveSideways(by: -1)
        #expect(scope.grid.selection == GridPosition(section: 0, index: first.items.count - 1))
        moveSideways(by: -10_000)
        #expect(scope.grid.selection == GridPosition(section: 0, index: 0))
        moveSideways(by: 100_000)
        let last = scope.grid.sections.count - 1
        #expect(scope.grid.selection == GridPosition(section: last, index: scope.grid.sections[last].items.count - 1))
    }

    @Test func verticalMovementKeepsTheColumn() async {
        await open("")
        let columns = EmojiScope.columns
        moveSideways(by: 3)
        moveVertically(by: 1)
        #expect(scope.grid.selection == GridPosition(section: 0, index: 3 + columns))
        moveVertically(by: -1)
        #expect(scope.grid.selection == GridPosition(section: 0, index: 3))
        moveVertically(by: -1)
        #expect(scope.grid.selection == GridPosition(section: 0, index: 3), "the top stops")
    }

    @Test func verticalMovementCrossesSectionsAndStopsAtTheEnds() async {
        await open("")
        let columns = EmojiScope.columns
        let first = scope.grid.sections[0]
        let lastRowStart = ((first.items.count - 1) / columns) * columns
        // First column of the first section's last row; down goes to row 0 of the next.
        moveSideways(by: lastRowStart)
        moveVertically(by: 1)
        #expect(scope.grid.selection == GridPosition(section: 1, index: 0))
        // And up again to the same cell.
        moveVertically(by: -1)
        #expect(scope.grid.selection == GridPosition(section: 0, index: lastRowStart))

        moveVertically(by: 10_000)
        let last = scope.grid.sections.count - 1
        #expect(scope.grid.selection?.section == last)
        let lastCount = scope.grid.sections[last].items.count
        #expect((scope.grid.selection?.index ?? 0) >= (lastCount - 1) / columns * columns)
        #expect(scope.selected != nil)
    }

    @Test func verticalMovementInAShortLastRowLandsOnTheLastEmoji() async {
        await open("")
        let columns = EmojiScope.columns
        let count = scope.grid.sections[0].items.count
        guard count % columns != 0, count > columns else { return }
        // Column further right than the short last row reaches.
        let column = columns - 1
        moveSideways(by: (count / columns - 1) * columns + column)
        moveVertically(by: 1)
        #expect(scope.grid.selection == GridPosition(section: 0, index: count - 1))
    }

    @Test func positionsCountFromTheTopOfTheGrid() async {
        await open("smile")
        #expect(scope.grid.item(atFlatIndex: 0) == scope.grid.sections[0].items[0])
        #expect(scope.grid.item(atFlatIndex: 2) == scope.grid.sections[0].items[2])
        #expect(scope.grid.item(atFlatIndex: 100_000) == nil)
        #expect(scope.grid.item(atFlatIndex: -1) == nil)
    }

    @Test func clearingDropsTheGrid() async {
        await open("")
        scope.clear()
        #expect(scope.grid.sections.isEmpty)
        #expect(scope.grid.selection == nil)
        #expect(!scope.hasLoaded)
    }

    // MARK: - Picking

    @Test func returnPastesInTheSkinToneAndCountsTheUse() async throws {
        await open("thumbsup")
        let thumbs = try #require(scope.selected)
        settings.cycleSkinTone()
        #expect(scope.activate(.primary, target: .selected))
        let delivery = try #require(palette.deliveries.first)
        #expect(delivery.content?.text == thumbs.character(tone: .light))
        #expect(delivery.action == .paste(.plainText))
        #expect(delivery.restoringPasteboard, "picking one does not lose the clipboard")
        #expect(delivery.recording == .skip)
        #expect(settings.usage.top(1) == [thumbs.character])
    }

    @Test func optionCopiesAndCommandDigitsPickByPosition() async throws {
        await open("smile")
        let third = try #require(scope.grid.item(atFlatIndex: 2))
        #expect(scope.activate(.optionShift, target: .position(2)))
        #expect(palette.deliveries.first?.action == .copyOnly)
        #expect(palette.deliveries.first?.recording == .record(sensitive: false), "a copy lands in the history")
        #expect(palette.deliveries.first?.content?.text == third.character(tone: nil))
    }

    @Test func tabCyclesTheSkinTone() throws {
        let tab = try #require(scope.keys.first { $0.combo == .tab })
        #expect(tab.hint == "Skin tone")
        #expect(tab.perform?() == true)
        #expect(settings.skinTone == .light)
        #expect(scope.navigation == .grid(columns: EmojiScope.columns))
    }

    // MARK: - Settings

    @Test func skinToneCyclesAndIsRemembered() {
        #expect(settings.skinTone == nil)
        settings.cycleSkinTone()
        settings.cycleSkinTone()
        #expect(settings.skinTone == .mediumLight)
        #expect(EmojiSettings(defaults: defaults).skinTone == .mediumLight)
        for _ in 0..<4 { settings.cycleSkinTone() }
        #expect(settings.skinTone == nil)
        #expect(EmojiSettings(defaults: defaults).skinTone == nil)
    }

    @Test func usageIsRemembered() throws {
        let fire = try #require(EmojiCatalog.shared.search("fire").first)
        settings.recordUse(of: fire)
        #expect(EmojiSettings(defaults: defaults).usage.top(1) == [fire.character])
    }
}
