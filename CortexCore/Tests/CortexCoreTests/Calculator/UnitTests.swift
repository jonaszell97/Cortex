import Foundation
import Testing
@testable import CortexCore

@Suite struct UnitCatalogTests {
    @Test func idsAreUnique() {
        let ids = UnitCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func everyNameMeansOneUnit() {
        var symbols: [String: String] = [:]
        var words: [String: String] = [:]
        for unit in UnitCatalog.all {
            for symbol in unit.symbols {
                #expect(symbols[symbol] == nil, "\(symbol) is \(symbols[symbol] ?? "") and \(unit.id)")
                symbols[symbol] = unit.id
            }
            for word in unit.words {
                #expect(words[word] == nil, "\(word) is \(words[word] ?? "") and \(unit.id)")
                words[word] = unit.id
            }
        }
    }

    /// Every factor is relative to one base unit per kind.
    @Test func oneBaseUnitPerKind() {
        for kind in CalcUnitKind.allCases {
            let bases = UnitCatalog.all.filter { $0.kind == kind && $0.factor == 1 && $0.offset == 0 }
            #expect(bases.count == 1, "\(kind): \(bases.map(\.id))")
        }
    }

    /// Exact where Foundation rounds.
    @Test func exactFactors() throws {
        let cases: [(String, String, Double)] = [
            ("lb", "kg", 0.45359237), ("gal", "l", 3.785411784), ("fl oz", "ml", 29.5735295625),
            ("cup", "ml", 236.5882365), ("psi", "kPa", 6.894757293168361), ("kn", "km/h", 1.852),
        ]
        for (from, to, value) in cases {
            let result = try CalcQuery.parse("1 \(from) to \(to)").evaluate()
            #expect(abs(result.value - value) <= 1e-12 * value, "\(from): \(result.value)")
        }
    }

    @Test func everyKindHasCommonUnits() {
        for kind in CalcUnitKind.allCases {
            #expect(UnitCatalog.all.filter { $0.kind == kind && $0.isCommon }.count >= 2, "\(kind)")
        }
    }

    @Test func lookup() {
        #expect(UnitCatalog.unit(named: "cm")?.id == "cm")
        #expect(UnitCatalog.unit(named: "Zentimeter")?.id == "cm")
        #expect(UnitCatalog.unit(named: "METRES")?.id == "m")
        #expect(UnitCatalog.unit(named: "MB")?.id == "MB")
        #expect(UnitCatalog.unit(named: "Mb")?.id == "Mbit")
        #expect(UnitCatalog.unit(named: "mb")?.id == "MB")
        #expect(UnitCatalog.unit(named: "C")?.id == "°C")
        #expect(UnitCatalog.unit(named: "c") == nil)
        #expect(UnitCatalog.unit(named: "Pfund") == nil)
    }

    @Test func equivalentsOfFeet() throws {
        let feet = try #require(UnitCatalog.unit(named: "ft"))
        let rows = UnitCatalog.equivalents(of: 5, in: feet)
        #expect(rows.map { $0.unit?.id } == ["m", "cm", "in"])
        #expect(abs(rows[0].value - 1.524) < 1e-12)
        #expect(abs(rows[2].value - 60) < 1e-12)
    }

    @Test func equivalentsOfTemperatures() throws {
        let celsius = try #require(UnitCatalog.unit(named: "°C"))
        let rows = UnitCatalog.equivalents(of: 20, in: celsius)
        #expect(rows.map { $0.unit?.id } == ["°F", "K"])
        #expect(abs(rows[0].value - 68) < 1e-9)
        #expect(abs(rows[1].value - 293.15) < 1e-9)
    }

    @Test func equivalentsOfDataSizes() throws {
        let gigabytes = try #require(UnitCatalog.unit(named: "GB"))
        #expect(UnitCatalog.equivalents(of: 5, in: gigabytes).map { $0.unit?.id } == ["GiB", "MiB", "MB", "kB"])
    }

    @Test func equivalentsOfTinyValues() throws {
        let millimetres = try #require(UnitCatalog.unit(named: "mm"))
        // Nothing reaches 1: the largest value of each system.
        #expect(UnitCatalog.equivalents(of: 0.001, in: millimetres).map { $0.unit?.id } == ["in", "cm"])
    }

    @Test func format() throws {
        #expect(try #require(UnitCatalog.unit(named: "cm")).format("7.62") == "7.62 cm")
        #expect(try #require(UnitCatalog.unit(named: "C")).format("20") == "20 °C")
        #expect(try #require(UnitCatalog.unit(named: "deg")).format("30") == "30°")
    }
}

@Suite struct CalcQueryTests {
    static let conversions: [(String, Double, String)] = [
        ("3 in to cm", 7.62, "cm"),
        ("3 in in cm", 7.62, "cm"),
        ("3in to cm", 7.62, "cm"),
        ("3 in → cm", 7.62, "cm"),
        ("3 in->cm", 7.62, "cm"),
        ("3 inches as centimetres", 7.62, "cm"),
        ("3 m in ft", 3 / 0.3048, "ft"),
        ("3 Metres IN Feet", 3 / 0.3048, "ft"),
        ("(1920/1080) m to ft", (1920.0 / 1080) / 0.3048, "ft"),
        ("1.5e3 m to km", 1.5, "km"),
        ("1 mi to km", 1.609344, "km"),
        ("2 nautical miles to km", 3.704, "km"),
        ("5' to cm", 152.4, "cm"),
        ("1 lb to kg", 0.45359237, "kg"),
        ("100 °C to °F", 212, "°F"),
        ("100°C to F", 212, "°F"),
        ("0 K to °C", -273.15, "°C"),
        ("-40 F to C", -40, "°C"),
        ("1 gal to l", 3.785411784, "l"),
        ("1 ha to m²", 10_000, "m²"),
        ("1 sq ft to cm2", 929.0304, "cm²"),
        ("90 min to h", 1.5, "h"),
        ("1 d to h", 24, "h"),
        ("1 wk in d", 7, "d"),
        ("2 Stunden in Minuten", 120, "min"),
        ("100 km/h to m/s", 100 / 3.6, "m/s"),
        ("1 GiB to MB", 1073.741824, "MB"),
        ("1 KB to B", 1000, "B"),
        ("100 Mb to MB", 12.5, "MB"),
        ("1 kWh to kJ", 3600, "kJ"),
        ("1 atm to hPa", 1013.25, "hPa"),
        ("180° to rad", Double.pi, "rad"),
        ("0x10 m to cm", 1600, "cm"),
        ("3,5 m to cm", 350, "cm"),
    ]

    @Test(arguments: conversions)
    func converts(_ text: String, _ value: Double, _ unit: String) throws {
        let result = try CalcQuery.parse(text, decimalSeparator: ",").evaluate()
        #expect(result.unit?.id == unit)
        #expect(abs(result.value - value) <= 1e-9 * max(1, abs(value)), "\(result.value)")
    }

    static let quantities: [(String, Double, String)] = [
        ("5 ft", 5, "ft"),
        ("3 in", 3, "in"),
        ("3in", 3, "in"),
        ("20°C", 20, "°C"),
        ("30°", 30, "°"),
        ("2 * 3 h", 6, "h"),
        ("0x1 F", 1, "°F"),
        ("1 min", 1, "min"),
        ("12 sq ft", 12, "ft²"),
        ("5 Meter", 5, "m"),
    ]

    @Test(arguments: quantities)
    func quantity(_ text: String, _ value: Double, _ unit: String) throws {
        let query = try CalcQuery.parse(text)
        #expect(query.target == nil)
        let result = try query.evaluate()
        #expect(result.unit?.id == unit)
        #expect(result.value == value)
    }

    static let calculations: [(String, Double)] = [
        ("1920/1080", 1920.0 / 1080.0),
        ("2 * pi", 2 * Double.pi),
        ("e", M_E),
        ("0x1F", 31),
        ("0xFF", 255),
        ("0xB", 11),
        ("0x1d", 29),
        ("50%", 0.5),
        ("sin(30°)", sin(30 * Double.pi / 180)),
        ("cos(180°)", -1),
        ("sqrt(16)", 4),
    ]

    @Test(arguments: calculations)
    func calculation(_ text: String, _ value: Double) throws {
        let query = try CalcQuery.parse(text)
        #expect(query.unit == nil)
        #expect(try query.evaluate() == CalcResult(value: value, unit: nil))
    }

    static let errors: [(String, CalcError)] = [
        ("3 kg to cm", .incompatibleUnits(.mass, .length)),
        ("5 ft to flurbs", .unknownUnit("flurbs")),
        ("3 flurbs", .unknownUnit("flurbs")),
        ("3 m to 4", .unknownUnit("4")),
        ("1/0 m to cm", .divisionByZero),
        ("3 + * 2", .unexpected("×")),
        ("foo + 1", .unknownName("foo")),
    ]

    @Test(arguments: errors)
    func fails(_ text: String, _ error: CalcError) {
        #expect(throws: error) { try CalcQuery.parse(text).evaluate() }
    }

    /// No float noise from going through the base unit.
    @Test func conversionsAreClean() throws {
        #expect(try CalcQuery.parse("3 in to cm").evaluate().value == 7.62)
        #expect(try CalcQuery.parse("1 m to ft").evaluate().value == 3.28083989501312)
        let feet = try #require(UnitCatalog.unit(named: "ft"))
        #expect(UnitCatalog.equivalents(of: 5, in: feet).map(\.value) == [1.524, 152.4, 60])
    }

    @Test func incompatibleUnitsMessage() {
        #expect(CalcError.incompatibleUnits(.mass, .length).message == "Can't convert mass to length")
        #expect(CalcError.incompatibleUnits(.dataSize, .duration).message == "Can't convert data size to duration")
    }

    /// Typed on the way to a unit or a conversion.
    static let unfinished = ["3 m to", "3 m in", "3 m as ", "3 m →", "3 m to c", "3 m to Zenti", "3 c", "3 ki", "5 ft to ki", "3 +", ""]

    @Test(arguments: unfinished)
    func unfinishedInput(_ text: String) {
        #expect(throws: CalcError.unfinished) { try CalcQuery.parse(text) }
    }

    static let texts: [(String, String)] = [
        ("1920/1080", "1920 ÷ 1080"),
        ("5 ft", "5 feet"),
        ("1 ft", "1 foot"),
        ("3 in to cm", "3 inches → centimetres"),
        ("1 m to cm", "1 metre → centimetres"),
        ("(1920/1080) m", "(1920 ÷ 1080) metres"),
        ("pi m", "π metres"),
        ("20°C", "20 degrees Celsius"),
        ("100 km/h in mph", "100 kilometres per hour → miles per hour"),
    ]

    @Test(arguments: texts)
    func text(_ input: String, _ text: String) throws {
        #expect(try CalcQuery.parse(input).text == text)
    }
}
