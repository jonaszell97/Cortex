import Foundation

/// A unit the calculator converts: a factor to its kind's base unit, with
/// the names it is typed as and shown with.
public struct CalcUnit: Hashable, Sendable {
    /// Unique in the catalog: `cm`, `fl oz`, `°C`.
    public let id: String
    public let kind: CalcUnitKind
    public let system: CalcUnitSystem
    /// How a value is written with it: `cm`, `°C`, `°`.
    public let symbol: String
    /// For the pane: `3 inches → centimetres`.
    public let name: String
    public let plural: String
    /// Listed among the equivalents of a value (`=5 ft`).
    public let isCommon: Bool
    /// Typed exactly as written: `m`, `MB`, `°C`.
    let symbols: [String]
    /// Typed in any case, lowercased: `metre`, `meters`, `zentimeter`.
    let words: [String]
    /// A value in the base unit is `value × factor + offset`.
    let factor: Double
    /// Only temperatures have one: 273.15 for Celsius.
    let offset: Double

    init(_ id: String, _ kind: CalcUnitKind, _ system: CalcUnitSystem, _ factor: Double, offset: Double = 0,
         symbols: [String], name: String, plural: String? = nil, words: [String] = [], common: Bool = true) {
        self.id = id
        self.kind = kind
        self.system = system
        self.factor = factor
        self.offset = offset
        self.symbols = symbols
        symbol = symbols[0]
        self.name = name
        let plural = plural ?? name + "s"
        self.plural = plural
        var seen = Set<String>()
        self.words = ([name, plural] + words).map { $0.lowercased() }.filter { seen.insert($0).inserted }
        isCommon = common
    }

    /// `7.62 cm`, `20 °C`, but `30°` for the angle.
    public func format(_ number: String) -> String {
        symbol == "°" ? number + symbol : number + " " + symbol
    }

    /// The value in the base unit of its kind (metres, kelvin, …).
    func baseValue(_ value: Double) -> Double {
        value * factor + offset
    }

    func value(fromBase base: Double) -> Double {
        (base - offset) / factor
    }

    /// `value` in this unit, in `other`. Rounded to 15 significant digits,
    /// so going through the base unit leaves no trace: `3 in` is 7.62 cm,
    /// not 7.619999999999999.
    public func convert(_ value: Double, to other: CalcUnit) -> Double {
        CalcFormatter.rounded(other.value(fromBase: baseValue(value)), digits: 15)
    }

    public static func == (lhs: CalcUnit, rhs: CalcUnit) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// What a unit measures; only units of the same kind convert.
public enum CalcUnitKind: String, CaseIterable, Sendable {
    case length, mass, volume, area, temperature, duration, speed
    case dataSize = "data size"
    case energy, pressure, angle
}

/// Which family a unit belongs to, so `=5 ft` lists metric units first.
public enum CalcUnitSystem: Sendable {
    case metric, imperial
    /// IEC data sizes: KiB, MiB, …
    case binary
    /// Neither: hours, joules, radians.
    case other
}
