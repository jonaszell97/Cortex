import Foundation
import Testing
@testable import Cortex
import CortexCore

/// The palette's `=` scope: the rows for calculations, conversions and
/// quantities, errors, pasting, ⇥, and the recent calculations.
@MainActor
@Suite struct CalculatorScopeTests {
    let suiteName = "CortexTests-\(UUID().uuidString)"
    let palette = FakePaletteHost()
    let store: UserDefaults
    let settings: CalculatorSettings

    init() {
        store = UserDefaults(suiteName: suiteName)!
        settings = CalculatorSettings(defaults: ModuleDefaults(id: "calculator", store: store))
    }

    func scope(_ locale: String = "en_US") -> CalculatorScope {
        let palette = palette
        return CalculatorScope(settings: settings, moduleID: "calculator", locale: Locale(identifier: locale)) { palette }
    }

    func rows(_ scope: CalculatorScope, _ query: String) -> [String] {
        scope.search(query)
        return scope.list.items.map(\.text)
    }

    func press(_ combo: KeyCombo, in scope: CalculatorScope) -> Bool? {
        scope.keys.first { $0.combo == combo }?.perform?()
    }

    // MARK: Rows

    @Test func calculation() {
        let scope = scope()
        #expect(rows(scope, "1920/1080") == ["1.777777778", "1.7777777777777777"])
        #expect(scope.understood == "1920 ÷ 1080")
        #expect(scope.exact == "1.7777777777777777")
        #expect(scope.error == nil)
        #expect(scope.list.selected?.text == "1.777777778")
    }

    @Test func oneRowWhenBothAgree() {
        #expect(rows(scope(), "2 + 2") == ["4"])
    }

    @Test func groupingOnlyInTheResultRow() {
        #expect(rows(scope(), "1920 * 1080") == ["2,073,600", "2073600"])
    }

    @Test func germanNumbers() {
        let scope = scope("de_DE")
        #expect(rows(scope, "3,5 * 2") == ["7"])
        #expect(rows(scope, "1/4") == ["0,25", "0.25"])
        #expect(rows(scope, "1920 * 1080") == ["2.073.600", "2073600"])
    }

    @Test func pointInsteadOfTheSystemFormat() {
        settings.decimalSeparator = .point
        #expect(rows(scope("de_DE"), "1/4") == ["0.25"])
        #expect(rows(scope("de_DE"), "1920 * 1080") == ["2073600"])
    }

    @Test func digits() {
        settings.digits = 3
        #expect(rows(scope(), "pi") == ["3.14", "3.141592653589793"])
        settings.digits = 40
        #expect(settings.digits == 15)
    }

    @Test func conversion() {
        let scope = scope()
        #expect(rows(scope, "3 in to cm") == ["7.62 cm", "7.62"])
        #expect(scope.list.items.map(\.subtitle) == ["Result", "Without the unit"])
        #expect(scope.understood == "3 inches → centimetres")
        #expect(scope.exact == "7.62 cm")
    }

    @Test func conversionWithAnInexactResult() {
        #expect(rows(scope(), "1 m to ft") == ["3.280839895 ft", "3.280839895", "3.28083989501312"])
    }

    @Test func quantityInOtherUnits() {
        let scope = scope()
        #expect(rows(scope, "5 ft") == ["1.524 m", "152.4 cm", "60 in"])
        #expect(scope.list.items.map(\.subtitle) == ["metres", "centimetres", "inches"])
        #expect(scope.understood == "5 feet")
    }

    @Test func errorsAreShownUnfinishedInputIsNot() {
        let scope = scope()
        #expect(rows(scope, "1/0").isEmpty)
        #expect(scope.error == "Division by zero")
        #expect(rows(scope, "3 kg to cm").isEmpty)
        #expect(scope.error == "Can't convert mass to length")
        #expect(rows(scope, "3 +").isEmpty)
        #expect(scope.error == nil)
        #expect(rows(scope, "3 m to c").isEmpty)
        #expect(scope.error == nil)
    }

    // MARK: Delivering

    @Test func returnPastesTheSelectedRowAndRemembersTheCalculation() throws {
        let scope = scope()
        scope.search(" 1920/1080 ")
        #expect(scope.activate(.primary, target: .selected))
        let delivery = try #require(palette.deliveries.last)
        #expect(delivery.content?.text == "1.777777778")
        #expect(delivery.action == .paste(.plainText))
        #expect(delivery.recording == .record(sensitive: false))
        #expect(!delivery.restoringPasteboard)
        #expect(settings.recents == ["1920/1080"])
    }

    @Test func optionReturnCopies() throws {
        let scope = scope()
        scope.search("3 in to cm")
        scope.move(.vertical(1))
        #expect(scope.activate(.option, target: .selected))
        let delivery = try #require(palette.deliveries.last)
        #expect(delivery.content?.text == "7.62")
        #expect(delivery.action == .copyOnly)
    }

    @Test func commandNumberPastesThatRow() throws {
        let scope = scope()
        scope.search("1920/1080")
        #expect(scope.activate(.primary, target: .position(1)))
        #expect(try #require(palette.deliveries.last).content?.text == "1.7777777777777777")
    }

    @Test func returnWithoutAResultDeliversNothing() {
        let scope = scope()
        scope.search("1/0")
        #expect(scope.activate(.primary, target: .selected))
        #expect(palette.deliveries.isEmpty)
        #expect(settings.recents.isEmpty)
    }

    @Test func tabKeepsCalculatingWithTheExactValue() {
        let scope = scope()
        scope.search("1920/1080")
        #expect(press(.tab, in: scope) == true)
        scope.search("3 in to cm")
        _ = press(.tab, in: scope)
        scope.search("5 ft")
        _ = press(.tab, in: scope)
        #expect(palette.searches == ["1.7777777777777777", "7.62 cm", "1.524 m"])
        #expect(palette.opened == ["calculator", "calculator", "calculator"])
    }

    @Test func hints() {
        let scope = scope()
        scope.search("2+2")
        #expect(scope.activationHints.map(\.label) == ["Paste", "Copy"])
        #expect(scope.keys.compactMap(\.hint) == ["Keep calculating"])
        scope.search("1/0")
        #expect(scope.activationHints.isEmpty)
        #expect(scope.keys.compactMap(\.hint).isEmpty)
    }

    // MARK: Recent calculations

    @Test func nothingTypedListsRecentsNewestFirst() {
        settings.addRecent("2+2")
        settings.addRecent("3 in to cm")
        let scope = scope()
        #expect(rows(scope, "") == ["3 in to cm", "2+2"])
        #expect(scope.list.items.map(\.subtitle) == ["= 7.62 cm", "= 4"])
        #expect(scope.list.items.allSatisfy { $0.kind == .recent })
        #expect(scope.activationHints.map(\.label) == ["Calculate again"])
        #expect(scope.keys.compactMap(\.hint) == ["Forget"])
    }

    @Test func returnOnARecentPutsItBack() {
        settings.addRecent("2+2")
        let scope = scope()
        scope.search("")
        #expect(scope.activate(.primary, target: .selected))
        #expect(palette.searches == ["2+2"])
        #expect(palette.deliveries.isEmpty)
    }

    @Test func commandDeleteForgetsARecent() {
        settings.addRecent("1+1")
        settings.addRecent("2+2")
        let scope = scope()
        scope.search("")
        #expect(press(.command(.delete), in: scope) == true)
        #expect(settings.recents == ["1+1"])
        #expect(scope.list.items.map(\.text) == ["1+1"])
        scope.search("1+1")
        #expect(press(.command(.delete), in: scope) == false, "the field deletes the text")
    }

    @Test func recentsMoveToTheTopAndAreCapped() {
        for index in 0..<25 { settings.addRecent("\(index) + 1") }
        settings.addRecent("3 + 1")
        #expect(settings.recents.count == CalculatorSettings.maxRecents)
        #expect(settings.recents.first == "3 + 1")
        #expect(settings.recents.filter { $0 == "3 + 1" }.count == 1)
        #expect(settings.recents.last == "6 + 1")
    }

    @Test func turningRecentsOffForgetsThem() {
        settings.addRecent("2+2")
        settings.keepRecents = false
        #expect(settings.recents.isEmpty)
        settings.addRecent("3+3")
        #expect(settings.recents.isEmpty)
    }

    @Test func clearDropsEverything() {
        let scope = scope()
        scope.search("1/0")
        scope.clear()
        #expect(scope.list.isEmpty)
        #expect(scope.error == nil)
        #expect(scope.query.isEmpty)
    }

    // MARK: Settings

    @Test func storedKeys() {
        settings.digits = 12
        settings.decimalSeparator = .point
        settings.keepRecents = true
        settings.addRecent("1+1")
        #expect(store.integer(forKey: "calculator.digits") == 12)
        #expect(store.string(forKey: "calculator.decimalSeparator") == "point")
        #expect(store.object(forKey: "calculator.keepRecents") as? Bool == true)
        #expect(store.stringArray(forKey: "calculator.recents") == ["1+1"])

        let reloaded = CalculatorSettings(defaults: ModuleDefaults(id: "calculator", store: store))
        #expect(reloaded.digits == 12)
        #expect(reloaded.decimalSeparator == .point)
        #expect(reloaded.recents == ["1+1"])
    }
}
