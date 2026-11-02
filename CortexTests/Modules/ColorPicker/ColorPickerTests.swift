import Foundation
import Testing
@testable import Cortex
import CortexCore

/// Hands out the colours it is given, or waits until it is told what was
/// picked (`waits`).
@MainActor
final class FakeColorSampler: ColorSampling {
    var picks: [ColorValue?] = []
    var waits = false
    private(set) var samples = 0
    private var pending: CheckedContinuation<ColorValue?, Never>?

    func sample() async -> ColorValue? {
        samples += 1
        guard waits else { return picks.isEmpty ? nil : picks.removeFirst() }
        return await withCheckedContinuation { pending = $0 }
    }

    var isWaiting: Bool { pending != nil }

    func finish(_ color: ColorValue?) {
        pending?.resume(returning: color)
        pending = nil
    }
}

@MainActor
@Suite struct ColorPickerTests {
    static let slate = ColorValue(red255: 26, green255: 43, blue255: 60)

    let suiteName = "CortexTests-\(UUID().uuidString)"
    let palette = FakePaletteHost()
    let sampler = FakeColorSampler()

    func module() throws -> ColorPickerModule {
        let services = ModuleServices(
            database: try makeTestDatabase(), defaults: UserDefaults(suiteName: suiteName)!, secrets: MemorySecrets())
        services.palette = palette
        let host = ModuleHost(ModuleList.all, services: services, registerHotkey: { _ in }, setHotkeyEnabled: { _, _ in })
        let module = try #require(host.module(ColorPickerModule.self))
        module.sampler = sampler
        module.settings.notify = false
        return module
    }

    func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    @Test func copiesThePickedColourAsANewClip() async throws {
        let module = try module()
        defer { tearDown() }
        sampler.picks = [Self.slate]

        #expect(await module.pick() == "#1A2B3C")
        let delivery = try #require(palette.deliveries.last)
        guard case .text(let text) = delivery.content else {
            Issue.record("expected text")
            return
        }
        #expect(text == "#1A2B3C")
        #expect(delivery.action == .copyOnly)
        #expect(delivery.recording == .record(sensitive: false))
        #expect(!delivery.restoringPasteboard)
    }

    @Test func escLeavesTheClipboardAlone() async throws {
        let module = try module()
        defer { tearDown() }
        sampler.picks = [nil]

        #expect(await module.pick() == nil)
        #expect(palette.deliveries.isEmpty)
    }

    @Test func closesThePaletteFirst() async throws {
        let module = try module()
        defer { tearDown() }
        palette.isVisible = true
        sampler.picks = [nil]

        await module.pick()
        #expect(!palette.isVisible)
    }

    @Test func usesTheChosenFormat() async throws {
        let module = try module()
        defer { tearDown() }
        let translucent = ColorValue(red255: 26, green255: 43, blue255: 60, alpha255: 128)

        module.settings.format = .rgb
        sampler.picks = [Self.slate, translucent]
        #expect(await module.pick() == "rgb(26, 43, 60)")
        #expect(await module.pick() == "rgba(26, 43, 60, 0.5)")

        module.settings.format = .hexWithoutHash
        module.settings.uppercaseHex = false
        sampler.picks = [Self.slate]
        #expect(await module.pick() == "1a2b3c")
    }

    @Test func aSecondPressWhilePickingDoesNothing() async throws {
        let module = try module()
        defer { tearDown() }
        sampler.waits = true

        let first = Task { await module.pick() }
        while !sampler.isWaiting { await Task.yield() }
        #expect(module.isPicking)
        #expect(await module.pick() == nil)
        #expect(sampler.samples == 1)

        sampler.finish(Self.slate)
        #expect(await first.value == "#1A2B3C")
        #expect(!module.isPicking)
        #expect(palette.deliveries.count == 1)
    }

    /// `$color` returns at once, so no progress card shows while picking;
    /// the pick it started copies like the hotkey.
    @Test func colorCommandStartsAPick() async throws {
        let module = try module()
        defer { tearDown() }
        sampler.waits = true
        let command = try #require(module.contributedCommands.first as? ColorPickerCommand)
        #expect(command.name == "color")
        #expect(command.accepts(.none))

        // Resolving picks nothing; handing over does.
        guard case .handoff(let description, let handOver) = try await command.resolve(.none) else {
            Issue.record("expected a handoff")
            return
        }
        #expect(description == "Shows the eyedropper and copies the color you click.")
        #expect(!module.isPicking && !sampler.isWaiting)
        try await handOver()
        while !sampler.isWaiting { await Task.yield() }
        #expect(module.isPicking)

        sampler.finish(Self.slate)
        while module.isPicking { await Task.yield() }
        guard case .text(let text) = palette.deliveries.last?.content else {
            Issue.record("expected text")
            return
        }
        #expect(text == "#1A2B3C")
        #expect(palette.deliveries.last?.action == .copyOnly)
    }

    @Test func settingsAreStoredUnderTheModuleID() throws {
        let module = try module()
        defer { tearDown() }
        module.settings.format = .hsl
        module.settings.uppercaseHex = false
        let defaults = UserDefaults(suiteName: suiteName)!
        #expect(defaults.string(forKey: "color-picker.format") == "hsl")
        #expect(defaults.object(forKey: "color-picker.uppercaseHex") as? Bool == false)
        #expect(defaults.object(forKey: "color-picker.notify") as? Bool == false)

        let reloaded = ColorPickerSettings(defaults: ModuleDefaults(id: "color-picker", store: defaults))
        #expect(reloaded.format == .hsl)
        #expect(!reloaded.uppercaseHex)
    }
}
