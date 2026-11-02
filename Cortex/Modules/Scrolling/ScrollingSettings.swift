import Foundation

/// Scroll direction preferences, stored in UserDefaults.
@MainActor
@Observable
final class ScrollingSettings {
    private enum Key {
        static let vertical = "scrollReverseVertical"
        static let horizontal = "scrollReverseHorizontal"
        static let trackpad = "scrollReverseTrackpad"
        static let mouse = "scrollReverseMouse"
        static let wheelStepSize = "scrollWheelStepSize"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var reverseVertical: Bool { didSet { defaults.set(reverseVertical, forKey: Key.vertical) } }
    var reverseHorizontal: Bool { didSet { defaults.set(reverseHorizontal, forKey: Key.horizontal) } }
    var reverseTrackpad: Bool { didSet { defaults.set(reverseTrackpad, forKey: Key.trackpad) } }
    var reverseMouse: Bool { didSet { defaults.set(reverseMouse, forKey: Key.mouse) } }
    /// Lines one wheel notch scrolls, or 0 to leave the wheel to macOS.
    var wheelStepSize: Int { didSet { defaults.set(wheelStepSize, forKey: Key.wheelStepSize) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Natural scrolling on the trackpad, classic scrolling on the mouse,
        // and Scroll Reverser's default step size.
        defaults.register(defaults: [
            Key.vertical: true,
            Key.horizontal: false,
            Key.trackpad: false,
            Key.mouse: true,
            Key.wheelStepSize: 3,
        ])
        reverseVertical = defaults.bool(forKey: Key.vertical)
        reverseHorizontal = defaults.bool(forKey: Key.horizontal)
        reverseTrackpad = defaults.bool(forKey: Key.trackpad)
        reverseMouse = defaults.bool(forKey: Key.mouse)
        wheelStepSize = defaults.integer(forKey: Key.wheelStepSize)
    }

    /// The rules to run the tap with, or nil when they would change no event.
    /// Whether scrolling is adjusted at all is the module's switch
    /// ("scrollReversal" before modules).
    var activeRules: ScrollReverser.Rules? {
        let rules = ScrollReverser.Rules(
            vertical: reverseVertical, horizontal: reverseHorizontal,
            trackpad: reverseTrackpad, mouse: reverseMouse, wheelStep: wheelStepSize)
        return rules.isEffective ? rules : nil
    }

    // MARK: - Step size slider

    /// The slider runs from 0 to 1 and is finer at the small end, the way
    /// Scroll Reverser's is, so its positions mean the same: far left is 0
    /// (left to macOS), the default 3 sits at about a fifth, far right is 30.
    nonisolated static func stepSize(sliderPosition: Double) -> Int {
        Int((pow(sliderPosition + 0.1, 1.8) * 25).rounded())
    }

    nonisolated static func sliderPosition(stepSize: Int) -> Double {
        min(max(pow(Double(stepSize) / 25, 1 / 1.8) - 0.1, 0), 1)
    }
}
