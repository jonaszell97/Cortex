import Foundation

public enum CalcToken: Equatable, Sendable {
    case number(Double)
    case identifier(String)
    case plus, minus, times, divide, power, percent, degree
    case openParenthesis, closeParenthesis

    /// How the token was written, near enough for an error message.
    var text: String {
        switch self {
        case .number(let value): CalcFormatter.plain(value)
        case .identifier(let name): name
        case .plus: "+"
        case .minus: "−"
        case .times: "×"
        case .divide: "÷"
        case .power: "^"
        case .percent: "%"
        case .degree: "°"
        case .openParenthesis: "("
        case .closeParenthesis: ")"
        }
    }
}

/// Splits a calculation into tokens.
///
/// Numbers: `42`, `3.5`, `.5`, `1e6`, `0x1F`, `0b101`. `.` is always a
/// decimal point; `decimalSeparator` (the system's, `,` in German) is
/// accepted as one too. There are no grouping separators: `_` and spaces
/// between digits are ignored (`1_000_000`, `1 000`), so `1,000` is 1 where
/// the decimal separator is `,` and unexpected elsewhere.
public enum CalcLexer {
    public static func tokens(_ text: String, decimalSeparator: Character = ".") throws(CalcError) -> [CalcToken] {
        var scanner = Scanner(Array(text), decimalSeparator: decimalSeparator)
        return try scanner.tokens()
    }

    private struct Scanner {
        let characters: [Character]
        let decimalSeparators: Set<Character>
        var index = 0

        init(_ characters: [Character], decimalSeparator: Character) {
            self.characters = characters
            decimalSeparators = [".", decimalSeparator]
        }

        var current: Character? { index < characters.count ? characters[index] : nil }

        func peek(_ offset: Int) -> Character? {
            index + offset < characters.count ? characters[index + offset] : nil
        }

        mutating func tokens() throws(CalcError) -> [CalcToken] {
            var tokens: [CalcToken] = []
            while let character = current {
                if character.isWhitespace {
                    index += 1
                } else if character.isASCIIDigit || (decimalSeparators.contains(character) && peek(1)?.isASCIIDigit == true) {
                    tokens.append(try number())
                } else if character.isLetter {
                    tokens.append(identifier())
                } else if let token = Self.symbols[character] {
                    index += 1
                    if character == "*", current == "*" {
                        index += 1
                        tokens.append(.power)
                    } else {
                        tokens.append(token)
                    }
                } else {
                    throw .unexpected(String(character))
                }
            }
            return tokens
        }

        static let symbols: [Character: CalcToken] = [
            "+": .plus, "-": .minus, "−": .minus,
            "*": .times, "×": .times, "·": .times, "/": .divide, "÷": .divide,
            "^": .power, "%": .percent, "°": .degree, "(": .openParenthesis, ")": .closeParenthesis,
        ]

        // MARK: - Numbers

        mutating func number() throws(CalcError) -> CalcToken {
            if current == "0", let radix = peek(1).flatMap({ Self.radixes[$0] }) {
                guard let first = peek(2) else { throw .unfinished }
                if first.isHexDigit, first.hexDigitValue! < radix {
                    index += 2
                    return try integer(radix: radix)
                }
            }

            var literal = digits()
            if let character = current, decimalSeparators.contains(character) {
                index += 1
                literal += "." + digits()
                if let next = current, decimalSeparators.contains(next) {
                    throw .unexpected(String(next))
                }
            }
            if current == "e" || current == "E" {
                let sign = peek(1) == "+" || peek(1) == "-" || peek(1) == "−"
                let digitOffset = sign ? 2 : 1
                if peek(digitOffset)?.isASCIIDigit == true {
                    literal += "e" + (sign && peek(1) != "+" ? "-" : "")
                    index += digitOffset
                    literal += digits()
                } else if peek(digitOffset) == nil {
                    // `1e` or `1e-` while the exponent is still being typed.
                    throw .unfinished
                }
            }
            guard let value = Double(literal) else { throw .unexpected(literal) }
            guard value.isFinite else { throw .overflow }
            return .number(value)
        }

        static let radixes: [Character: Int] = ["x": 16, "X": 16, "b": 2, "B": 2]

        /// ASCII digits, skipping `_` and spaces between two of them.
        mutating func digits() -> String {
            var result = ""
            while let character = current {
                if character.isASCIIDigit {
                    result.append(character)
                    index += 1
                } else if character == "_" || character == " ", !result.isEmpty, skipsToDigit() {
                    continue
                } else {
                    break
                }
            }
            return result
        }

        /// From a `_` or space, moves to the next digit if one follows
        /// directly (after any run of them); otherwise stays.
        mutating func skipsToDigit() -> Bool {
            var offset = 0
            while let character = peek(offset), character == "_" || character == " " {
                offset += 1
            }
            guard peek(offset)?.isASCIIDigit == true else { return false }
            index += offset
            return true
        }

        mutating func integer(radix: Int) throws(CalcError) -> CalcToken {
            var value: UInt64 = 0
            while let character = current {
                if let digit = character.hexDigitValue, digit < radix {
                    let (shifted, overflow) = value.multipliedReportingOverflow(by: UInt64(radix))
                    guard !overflow else { throw .overflow }
                    value = shifted + UInt64(digit)
                    index += 1
                } else if character == "_", peek(1)?.hexDigitValue.map({ $0 < radix }) == true {
                    index += 1
                } else {
                    break
                }
            }
            if let character = current, character.isLetter || character.isASCIIDigit {
                throw .unexpected(String(character))
            }
            return .number(Double(value))
        }

        // MARK: - Names

        mutating func identifier() -> CalcToken {
            var name = ""
            while let character = current, character.isLetter || character.isASCIIDigit || character == "_" {
                name.append(character)
                index += 1
            }
            return .identifier(name)
        }
    }
}

extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
