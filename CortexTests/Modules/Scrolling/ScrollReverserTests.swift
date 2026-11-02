import CoreGraphics
import Foundation
import Testing
@testable import Cortex

@MainActor
@Suite struct ScrollingSettingsTests {
    let suiteName = "CortexTests-\(UUID().uuidString)"
    var defaults: UserDefaults { UserDefaults(suiteName: suiteName)! }

    @Test func reversesTheMouseVerticallyByDefault() {
        let settings = ScrollingSettings(defaults: defaults)
        #expect(settings.activeRules == ScrollReverser.Rules(vertical: true, mouse: true, wheelStep: 3))
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func noRulesWithoutDirectionOrDevice() {
        let settings = ScrollingSettings(defaults: defaults)
        settings.wheelStepSize = 0
        settings.reverseMouse = false
        #expect(settings.activeRules == nil)
        settings.reverseTrackpad = true
        settings.reverseVertical = false
        #expect(settings.activeRules == nil)
        settings.reverseHorizontal = true
        #expect(settings.activeRules == ScrollReverser.Rules(horizontal: true, trackpad: true))
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func stepSizeAloneIsEnoughForRules() {
        let settings = ScrollingSettings(defaults: defaults)
        settings.reverseVertical = false
        #expect(settings.activeRules == ScrollReverser.Rules(mouse: true, wheelStep: 3))
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func sliderMatchesScrollReverser() {
        #expect(ScrollingSettings.stepSize(sliderPosition: 0) == 0)
        #expect(ScrollingSettings.stepSize(sliderPosition: 1) == 30)
        // Scroll Reverser's default sits at about a fifth of the slider.
        #expect(abs(ScrollingSettings.sliderPosition(stepSize: 3) - 0.208) < 0.001)
        for step in 0...30 {
            #expect(ScrollingSettings.stepSize(sliderPosition: ScrollingSettings.sliderPosition(stepSize: step)) == step)
        }
        #expect(ScrollingSettings.sliderPosition(stepSize: 100) == 1)
    }

    @Test func changesPersist() {
        let settings = ScrollingSettings(defaults: defaults)
        settings.reverseHorizontal = true
        settings.reverseTrackpad = true
        settings.wheelStepSize = 7

        let reloaded = ScrollingSettings(defaults: defaults)
        #expect(reloaded.reverseHorizontal)
        #expect(reloaded.reverseTrackpad)
        #expect(reloaded.reverseVertical)
        #expect(reloaded.reverseMouse)
        #expect(reloaded.wheelStepSize == 7)
        defaults.removePersistentDomain(forName: suiteName)
    }
}

@Suite struct ScrollReverserTests {
    struct Deltas: Equatable {
        var lines: Int64
        var fixed: Double
        var points: Int64
    }

    /// A wheel event as a mouse sends it, or a trackpad one when given phases.
    func scrollEvent(vertical: Int32, horizontal: Int32, phase: Int64 = 0, momentum: Int64 = 0) throws -> CGEvent {
        let event = try #require(CGEvent(
            scrollWheelEvent2Source: nil, units: .line, wheelCount: 2,
            wheel1: vertical, wheel2: horizontal, wheel3: 0))
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        return event
    }

    func vertical(_ event: CGEvent) -> Deltas {
        Deltas(
            lines: event.getIntegerValueField(.scrollWheelEventDeltaAxis1),
            fixed: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1),
            points: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
    }

    func horizontal(_ event: CGEvent) -> Deltas {
        Deltas(
            lines: event.getIntegerValueField(.scrollWheelEventDeltaAxis2),
            fixed: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2),
            points: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
    }

    func negated(_ deltas: Deltas) -> Deltas {
        Deltas(lines: -deltas.lines, fixed: -deltas.fixed, points: -deltas.points)
    }

    @Test func wheelWithoutPhaseIsAMouse() throws {
        #expect(ScrollReverser.source(of: try scrollEvent(vertical: 3, horizontal: 0)) == .mouse)
        let smooth = try scrollEvent(vertical: 3, horizontal: 0)
        smooth.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        #expect(ScrollReverser.source(of: smooth) == .mouse)
    }

    @Test(arguments: [(Int64(1), Int64(0)), (2, 0), (4, 0), (128, 0), (0, 1), (0, 2), (0, 3)])
    func phasesMeanATrackpad(phase: Int64, momentum: Int64) throws {
        let event = try scrollEvent(vertical: 3, horizontal: 0, phase: phase, momentum: momentum)
        #expect(ScrollReverser.source(of: event) == .trackpad)
    }

    @Test func reversesAllVerticalDeltasOfTheMouse() throws {
        let event = try scrollEvent(vertical: 3, horizontal: 2)
        let before = vertical(event)
        let horizontalBefore = horizontal(event)
        #expect(before.lines != 0 && before.fixed != 0 && before.points != 0)

        ScrollReverser.apply(.init(vertical: true, mouse: true), to: event)
        #expect(vertical(event) == negated(before))
        #expect(horizontal(event) == horizontalBefore)
    }

    @Test func leavesTheTrackpadAloneWhenOnlyTheMouseIsReversed() throws {
        for (phase, momentum) in [(Int64(2), Int64(0)), (0, 2)] {
            let event = try scrollEvent(vertical: -4, horizontal: 0, phase: phase, momentum: momentum)
            let before = vertical(event)
            ScrollReverser.apply(.init(vertical: true, horizontal: true, mouse: true), to: event)
            #expect(vertical(event) == before)
        }
    }

    @Test func reversesTheTrackpadHorizontally() throws {
        let event = try scrollEvent(vertical: 1, horizontal: -5, phase: 2)
        let before = horizontal(event)
        let verticalBefore = vertical(event)
        #expect(before.lines != 0 && before.fixed != 0 && before.points != 0)

        ScrollReverser.apply(.init(horizontal: true, trackpad: true), to: event)
        #expect(horizontal(event) == negated(before))
        #expect(vertical(event) == verticalBefore)
    }

    @Test func setsTheStepOfASingleNotch() throws {
        let event = try scrollEvent(vertical: 1, horizontal: 0)
        ScrollReverser.apply(.init(wheelStep: 3), to: event)
        #expect(vertical(event) == Deltas(lines: 3, fixed: 3, points: 24))
        #expect(horizontal(event) == Deltas(lines: 0, fixed: 0, points: 0))

        let down = try scrollEvent(vertical: -1, horizontal: 0)
        ScrollReverser.apply(.init(vertical: true, mouse: true, wheelStep: 5), to: down)
        #expect(vertical(down) == Deltas(lines: 5, fixed: 5, points: 40))
    }

    @Test func leavesFasterTurnsTheirSizeButReversesThem() throws {
        let event = try scrollEvent(vertical: 4, horizontal: 0)
        let before = vertical(event)
        ScrollReverser.apply(.init(vertical: true, mouse: true, wheelStep: 3), to: event)
        #expect(vertical(event) == negated(before))
    }

    @Test func neverStepsContinuousScrolling() throws {
        let trackpad = try scrollEvent(vertical: 1, horizontal: 0, phase: 2)
        trackpad.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        let smooth = try scrollEvent(vertical: 1, horizontal: 0)
        smooth.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        for event in [trackpad, smooth] {
            let before = vertical(event)
            ScrollReverser.apply(.init(wheelStep: 10), to: event)
            #expect(vertical(event) == before)
        }
    }

    @Test func reversingTwiceRestoresTheEvent() throws {
        let event = try scrollEvent(vertical: 7, horizontal: -2)
        let before = (vertical(event), horizontal(event))
        let rules = ScrollReverser.Rules(vertical: true, horizontal: true, mouse: true)
        ScrollReverser.apply(rules, to: event)
        ScrollReverser.apply(rules, to: event)
        #expect(vertical(event) == before.0)
        #expect(horizontal(event) == before.1)
    }
}
