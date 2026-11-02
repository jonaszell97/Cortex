import Foundation

/// The units the calculator knows, by the names they are typed as, in
/// English and German. Symbols are case-sensitive (`MB` megabytes, `Mb`
/// megabits, `C` Celsius); words are not (`Meter`, `metres`, `zoll`).
///
/// Not listed on purpose: `Pfund` (500 g in German use, not the 453.6 g of
/// `lb`), `grad` (degrees in German, gradians in English), US and imperial
/// variants of the same name (`gal`, `pt`, `cup` are US customary).
public enum UnitCatalog {
    public static let all: [CalcUnit] = length + mass + volume + area + temperature
        + duration + speed + dataSize + energy + pressure + angle

    /// A unit by its whole name: a symbol as written, else a word in any case.
    public static func unit(named name: String) -> CalcUnit? {
        bySymbol[name] ?? byWord[name.lowercased()]
    }

    /// The unit `text` ends with, and the text before it (trimmed): `3 in`,
    /// `20°C`, `(1920/1080) m`. The longest name wins (`km/h`, not `h`), and a
    /// name starting with a letter must not follow one (`3 xm` is no metre).
    static func suffix(of text: Substring) -> (unit: CalcUnit, rest: Substring)? {
        for (name, unit, exact) in suffixNames where text.count > name.count {
            let tail = text.suffix(name.count)
            guard exact ? tail == name : tail.lowercased() == name else { continue }
            let rest = text.dropLast(name.count)
            if name.first!.isLetter, rest.last!.isLetter { continue }
            // `0x1F` is a number, not 1 °F.
            if name.allSatisfy(\.isHexDigit), rest.contains(hexLiteralEnd) { continue }
            let trimmed = rest.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            return (unit, Substring(trimmed))
        }
        return nil
    }

    private nonisolated(unsafe) static let hexLiteralEnd = #/0[xX][0-9a-fA-F_]*$/#

    /// Whether some unit's name starts with `text`, in any case: `c` may
    /// become `cm`, so it is unfinished rather than unknown.
    static func isPrefix(_ text: Substring) -> Bool {
        let lowered = text.lowercased()
        return lowercasedNames.contains { $0.hasPrefix(lowered) }
    }

    /// Other ways to write a value, for `=5 ft`: up to two units of each
    /// other system, then up to two of its own, each the largest units in
    /// which the value is still at least 1 (`1.524 m`, `152.4 cm`, `60 in`).
    /// Only common units. Temperatures list every other scale.
    public static func equivalents(of value: Double, in unit: CalcUnit) -> [CalcResult] {
        let candidates = all
            .filter { $0.kind == unit.kind && $0.isCommon && $0 != unit }
            .map { CalcResult(value: unit.convert(value, to: $0), unit: $0) }
            .filter { $0.value.isFinite }
        if unit.kind == .temperature { return candidates }

        let systems = [CalcUnitSystem.metric, .imperial, .binary, .other]
        let order = systems.filter { $0 != unit.system } + [unit.system]
        return order.flatMap { system in
            let members = candidates.filter { $0.unit?.system == system }
            let readable = members.filter { Swift.abs($0.value) >= 1 }.sorted { Swift.abs($0.value) < Swift.abs($1.value) }
            if !readable.isEmpty { return Array(readable.prefix(2)) }
            return Array(members.max { Swift.abs($0.value) < Swift.abs($1.value) }.map { [$0] } ?? [])
        }
    }

    // MARK: - Lookup tables

    private static let bySymbol: [String: CalcUnit] = Dictionary(
        all.flatMap { unit in unit.symbols.map { ($0, unit) } }, uniquingKeysWith: { first, _ in first })

    private static let byWord: [String: CalcUnit] = Dictionary(
        all.flatMap { unit in unit.words.map { ($0, unit) } }, uniquingKeysWith: { first, _ in first })

    /// Longest first, symbols before words of the same length.
    private static let suffixNames: [(name: String, unit: CalcUnit, exact: Bool)] = all
        .flatMap { unit in unit.symbols.map { ($0, unit, true) } + unit.words.map { ($0, unit, false) } }
        .sorted { $0.0.count != $1.0.count ? $0.0.count > $1.0.count : $0.2 && !$1.2 }

    private static let lowercasedNames = Set(all.flatMap { $0.symbols.map { $0.lowercased() } + $0.words })

    // MARK: - Units

    /// Each unit is its kind's base unit times a factor (plus an offset for
    /// temperatures): metres, kilograms, litres, square metres, kelvin,
    /// seconds, metres per second, bytes, joules, pascals, degrees. The
    /// factors are exact by definition; Foundation's are rounded to about six
    /// digits (`lb` 0.453592, `gal` 3.78541, `km/h` 0.277778), which shows at
    /// ten.

    /// The US liquid gallon, 231 cubic inches; the smaller US measures are
    /// fractions of it.
    private static let usGallon = 3.785411784

    private static let length: [CalcUnit] = [
        CalcUnit("mm", .length, .metric, 0.001, symbols: ["mm"], name: "millimetre", words: ["millimeter", "millimeters"]),
        CalcUnit("cm", .length, .metric, 0.01, symbols: ["cm"], name: "centimetre", words: ["centimeter", "centimeters", "zentimeter"]),
        CalcUnit("m", .length, .metric, 1, symbols: ["m"], name: "metre", words: ["meter", "meters"]),
        CalcUnit("km", .length, .metric, 1_000, symbols: ["km"], name: "kilometre", words: ["kilometer", "kilometers"]),
        CalcUnit("µm", .length, .metric, 1e-6, symbols: ["µm", "μm", "um"], name: "micrometre", words: ["micrometer", "micrometers", "mikrometer"], common: false),
        CalcUnit("nm", .length, .metric, 1e-9, symbols: ["nm"], name: "nanometre", words: ["nanometer", "nanometers"], common: false),
        CalcUnit("in", .length, .imperial, 0.0254, symbols: ["in", "\"", "″"], name: "inch", plural: "inches", words: ["zoll"]),
        CalcUnit("ft", .length, .imperial, 0.3048, symbols: ["ft", "'", "′"], name: "foot", plural: "feet", words: ["fuß", "fuss"]),
        CalcUnit("yd", .length, .imperial, 0.9144, symbols: ["yd"], name: "yard", common: false),
        CalcUnit("mi", .length, .imperial, 1_609.344, symbols: ["mi"], name: "mile", words: ["meile", "meilen"]),
        CalcUnit("nmi", .length, .other, 1_852, symbols: ["nmi"], name: "nautical mile", words: ["seemeile", "seemeilen"], common: false),
    ]

    private static let mass: [CalcUnit] = [
        CalcUnit("µg", .mass, .metric, 1e-9, symbols: ["µg", "μg", "ug"], name: "microgram", words: ["mikrogramm"], common: false),
        CalcUnit("mg", .mass, .metric, 1e-6, symbols: ["mg"], name: "milligram", words: ["milligramm"]),
        CalcUnit("g", .mass, .metric, 0.001, symbols: ["g"], name: "gram", words: ["gramm", "gramme", "grammes"]),
        CalcUnit("kg", .mass, .metric, 1, symbols: ["kg"], name: "kilogram", words: ["kilogramm", "kilo", "kilos"]),
        CalcUnit("t", .mass, .metric, 1_000, symbols: ["t"], name: "tonne", words: ["tonnen", "metric ton", "metric tons"]),
        CalcUnit("oz", .mass, .imperial, 0.028349523125, symbols: ["oz"], name: "ounce", words: ["unze", "unzen"]),
        CalcUnit("lb", .mass, .imperial, 0.45359237, symbols: ["lb", "lbs"], name: "pound"),
        CalcUnit("st", .mass, .imperial, 6.35029318, symbols: ["st"], name: "stone", plural: "stone", words: ["stones"], common: false),
    ]

    private static let volume: [CalcUnit] = [
        CalcUnit("ml", .volume, .metric, 0.001, symbols: ["ml", "mL"], name: "millilitre", words: ["milliliter", "milliliters"]),
        CalcUnit("cl", .volume, .metric, 0.01, symbols: ["cl", "cL"], name: "centilitre", words: ["centiliter", "centiliters", "zentiliter"], common: false),
        CalcUnit("dl", .volume, .metric, 0.1, symbols: ["dl", "dL"], name: "decilitre", words: ["deciliter", "deciliters", "deziliter"], common: false),
        CalcUnit("l", .volume, .metric, 1, symbols: ["l", "L", "ℓ"], name: "litre", words: ["liter", "liters"]),
        CalcUnit("m³", .volume, .metric, 1_000, symbols: ["m³", "m3"], name: "cubic metre", words: ["cubic meter", "cubic meters", "kubikmeter"], common: false),
        CalcUnit("tsp", .volume, .imperial, usGallon / 768, symbols: ["tsp"], name: "teaspoon", common: false),
        CalcUnit("tbsp", .volume, .imperial, usGallon / 256, symbols: ["tbsp"], name: "tablespoon", common: false),
        CalcUnit("fl oz", .volume, .imperial, usGallon / 128, symbols: ["fl oz", "floz"], name: "fluid ounce"),
        CalcUnit("cup", .volume, .imperial, usGallon / 16, symbols: ["cup", "cups"], name: "cup"),
        CalcUnit("pt", .volume, .imperial, usGallon / 8, symbols: ["pt"], name: "pint", common: false),
        CalcUnit("qt", .volume, .imperial, usGallon / 4, symbols: ["qt"], name: "quart", common: false),
        CalcUnit("gal", .volume, .imperial, usGallon, symbols: ["gal"], name: "gallon"),
    ]

    private static let area: [CalcUnit] = [
        CalcUnit("mm²", .area, .metric, 1e-6, symbols: ["mm²", "mm2"], name: "square millimetre", words: ["square millimeter", "square millimeters", "quadratmillimeter"], common: false),
        CalcUnit("cm²", .area, .metric, 1e-4, symbols: ["cm²", "cm2"], name: "square centimetre", words: ["square centimeter", "square centimeters", "quadratzentimeter"]),
        CalcUnit("m²", .area, .metric, 1, symbols: ["m²", "m2", "sqm"], name: "square metre", words: ["square meter", "square meters", "quadratmeter"]),
        CalcUnit("ha", .area, .metric, 10_000, symbols: ["ha"], name: "hectare", words: ["hektar"]),
        CalcUnit("km²", .area, .metric, 1e6, symbols: ["km²", "km2"], name: "square kilometre", words: ["square kilometer", "square kilometers", "quadratkilometer"]),
        CalcUnit("in²", .area, .imperial, 0.00064516, symbols: ["in²", "in2", "sq in"], name: "square inch", plural: "square inches", common: false),
        CalcUnit("ft²", .area, .imperial, 0.09290304, symbols: ["ft²", "ft2", "sq ft", "sqft"], name: "square foot", plural: "square feet"),
        CalcUnit("yd²", .area, .imperial, 0.83612736, symbols: ["yd²", "yd2", "sq yd"], name: "square yard", common: false),
        CalcUnit("ac", .area, .imperial, 4_046.8564224, symbols: ["ac"], name: "acre"),
        CalcUnit("mi²", .area, .imperial, 2_589_988.110336, symbols: ["mi²", "mi2", "sq mi"], name: "square mile"),
    ]

    private static let temperature: [CalcUnit] = [
        CalcUnit("°C", .temperature, .metric, 1, offset: 273.15, symbols: ["°C", "C", "℃"], name: "degree Celsius", plural: "degrees Celsius", words: ["celsius"]),
        CalcUnit("°F", .temperature, .imperial, 5.0 / 9, offset: 273.15 - 160.0 / 9, symbols: ["°F", "F", "℉"], name: "degree Fahrenheit", plural: "degrees Fahrenheit", words: ["fahrenheit"]),
        CalcUnit("K", .temperature, .metric, 1, symbols: ["K"], name: "kelvin", plural: "kelvin"),
    ]

    private static let duration: [CalcUnit] = [
        CalcUnit("ns", .duration, .other, 1e-9, symbols: ["ns"], name: "nanosecond", words: ["nanosekunde", "nanosekunden"], common: false),
        CalcUnit("µs", .duration, .other, 1e-6, symbols: ["µs", "μs", "us"], name: "microsecond", words: ["mikrosekunde", "mikrosekunden"], common: false),
        CalcUnit("ms", .duration, .other, 0.001, symbols: ["ms"], name: "millisecond", words: ["millisekunde", "millisekunden"]),
        CalcUnit("s", .duration, .other, 1, symbols: ["s"], name: "second", words: ["sec", "secs", "sekunde", "sekunden"]),
        CalcUnit("min", .duration, .other, 60, symbols: ["min"], name: "minute", words: ["mins", "minuten"]),
        CalcUnit("h", .duration, .other, 3_600, symbols: ["h"], name: "hour", words: ["hr", "hrs", "stunde", "stunden"]),
        CalcUnit("d", .duration, .other, 86_400, symbols: ["d"], name: "day", words: ["tag", "tage", "tagen"]),
        CalcUnit("wk", .duration, .other, 604_800, symbols: ["wk"], name: "week", words: ["woche", "wochen"]),
    ]

    private static let speed: [CalcUnit] = [
        CalcUnit("m/s", .speed, .metric, 1, symbols: ["m/s"], name: "metre per second", plural: "metres per second", words: ["meter per second", "meters per second"]),
        CalcUnit("km/h", .speed, .metric, 1 / 3.6, symbols: ["km/h", "kmh", "kph"], name: "kilometre per hour", plural: "kilometres per hour", words: ["kilometer per hour", "kilometers per hour"]),
        CalcUnit("mph", .speed, .imperial, 0.44704, symbols: ["mph"], name: "mile per hour", plural: "miles per hour"),
        CalcUnit("kn", .speed, .other, 1_852.0 / 3_600, symbols: ["kn", "kt"], name: "knot", words: ["knoten"], common: false),
    ]

    private static let dataSize: [CalcUnit] = [
        CalcUnit("bit", .dataSize, .metric, 0.125, symbols: ["bit"], name: "bit", common: false),
        CalcUnit("kbit", .dataSize, .metric, 125, symbols: ["kbit"], name: "kilobit", common: false),
        CalcUnit("Mbit", .dataSize, .metric, 125e3, symbols: ["Mbit", "Mb"], name: "megabit", common: false),
        CalcUnit("Gbit", .dataSize, .metric, 125e6, symbols: ["Gbit", "Gb"], name: "gigabit", common: false),
        CalcUnit("B", .dataSize, .metric, 1, symbols: ["B"], name: "byte"),
        CalcUnit("kB", .dataSize, .metric, 1e3, symbols: ["kB", "KB"], name: "kilobyte", words: ["kb"]),
        CalcUnit("MB", .dataSize, .metric, 1e6, symbols: ["MB"], name: "megabyte", words: ["mb"]),
        CalcUnit("GB", .dataSize, .metric, 1e9, symbols: ["GB"], name: "gigabyte", words: ["gb"]),
        CalcUnit("TB", .dataSize, .metric, 1e12, symbols: ["TB"], name: "terabyte", words: ["tb"]),
        CalcUnit("PB", .dataSize, .metric, 1e15, symbols: ["PB"], name: "petabyte", words: ["pb"], common: false),
        CalcUnit("KiB", .dataSize, .binary, 1_024, symbols: ["KiB"], name: "kibibyte", words: ["kib"]),
        CalcUnit("MiB", .dataSize, .binary, 1_048_576, symbols: ["MiB"], name: "mebibyte", words: ["mib"]),
        CalcUnit("GiB", .dataSize, .binary, 1_073_741_824, symbols: ["GiB"], name: "gibibyte", words: ["gib"]),
        CalcUnit("TiB", .dataSize, .binary, 1_099_511_627_776, symbols: ["TiB"], name: "tebibyte", words: ["tib"]),
    ]

    private static let energy: [CalcUnit] = [
        CalcUnit("J", .energy, .other, 1, symbols: ["J"], name: "joule"),
        CalcUnit("kJ", .energy, .other, 1_000, symbols: ["kJ"], name: "kilojoule"),
        CalcUnit("cal", .energy, .other, 4.184, symbols: ["cal"], name: "calorie", common: false),
        CalcUnit("kcal", .energy, .other, 4_184, symbols: ["kcal"], name: "kilocalorie", words: ["kalorie", "kalorien", "kilokalorie", "kilokalorien"]),
        CalcUnit("Wh", .energy, .other, 3_600, symbols: ["Wh"], name: "watt-hour", common: false),
        CalcUnit("kWh", .energy, .other, 3.6e6, symbols: ["kWh"], name: "kilowatt-hour"),
    ]

    private static let pressure: [CalcUnit] = [
        CalcUnit("Pa", .pressure, .metric, 1, symbols: ["Pa"], name: "pascal", common: false),
        CalcUnit("hPa", .pressure, .metric, 100, symbols: ["hPa"], name: "hectopascal", words: ["hektopascal"]),
        CalcUnit("kPa", .pressure, .metric, 1_000, symbols: ["kPa"], name: "kilopascal"),
        CalcUnit("bar", .pressure, .metric, 100_000, symbols: ["bar"], name: "bar", words: ["bars"]),
        CalcUnit("mbar", .pressure, .metric, 100, symbols: ["mbar"], name: "millibar", common: false),
        CalcUnit("atm", .pressure, .other, 101_325, symbols: ["atm"], name: "atmosphere"),
        CalcUnit("psi", .pressure, .imperial, 0.45359237 * 9.80665 / 0.00064516, symbols: ["psi"], name: "psi", plural: "psi"),
        CalcUnit("mmHg", .pressure, .other, 133.322387415, symbols: ["mmHg"], name: "millimetre of mercury", plural: "millimetres of mercury", common: false),
        CalcUnit("inHg", .pressure, .imperial, 3_386.389, symbols: ["inHg"], name: "inch of mercury", plural: "inches of mercury", common: false),
    ]

    private static let angle: [CalcUnit] = [
        CalcUnit("°", .angle, .other, 1, symbols: ["°", "deg"], name: "degree"),
        CalcUnit("rad", .angle, .other, 180 / Double.pi, symbols: ["rad"], name: "radian"),
        CalcUnit("turn", .angle, .other, 360, symbols: ["turn"], name: "turn", words: ["revolution", "revolutions", "rev", "umdrehung", "umdrehungen"]),
        CalcUnit("gon", .angle, .other, 0.9, symbols: ["gon"], name: "gradian", words: ["gradians"], common: false),
    ]
}
