import Foundation
import Testing
@testable import CortexCore

@Suite struct CalcLexerTests {
    static let numbers: [(String, Double)] = [
        ("42", 42),
        ("3.5", 3.5),
        (".5", 0.5),
        ("1.", 1),
        ("1e6", 1_000_000),
        ("1E6", 1_000_000),
        ("2.5e-3", 0.0025),
        ("2.5e+3", 2500),
        ("2.5e−3", 0.0025),
        ("0x1F", 31),
        ("0XFF", 255),
        ("0b101", 5),
        ("0xFF_FF", 65535),
        ("1_000_000", 1_000_000),
        ("1 000 000", 1_000_000),
        ("1 000.25", 1000.25),
        ("007", 7),
    ]

    @Test(arguments: numbers)
    func number(_ text: String, _ value: Double) throws {
        #expect(try CalcLexer.tokens(text) == [.number(value)])
    }

    @Test func operators() throws {
        #expect(try CalcLexer.tokens("+ - − * × · / ÷ ^ ** % ( )") == [
            .plus, .minus, .minus, .times, .times, .times, .divide, .divide,
            .power, .power, .percent, .openParenthesis, .closeParenthesis,
        ])
    }

    @Test func names() throws {
        #expect(try CalcLexer.tokens("sqrt(2) π") == [
            .identifier("sqrt"), .openParenthesis, .number(2), .closeParenthesis, .identifier("π"),
        ])
    }

    @Test func spacesOnlyJoinDigits() throws {
        #expect(try CalcLexer.tokens("1 + 2") == [.number(1), .plus, .number(2)])
        #expect(try CalcLexer.tokens("3 pi") == [.number(3), .identifier("pi")])
    }

    @Test func decimalComma() throws {
        #expect(try CalcLexer.tokens("3,5", decimalSeparator: ",") == [.number(3.5)])
        #expect(try CalcLexer.tokens("3.5", decimalSeparator: ",") == [.number(3.5)])
        #expect(try CalcLexer.tokens("1 000,5", decimalSeparator: ",") == [.number(1000.5)])
        #expect(try CalcLexer.tokens(",5", decimalSeparator: ",") == [.number(0.5)])
        #expect(throws: CalcError.unexpected(",")) { try CalcLexer.tokens("1,000") }
    }

    @Test func errors() {
        #expect(throws: CalcError.unexpected(".")) { try CalcLexer.tokens("1.2.3") }
        #expect(throws: CalcError.unexpected(",")) { try CalcLexer.tokens("1.2,3", decimalSeparator: ",") }
        #expect(throws: CalcError.unexpected("2")) { try CalcLexer.tokens("0b102") }
        #expect(throws: CalcError.unexpected("g")) { try CalcLexer.tokens("0x1g") }
        #expect(throws: CalcError.unexpected("$")) { try CalcLexer.tokens("3 $") }
        #expect(throws: CalcError.overflow) { try CalcLexer.tokens("1e400") }
        #expect(throws: CalcError.overflow) { try CalcLexer.tokens("0x1_0000_0000_0000_0000") }
    }

    @Test func unfinishedNumbers() {
        #expect(throws: CalcError.unfinished) { try CalcLexer.tokens("1e") }
        #expect(throws: CalcError.unfinished) { try CalcLexer.tokens("1e-") }
        #expect(throws: CalcError.unfinished) { try CalcLexer.tokens("0x") }
        #expect(throws: CalcError.unfinished) { try CalcLexer.tokens("0b") }
    }
}

@Suite struct CalcEvaluatorTests {
    static let results: [(String, Double)] = [
        ("1920/1080", 1920.0 / 1080.0),
        ("1 + 2 * 3", 7),
        ("(1 + 2) * 3", 9),
        ("10 - 4 - 3", 3),
        ("100 / 10 / 5", 2),
        ("2^3^2", 512),
        ("2**10", 1024),
        ("-2^2", -4),
        ("(-2)^2", 4),
        ("2^-1", 0.5),
        ("-3 * -3", 9),
        ("--3", 3),
        ("+3", 3),
        ("50%", 0.5),
        ("200 * 15%", 30),
        ("10%%", 0.001),
        ("3 × 4 ÷ 2", 6),
        ("6 − 8", -2),
        ("(1 + 2", 3),
        ("((2", 2),
        ("2 * (3 + (4", 14),
        ("sqrt(16)", 4),
        ("SQRT(16)", 4),
        ("sqrt(16", 4),
        ("abs(-3)", 3),
        ("round(2.5)", 3),
        ("round(-2.5)", -3),
        ("floor(-2.5)", -3),
        ("ceil(2.1)", 3),
        ("ln(e)", 1),
        ("log(1000)", 3),
        ("pi", Double.pi),
        ("PI", Double.pi),
        ("π", Double.pi),
        ("2 * pi", 2 * Double.pi),
        ("e", M_E),
        ("0.1 + 0.2", 0.1 + 0.2),
        ("0xFF + 1", 256),
        ("3 4", 34),
    ]

    @Test(arguments: results)
    func evaluates(_ text: String, _ value: Double) throws {
        #expect(try CalcEvaluator.evaluate(text) == value)
    }

    @Test func trigonometryIsExactAtQuarterTurns() throws {
        #expect(try CalcEvaluator.evaluate("sin(pi)") == 0)
        #expect(try CalcEvaluator.evaluate("sin(-pi/2)") == -1)
        #expect(try CalcEvaluator.evaluate("cos(pi/2)") == 0)
        #expect(try CalcEvaluator.evaluate("cos(3*pi)") == -1)
        #expect(try CalcEvaluator.evaluate("tan(pi)") == 0)
        #expect(try CalcEvaluator.evaluate("sin(1e-12)") == 1e-12)
        #expect(try CalcEvaluator.evaluate("sin(1)") == sin(1))
        #expect(throws: CalcError.undefined) { try CalcEvaluator.evaluate("tan(pi/2)") }
    }

    @Test func decimalComma() throws {
        #expect(try CalcEvaluator.evaluate("3,5 * 2", decimalSeparator: ",") == 7)
    }

    static let errors: [(String, CalcError)] = [
        ("1/0", .divisionByZero),
        ("0/0", .divisionByZero),
        ("0^-1", .divisionByZero),
        ("10^400", .overflow),
        ("1e300 * 1e300", .overflow),
        ("sqrt(-1)", .undefined),
        ("ln(0)", .undefined),
        ("log(-1)", .undefined),
        ("(-8)^(1/3)", .undefined),
        ("3 + * 2", .unexpected("×")),
        ("3)", .unexpected(")")),
        (")", .unexpected(")")),
        ("2pi", .unexpected("pi")),
        ("(2 pi)", .unexpected("pi")),
        ("foo", .unknownName("foo")),
        ("foo + 1", .unknownName("foo")),
        ("sq + 1", .unknownName("sq")),
        ("sqrt 4", .needsParentheses("sqrt")),
        ("sqrt + 4", .needsParentheses("sqrt")),
        (String(repeating: "(", count: 101) + "1", .tooDeep),
        (String(repeating: "-", count: 101) + "1", .tooDeep),
    ]

    @Test(arguments: errors)
    func fails(_ text: String, _ error: CalcError) {
        #expect(throws: error) { try CalcEvaluator.evaluate(text) }
    }

    /// Input that may still become valid as it is typed.
    static let unfinishedInputs = ["", "  ", "3 +", "3 *", "-", "(", "2 * (", "sqrt(", "sqrt", "sq", "p", "2^", "1e", "1 + 1e-"]

    @Test(arguments: unfinishedInputs)
    func unfinished(_ text: String) {
        #expect(throws: CalcError.unfinished) { try CalcEvaluator.evaluate(text) }
    }

    @Test func nestingWithinTheLimit() throws {
        let text = String(repeating: "(", count: 50) + "1" + String(repeating: ")", count: 50)
        #expect(try CalcEvaluator.evaluate(text) == 1)
    }
}

@Suite struct CalcExpressionTextTests {
    static let texts: [(String, String)] = [
        ("1920/1080", "1920 ÷ 1080"),
        ("1+2*3", "1 + 2 × 3"),
        ("(1+2)*3", "(1 + 2) × 3"),
        ("1-(2-3)", "1 − (2 − 3)"),
        ("(1-2)-3", "1 − 2 − 3"),
        ("8/(4/2)", "8 ÷ (4 ÷ 2)"),
        ("2^3^2", "2^3^2"),
        ("(2^3)^2", "(2^3)^2"),
        ("-2^2", "−2^2"),
        ("(-2)^2", "(−2)^2"),
        ("2^-1", "2^(−1)"),
        ("-(1+2)", "−(1 + 2)"),
        ("--3", "−(−3)"),
        ("-2*3", "−2 × 3"),
        ("50%", "50%"),
        ("(1+2)%", "(1 + 2)%"),
        ("sqrt(2)*pi", "sqrt(2) × π"),
        ("SQRT(1+1)", "sqrt(1 + 1)"),
        ("(1+2", "1 + 2"),
        ("1.5e3", "1500"),
        ("0.25", "0.25"),
    ]

    @Test(arguments: texts)
    func text(_ input: String, _ text: String) throws {
        #expect(try CalcParser.parse(input).text == text)
    }
}

@Suite struct CalcFormatterTests {
    let english = Locale(identifier: "en_US")
    let german = Locale(identifier: "de_DE")

    @Test func display() {
        #expect(CalcFormatter.display(1920.0 / 1080.0, locale: english) == "1.777777778")
        #expect(CalcFormatter.display(0.1 + 0.2, locale: english) == "0.3")
        #expect(CalcFormatter.display(2_073_600, locale: english) == "2,073,600")
        #expect(CalcFormatter.display(-42, locale: english) == "-42")
        #expect(CalcFormatter.display(0.000001, locale: english) == "0.000001")
        #expect(CalcFormatter.display(123_456_789_012_345, locale: english) == "123,456,789,000,000")
    }

    @Test func displayInGerman() {
        #expect(CalcFormatter.display(1920.0 / 1080.0, locale: german) == "1,777777778")
        #expect(CalcFormatter.display(2_073_600.5, locale: german) == "2.073.600,5")
        #expect(CalcFormatter.display(1.5e20, locale: german) == "1,5e20")
    }

    @Test func scientific() {
        #expect(CalcFormatter.display(1e15, locale: english) == "1e15")
        #expect(CalcFormatter.display(1.5e20, locale: english) == "1.5e20")
        #expect(CalcFormatter.display(-2.5e-9, locale: english) == "-2.5e-9")
        #expect(CalcFormatter.display(1.7976931348623157e308, locale: english) == "1.797693135e308")
    }

    @Test func roundingCarries() {
        #expect(CalcFormatter.display(9.99999999999, locale: english) == "10")
        #expect(CalcFormatter.display(999_999_999_999_999.9, locale: english) == "1e15")
    }

    @Test func digits() {
        #expect(CalcFormatter.display(Double.pi, digits: 3, locale: english) == "3.14")
        #expect(CalcFormatter.display(Double.pi, digits: 0, locale: english) == "3")
        #expect(CalcFormatter.display(Double.pi, digits: 40, locale: english) == "3.14159265358979")
    }

    @Test func zero() {
        #expect(CalcFormatter.display(0, locale: english) == "0")
        #expect(CalcFormatter.display(-0.0, locale: english) == "0")
        #expect(CalcFormatter.display(1e-20, digits: 10, locale: english) == "1e-20")
        #expect(CalcFormatter.plain(-0.0) == "0")
    }

    @Test func plain() {
        #expect(CalcFormatter.plain(1920.0 / 1080.0) == "1.7777777777777777")
        #expect(CalcFormatter.plain(2_073_600) == "2073600")
        #expect(CalcFormatter.plain(0.1 + 0.2) == "0.30000000000000004")
        #expect(CalcFormatter.plain(-0.5) == "-0.5")
        #expect(CalcFormatter.plain(1e20) == "1e+20")
    }
}
