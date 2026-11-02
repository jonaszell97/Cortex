import Foundation

/// Pretty-prints and minifies JSON without going through `JSONSerialization`,
/// so key order and number spellings (`1.50`, `1e3`) stay exactly as written.
public enum JSONFormatter {
    public static func pretty(_ text: String, indent: String = "  ") throws -> String {
        var output = ""
        var parser = Parser(text)
        try parser.parseDocument().write(to: &output, indent: indent, level: 0)
        return output
    }

    public static func minify(_ text: String) throws -> String {
        var output = ""
        var parser = Parser(text)
        try parser.parseDocument().write(to: &output, indent: nil, level: 0)
        return output
    }

    indirect enum Value {
        case object([(key: String, value: Value)])
        case array([Value])
        /// The literal as written: a quoted string with its escapes, a
        /// number, true, false or null.
        case literal(String)

        func write(to output: inout String, indent: String?, level: Int) {
            switch self {
            case .literal(let literal):
                output += literal
            case .array(let values):
                guard !values.isEmpty else { output += "[]"; return }
                output += "["
                for (index, value) in values.enumerated() {
                    if index > 0 { output += "," }
                    newline(&output, indent: indent, level: level + 1)
                    value.write(to: &output, indent: indent, level: level + 1)
                }
                newline(&output, indent: indent, level: level)
                output += "]"
            case .object(let members):
                guard !members.isEmpty else { output += "{}"; return }
                output += "{"
                for (index, member) in members.enumerated() {
                    if index > 0 { output += "," }
                    newline(&output, indent: indent, level: level + 1)
                    output += member.key
                    output += indent == nil ? ":" : ": "
                    member.value.write(to: &output, indent: indent, level: level + 1)
                }
                newline(&output, indent: indent, level: level)
                output += "}"
            }
        }

        private func newline(_ output: inout String, indent: String?, level: Int) {
            guard let indent else { return }
            output += "\n" + String(repeating: indent, count: level)
        }
    }

    private struct Parser {
        let scalars: [Unicode.Scalar]
        var position = 0

        init(_ text: String) {
            scalars = Array(text.unicodeScalars)
        }

        mutating func parseDocument() throws -> Value {
            skipWhitespace()
            // A byte order mark from a file pasted as text.
            if position < scalars.count, scalars[position] == "\u{FEFF}" { position += 1 }
            let value = try parseValue(depth: 0)
            skipWhitespace()
            guard position == scalars.count else { throw error("Unexpected text after the JSON value") }
            return value
        }

        private mutating func parseValue(depth: Int) throws -> Value {
            guard depth < 512 else { throw error("Nested too deeply") }
            skipWhitespace()
            guard let scalar = peek() else { throw error("Unexpected end of text") }
            switch scalar {
            case "{": return try parseObject(depth: depth)
            case "[": return try parseArray(depth: depth)
            case "\"": return .literal(try parseString())
            case "t": return .literal(try parseWord("true"))
            case "f": return .literal(try parseWord("false"))
            case "n": return .literal(try parseWord("null"))
            case "-", "0"..."9": return .literal(try parseNumber())
            default: throw error("Unexpected character “\(scalar)”")
            }
        }

        private mutating func parseObject(depth: Int) throws -> Value {
            position += 1
            var members: [(key: String, value: Value)] = []
            skipWhitespace()
            if peek() == "}" { position += 1; return .object([]) }
            while true {
                skipWhitespace()
                guard peek() == "\"" else { throw error("Expected a quoted key") }
                let key = try parseString()
                skipWhitespace()
                guard peek() == ":" else { throw error("Expected “:” after a key") }
                position += 1
                members.append((key, try parseValue(depth: depth + 1)))
                skipWhitespace()
                switch peek() {
                case ",": position += 1
                case "}": position += 1; return .object(members)
                default: throw error("Expected “,” or “}”")
                }
            }
        }

        private mutating func parseArray(depth: Int) throws -> Value {
            position += 1
            var values: [Value] = []
            skipWhitespace()
            if peek() == "]" { position += 1; return .array([]) }
            while true {
                values.append(try parseValue(depth: depth + 1))
                skipWhitespace()
                switch peek() {
                case ",": position += 1
                case "]": position += 1; return .array(values)
                default: throw error("Expected “,” or “]”")
                }
            }
        }

        private mutating func parseString() throws -> String {
            let start = position
            position += 1
            while let scalar = peek() {
                position += 1
                switch scalar {
                case "\"":
                    return String(String.UnicodeScalarView(scalars[start..<position]))
                case "\\":
                    guard let escaped = peek() else { break }
                    position += 1
                    switch escaped {
                    case "\"", "\\", "/", "b", "f", "n", "r", "t":
                        continue
                    case "u":
                        guard position + 4 <= scalars.count,
                              scalars[position..<position + 4].allSatisfy({ $0.properties.isASCIIHexDigit })
                        else { throw error("Invalid \\u escape") }
                        position += 4
                    default:
                        throw error("Invalid escape “\\\(escaped)”")
                    }
                default:
                    if scalar.value < 0x20 { throw error("Control character in a string") }
                }
            }
            throw error("Unterminated string")
        }

        private mutating func parseNumber() throws -> String {
            let start = position
            if peek() == "-" { position += 1 }
            guard let first = peek(), ("0"..."9").contains(first) else { throw error("Invalid number") }
            if first == "0" { position += 1 } else { skipDigits() }
            if peek() == "." {
                position += 1
                guard let digit = peek(), ("0"..."9").contains(digit) else { throw error("Invalid number") }
                skipDigits()
            }
            if peek() == "e" || peek() == "E" {
                position += 1
                if peek() == "+" || peek() == "-" { position += 1 }
                guard let digit = peek(), ("0"..."9").contains(digit) else { throw error("Invalid number") }
                skipDigits()
            }
            return String(String.UnicodeScalarView(scalars[start..<position]))
        }

        private mutating func parseWord(_ word: String) throws -> String {
            for expected in word.unicodeScalars {
                guard peek() == expected else { throw error("Unexpected character") }
                position += 1
            }
            return word
        }

        private mutating func skipDigits() {
            while let scalar = peek(), ("0"..."9").contains(scalar) { position += 1 }
        }

        private mutating func skipWhitespace() {
            while let scalar = peek(), scalar == " " || scalar == "\n" || scalar == "\r" || scalar == "\t" {
                position += 1
            }
        }

        private func peek() -> Unicode.Scalar? {
            position < scalars.count ? scalars[position] : nil
        }

        /// The message names line and column, since the JSON is usually a
        /// long single paste.
        private func error(_ message: String) -> QuickActionError {
            var line = 1
            var column = 1
            for scalar in scalars[..<min(position, scalars.count)] {
                if scalar == "\n" { line += 1; column = 1 } else { column += 1 }
            }
            return QuickActionError("Not valid JSON: \(message) (line \(line), column \(column))")
        }
    }
}
