import Observation
import Testing
@testable import Cortex

/// Starting and stopping something exactly while a setting wants it.
@MainActor
@Suite struct WhileWantedTests {
    @MainActor @Observable final class Setting {
        var value: Int?
    }

    @MainActor final class Tap {
        var started: [Int] = []
        var stops = 0
    }

    @MainActor final class Trust {
        var isTrusted = true
    }

    let setting = Setting()
    let tap = Tap()
    let trust = Trust()
    let accessibility: AccessibilityPermission

    init() {
        let trust = trust
        accessibility = AccessibilityPermission(isTrusted: { trust.isTrusted })
    }

    func run() -> ModuleTask {
        let (setting, tap) = (setting, tap)
        return whileWanted(
            accessibility: accessibility,
            { setting.value },
            start: { tap.started.append($0); return true },
            stop: { tap.stops += 1 })
    }

    /// Lets the observation's follow-up run.
    func settle() async {
        for _ in 0..<10 { await Task.yield() }
    }

    @Test func startsWithTheValueAndStopsWhenNoLongerWanted() async {
        setting.value = 1
        let task = run()
        #expect(tap.started == [1])

        setting.value = 2
        await settle()
        #expect(tap.started == [1, 2], "a new value reaches the running tap")

        setting.value = nil
        await settle()
        #expect(tap.stops == 1)
        withExtendedLifetime(task) {}
    }

    @Test func doesNotStartWhileUnwanted() async {
        let task = run()
        #expect(tap.started.isEmpty)
        setting.value = 3
        await settle()
        #expect(tap.started == [3])
        withExtendedLifetime(task) {}
    }

    /// A tap left running without the permission freezes all input.
    @Test func stopsWhenThePermissionIsRevokedAndRestartsWhenGranted() async {
        setting.value = 1
        let task = run()
        #expect(tap.started == [1])

        trust.isTrusted = false
        accessibility.refresh()
        await settle()
        #expect(tap.stops == 1)

        trust.isTrusted = true
        accessibility.refresh()
        await settle()
        #expect(tap.started == [1, 1])
        withExtendedLifetime(task) {}
    }

    @Test func doesNotStartWithoutThePermission() async {
        let accessibility = AccessibilityPermission(isTrusted: { false })
        let tap = tap
        setting.value = 1
        let task = whileWanted(
            accessibility: accessibility, { [setting] in setting.value },
            start: { tap.started.append($0); return true }, stop: { tap.stops += 1 })
        #expect(tap.started.isEmpty)
        task.cancel()
    }

    @Test func cancellingStopsForGood() async {
        setting.value = 1
        let task = run()
        task.cancel()
        #expect(tap.stops == 1)
        #expect(task.isCancelled)

        setting.value = 2
        await settle()
        #expect(tap.started == [1])
    }

    @Test func waitsForThePermission() async {
        trust.isTrusted = false
        accessibility.refresh()
        setting.value = 1
        let task = run()
        #expect(tap.started.isEmpty)

        trust.isTrusted = true
        accessibility.refresh()
        await settle()
        #expect(tap.started == [1])
        withExtendedLifetime(task) {}
    }

    @Test func stopsWhenThePermissionIsRevoked() async {
        setting.value = 1
        let task = run()
        #expect(tap.started == [1])

        trust.isTrusted = false
        accessibility.refresh()
        await settle()
        #expect(tap.stops == 1, "a tap without the permission freezes all input")

        trust.isTrusted = true
        accessibility.refresh()
        await settle()
        #expect(tap.started == [1, 1])
        withExtendedLifetime(task) {}
    }
}
