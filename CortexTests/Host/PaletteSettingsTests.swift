import Foundation
import Testing
@testable import Cortex

@MainActor
@Suite struct PaletteSettingsTests {
    let suiteName = "CortexTests-\(UUID().uuidString)"
    var defaults: UserDefaults { UserDefaults(suiteName: suiteName)! }

    @Test func classicByDefault() {
        #expect(PaletteSettings(defaults: defaults).style == .classic)
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func stylePersists() {
        PaletteSettings(defaults: defaults).style = .glass
        #expect(PaletteSettings(defaults: defaults).style == .glass)
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func unknownStyleFallsBackToClassic() {
        defaults.set("neon", forKey: "paletteStyle")
        #expect(PaletteSettings(defaults: defaults).style == .classic)
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func positionPersistsAndResets() {
        #expect(PaletteSettings(defaults: defaults).position == nil)
        PaletteSettings(defaults: defaults).position = CGPoint(x: 0.25, y: 0.75)
        let reloaded = PaletteSettings(defaults: defaults)
        #expect(reloaded.position == CGPoint(x: 0.25, y: 0.75))
        reloaded.position = nil
        #expect(PaletteSettings(defaults: defaults).position == nil)
        defaults.removePersistentDomain(forName: suiteName)
    }
}

@Suite struct PanelPlacementTests {
    let size = CGSize(width: 820, height: 520)
    let screen = CGRect(x: 0, y: 25, width: 1600, height: 1000)

    @Test func centredWithoutAPosition() {
        #expect(PanelPlacement.origin(size: size, relativeCenter: nil, in: screen) == CGPoint(x: 390, y: 265))
    }

    @Test func roundTripsAPosition() {
        let frame = CGRect(origin: CGPoint(x: 100, y: 400), size: size)
        let relative = PanelPlacement.relativeCenter(of: frame, in: screen)
        #expect(PanelPlacement.origin(size: size, relativeCenter: relative, in: screen) == frame.origin)
    }

    @Test func sameRelativePlaceOnAnotherScreen() {
        let other = CGRect(x: -1200, y: 0, width: 3200, height: 2000)
        // Centre a quarter in from the left, at mid height.
        let origin = PanelPlacement.origin(size: size, relativeCenter: CGPoint(x: 0.25, y: 0.5), in: other)
        #expect(origin == CGPoint(x: -1200 + 800 - 410, y: 1000 - 260))
    }

    @Test func keptOnScreen() {
        let corner = PanelPlacement.origin(size: size, relativeCenter: CGPoint(x: 1, y: 0), in: screen)
        #expect(corner == CGPoint(x: 1600 - 820, y: 25))
    }
}
