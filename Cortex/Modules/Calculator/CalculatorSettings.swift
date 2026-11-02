import Foundation

/// How the result row writes decimals. The raw values are stored settings;
/// never rename one.
enum CalculatorDecimalSeparator: String, CaseIterable {
    /// The system's number format, with its grouping: `1.234,5` in German.
    case system
    /// `1234.5`, whatever the system says.
    case point
}

/// Calculator preferences and recent calculations, stored as
/// "calculator.<name>" on this Mac (not synced).
@MainActor
@Observable
final class CalculatorSettings {
    static let digitRange = 1...15
    static let maxRecents = 20

    @ObservationIgnored private let defaults: ModuleDefaults

    /// Significant digits of the result row.
    var digits: Int {
        didSet {
            let clamped = min(max(digits, Self.digitRange.lowerBound), Self.digitRange.upperBound)
            if clamped != digits { digits = clamped }
            defaults.set(digits, for: "digits")
        }
    }
    var decimalSeparator: CalculatorDecimalSeparator { didSet { defaults.set(decimalSeparator.rawValue, for: "decimalSeparator") } }
    /// Off forgets the recent calculations.
    var keepRecents: Bool {
        didSet {
            defaults.set(keepRecents, for: "keepRecents")
            if !keepRecents { recents = [] }
        }
    }
    /// What was typed after `=` for each result pasted or copied, newest
    /// first.
    private(set) var recents: [String] { didSet { defaults.set(recents, for: "recents") } }

    init(defaults: ModuleDefaults) {
        self.defaults = defaults
        digits = defaults.integer("digits") ?? 10
        decimalSeparator = defaults.string("decimalSeparator").flatMap(CalculatorDecimalSeparator.init(rawValue:)) ?? .system
        keepRecents = defaults.bool("keepRecents") ?? true
        recents = defaults.object("recents") as? [String] ?? []
    }

    /// Moves a calculation to the top, or adds it there.
    func addRecent(_ calculation: String) {
        let calculation = calculation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard keepRecents, !calculation.isEmpty else { return }
        recents = [calculation] + recents.filter { $0 != calculation }.prefix(Self.maxRecents - 1)
    }

    func removeRecent(_ calculation: String) {
        recents.removeAll { $0 == calculation }
    }

    func clearRecents() {
        recents = []
    }
}
