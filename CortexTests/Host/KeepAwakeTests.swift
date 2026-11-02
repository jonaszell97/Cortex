import Foundation
import Testing
@testable import Cortex

@MainActor
@Suite struct KeepAwakeTests {
    let suiteName = "CortexTests-\(UUID().uuidString)"
    var defaults: UserDefaults { UserDefaults(suiteName: suiteName)! }

    @Test func offByDefault() {
        let keepAwake = KeepAwake(defaults: defaults)
        #expect(!keepAwake.isEnabled)
        #expect(!keepAwake.isRunning)
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func togglingStartsAndStopsCaffeinate() {
        let keepAwake = KeepAwake(defaults: defaults)
        keepAwake.isEnabled = true
        #expect(keepAwake.isRunning)
        #expect(keepAwake.lastError == nil)
        #expect(KeepAwake(defaults: defaults).isEnabled)

        keepAwake.isEnabled = false
        #expect(!keepAwake.isRunning)
        #expect(!KeepAwake(defaults: defaults).isEnabled)
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func savedChoiceIsNotAppliedUntilAsked() {
        defaults.set(true, forKey: KeepAwake.key)
        let keepAwake = KeepAwake(defaults: defaults)
        #expect(keepAwake.isEnabled)
        #expect(!keepAwake.isRunning)
        keepAwake.apply()
        #expect(keepAwake.isRunning)
        keepAwake.stop()
        #expect(!keepAwake.isRunning)
        defaults.removePersistentDomain(forName: suiteName)
    }
}
