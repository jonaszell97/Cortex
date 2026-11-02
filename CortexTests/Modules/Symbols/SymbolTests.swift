import AppKit
import Foundation
import Testing
@testable import Cortex
import CortexCore

@MainActor
@Suite struct SymbolTests {
    /// A small catalog with the shapes of the system data: a localized copy,
    /// a symbol without search words of its own, and a newer one.
    func makeCatalog(osMajor: Int = 27) -> SymbolCatalog {
        SymbolCatalog(
            order: [
                "star", "star.fill", "star.circle.fill", "heart", "heart.fill", "heart.fill.ar", "chevron.right",
                "chevron.right.rtl", "swift", "brandnew", "doc.richtext.fill.th",
            ],
            search: ["star": ["favorite", "vip"], "heart": ["love", "health"], "chevron.right": ["next"]],
            releases: [
                "star": "2019", "star.fill": "2019", "star.circle.fill": "2019.1", "heart": "2019", "heart.fill": "2019",
                "chevron.right": "2019", "swift": "2020", "brandnew": "2026", "doc.richtext.fill.th": "2019",
            ],
            releaseVersions: ["2019": "10.15", "2019.1": "10.15", "2020": "11.0", "2026": "27.0"],
            osVersion: OperatingSystemVersion(majorVersion: osMajor, minorVersion: 0, patchVersion: 0))
    }

    func names(_ catalog: SymbolCatalog, _ query: String, usage: UsageRanking = UsageRanking()) -> [String] {
        catalog.search(query, usage: usage).map(\.name)
    }

    @Test func leavesOutLocalizedCopiesWhenThePlainOneExists() {
        let names = makeCatalog().symbols.map(\.name)
        #expect(!names.contains("heart.fill.ar"))
        #expect(!names.contains("chevron.right.rtl"))
        // No plain "doc.richtext.fill" in the data: the copy is all there is.
        #expect(names.contains("doc.richtext.fill.th"))
        #expect(names.contains("heart.fill"))
    }

    @Test func leavesOutSymbolsNewerThanThisMac() {
        #expect(makeCatalog(osMajor: 27).symbol(named: "brandnew") != nil)
        #expect(makeCatalog(osMajor: 26).symbol(named: "brandnew") == nil)
        #expect(makeCatalog(osMajor: 26).symbol(named: "swift") != nil)
        #expect(makeCatalog().symbol(named: "swift")?.macOSVersion == "11.0")
    }

    @Test func emptyQueryListsEverythingInTheOrderOfSFSymbols() {
        let catalog = makeCatalog()
        #expect(catalog.search("").map(\.name) == catalog.symbols.map(\.name))
        #expect(catalog.search("::").count == catalog.symbols.count)
    }

    @Test func exactNameFirstThenShorterNamesStartingWithTheQuery() {
        #expect(names(makeCatalog(), "star") == ["star", "star.fill", "star.circle.fill"])
        #expect(names(makeCatalog(), "star.fill") == ["star.fill"])
        #expect(names(makeCatalog(), "star.f") == ["star.fill"])
    }

    @Test func wordsMatchPartsOfTheName() {
        // Not in order, and not at the start of the name.
        #expect(names(makeCatalog(), "fill star") == ["star.fill", "star.circle.fill"])
        #expect(names(makeCatalog(), "circle") == ["star.circle.fill"])
        #expect(names(makeCatalog(), "ircle") == ["star.circle.fill"])
    }

    @Test func dotsInTheNameCanBeLeftOut() {
        #expect(names(makeCatalog(), "starfill") == ["star.fill"])
        #expect(names(makeCatalog(), "starcircle") == ["star.circle.fill"])
        #expect(names(makeCatalog(), "circlefill") == ["star.circle.fill"])
        #expect(names(makeCatalog(), "chevronr") == ["chevron.right"])
        #expect(names(makeCatalog(), "star.circlefill") == ["star.circle.fill"])
        // Typed with dots, the exact name still comes first.
        #expect(names(makeCatalog(), "heartfill").first == "heart.fill")
        #expect(names(makeCatalog(), "heart").first == "heart")
    }

    @Test func findsBySystemKeywordsAndInheritsThemFromShorterNames() {
        #expect(names(makeCatalog(), "favorite") == ["star", "star.fill", "star.circle.fill"])
        #expect(names(makeCatalog(), "love") == ["heart", "heart.fill"])
        #expect(makeCatalog().symbol(named: "star.circle.fill")?.keywords == ["favorite", "vip"])
        #expect(makeCatalog().symbol(named: "swift")?.keywords == [])
    }

    @Test func noMatchesAndCase() {
        #expect(names(makeCatalog(), "zzz").isEmpty)
        #expect(names(makeCatalog(), "STAR.Fill") == ["star.fill"])
        #expect(names(makeCatalog(), "star zzz").isEmpty)
    }

    @Test func usageBreaksTiesAmongEqualMatches() {
        var usage = UsageRanking()
        usage.recordUse(of: "star.circle.fill")
        // "fill" is a whole part of all three; the used one wins the tie.
        #expect(names(makeCatalog(), "fill", usage: usage).first == "star.circle.fill")
        #expect(names(makeCatalog(), "fill").first == "star.fill")
    }

    // MARK: - This Mac's data

    @Test func readsTheSystemData() throws {
        let catalog = SymbolCatalog.system()
        try #require(!catalog.isEmpty, "CoreGlyphs.bundle should be readable on macOS")
        #expect(catalog.symbols.count > 5_000)
        #expect(catalog.symbol(named: "star.fill") != nil)
        #expect(names(catalog, "star.fill").first == "star.fill")
        #expect(names(catalog, "favorite").contains("star"))
        #expect(names(catalog, "personcircle").first == "person.circle")
        // Every symbol in the grid can be drawn by this version of macOS.
        let undrawable = catalog.symbols.filter { NSImage(systemSymbolName: $0.name, accessibilityDescription: nil) == nil }
        #expect(undrawable.isEmpty, "\(undrawable.prefix(5).map(\.name))")
    }

    @Test func missingSystemDataGivesAnEmptyCatalog() {
        let missing = URL(filePath: "/nonexistent-\(UUID().uuidString)")
        let catalog = SymbolCatalog.system(directory: missing)
        #expect(catalog.isEmpty)
        #expect(catalog.search("star").isEmpty)
    }

    // MARK: - Picture

    @Test func rendersAPNGWithTransparencyAndBlackInk() throws {
        let png = try #require(SymbolImage.png(for: "star.fill", pointSize: 64))
        let bitmap = try #require(NSBitmapImageRep(data: png))
        #expect(bitmap.pixelsWide > 40 && bitmap.pixelsHigh > 40)
        #expect(bitmap.hasAlpha)
        // The corner is empty; the middle of a filled star is solid black.
        let corner = try #require(bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
        #expect(corner.alphaComponent == 0)
        let middle = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
        #expect(middle.alphaComponent > 0.99)
        #expect(middle.redComponent < 0.01 && middle.greenComponent < 0.01 && middle.blueComponent < 0.01)
    }

    @Test func noPictureForAnUnknownName() {
        #expect(SymbolImage.png(for: "definitely.not.a.symbol") == nil)
    }

    // MARK: - The palette scope

    func makeScope(catalog: SymbolCatalog? = nil) -> (SymbolsScope, SymbolsSettings, FakePaletteHost) {
        let defaults = UserDefaults(suiteName: "SymbolTests-\(UUID().uuidString)")!
        let settings = SymbolsSettings(defaults: defaults)
        let palette = FakePaletteHost()
        let scope = if let catalog {
            SymbolsScope(settings: settings, catalog: { catalog }) { palette }
        } else {
            SymbolsScope(settings: settings) { palette }
        }
        return (scope, settings, palette)
    }

    @Test func symbolScopeListsAndSearchesThisMacsSymbols() async throws {
        let (scope, settings, _) = makeScope()

        scope.search("")
        await scope.loaded()
        #expect(scope.grid.sections.map(\.title) == ["All symbols"])
        #expect(scope.selected != nil)

        settings.recordUse(of: "star.fill")
        scope.search("star")
        await scope.loaded()
        #expect(scope.grid.sections.count == 1 && scope.grid.sections[0].title == nil)
        #expect(scope.selected?.name == "star")
        let matches = try #require(scope.grid.sections.first?.items.count)
        #expect(matches > SymbolsScope.columns + 1)
        scope.move(.vertical(1))
        scope.move(.sideways(1))
        #expect(scope.grid.selection == GridPosition(section: 0, index: SymbolsScope.columns + 1))

        scope.search("")
        await scope.loaded()
        #expect(scope.grid.sections.map(\.title) == ["Frequently used", "All symbols"])
        #expect(scope.grid.sections.first?.items.map(\.name) == ["star.fill"])

        scope.search("zzzzzzzz")
        await scope.loaded()
        #expect(scope.grid.isEmpty)
        #expect(scope.selected == nil)
        #expect(scope.hasLoaded)
        #expect(!scope.isCatalogEmpty)

        scope.clear()
        #expect(scope.grid.isEmpty)
        #expect(!scope.hasLoaded)
    }

    @Test func returnPastesTheNameAndShiftAPicture() async throws {
        let (scope, settings, palette) = makeScope(catalog: makeCatalog())
        scope.search("star")
        await scope.loaded()

        #expect(scope.activate(.primary, target: .selected))
        #expect(palette.deliveries.last?.content?.text == "star")
        #expect(palette.deliveries.last?.action == .paste(.plainText))
        #expect(palette.deliveries.last?.restoringPasteboard == true)
        #expect(palette.deliveries.last?.recording == .skip)

        #expect(scope.activate(.shift, target: .position(1)))
        #expect(palette.deliveries.last?.content?.isImage == true)
        #expect(palette.deliveries.last?.action == .paste(.plainText))

        #expect(scope.activate(.optionShift, target: .selected))
        #expect(palette.deliveries.last?.content?.isImage == true)
        #expect(palette.deliveries.last?.action == .copyOnly)
        #expect(palette.deliveries.last?.recording == .record(sensitive: false), "a copy lands in the history")
        #expect(settings.usage.top(2).sorted() == ["star", "star.fill"])
    }

    @Test func anEmptyCatalogSaysSo() async {
        let (scope, _, _) = makeScope(catalog: SymbolCatalog.system(directory: URL(filePath: "/nonexistent-\(UUID().uuidString)")))
        scope.search("")
        await scope.loaded()
        #expect(scope.grid.isEmpty)
        #expect(scope.isCatalogEmpty)
    }

    @Test func symbolUsageIsRemembered() {
        let defaults = UserDefaults(suiteName: "SymbolTests-\(UUID().uuidString)")!
        SymbolsSettings(defaults: defaults).recordUse(of: "heart.fill")
        #expect(SymbolsSettings(defaults: defaults).usage.top(1) == ["heart.fill"])
        #expect(EmojiSettings(defaults: defaults).usage.isEmpty, "emoji and symbols are counted apart")
    }
}
