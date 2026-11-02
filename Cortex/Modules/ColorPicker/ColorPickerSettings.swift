import Foundation
import CortexCore

/// Color picker preferences, stored as "color-picker.<name>".
@MainActor
@Observable
final class ColorPickerSettings {
    @ObservationIgnored private let defaults: ModuleDefaults

    /// What a picked colour is copied as.
    var format: ColorFormat { didSet { defaults.set(format.rawValue, for: "format") } }
    /// `#1A2B3C` rather than `#1a2b3c`.
    var uppercaseHex: Bool { didSet { defaults.set(uppercaseHex, for: "uppercaseHex") } }
    /// A notification says what was copied.
    var notify: Bool { didSet { defaults.set(notify, for: "notify") } }

    init(defaults: ModuleDefaults) {
        self.defaults = defaults
        format = defaults.string("format").flatMap(ColorFormat.init(rawValue:)) ?? .hex
        uppercaseHex = defaults.bool("uppercaseHex") ?? true
        notify = defaults.bool("notify") ?? true
    }

    func string(for color: ColorValue) -> String {
        format.string(for: color, uppercaseHex: uppercaseHex)
    }
}
