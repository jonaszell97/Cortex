import Foundation

/// The part of TOML that action files need: top-level `key = value` pairs
/// with strings (all four kinds), booleans, integers and arrays of those,
/// plus comments. Tables are rejected with a clear error rather than
/// ignored, except by `parseTables`, which reads one level of `[name]`
/// tables (`projects.toml`).
public enum TOML {
    public enum Value: Sendable, Equatable {
        case string(String)
        case integer(Int)
        case bool(Bool)
        case array([Value])
    }

    public struct ParseError: Error, Equatable, CustomStringConvertible {
        public var line: Int
        public var message: String

        public var description: String { "line \(line): \(message)" }
    }

    /// A document with tables: the keys before the first table, then each
    /// table in order.
    public struct Document: Sendable, Equatable {
        public var keys: [String: Value]
        public var tables: [Table]
    }

    public struct Table: Sendable, Equatable {
        public var name: String
        /// The line of its `[name]`, for messages.
        public var line: Int
        public var keys: [String: Value]
    }

    public static func parse(_ text: String) throws -> [String: Value] {
        var parser = Parser(text)
        return try parser.parseDocument(allowingTables: false).keys
    }

    /// Also reads `[name]` tables; nested and dotted ones, and arrays of
    /// tables, are rejected.
    public static func parseTables(_ text: String) throws -> Document {
        var parser = Parser(text)
        return try parser.parseDocument(allowingTables: true)
    }

    private struct Parser {
        let scalars: [Unicode.Scalar]
        var position = 0
        var line = 1

        init(_ text: String) {
            scalars = Array(text.unicodeScalars)
        }

        mutating func parseDocument(allowingTables: Bool) throws -> Document {
            var document = Document(keys: [:], tables: [])
            // The keys of the current table, or of the top before the first.
            var result: [String: Value] = [:]
            func finishSection() {
                if document.tables.isEmpty {
                    document.keys = result
                } else {
                    document.tables[document.tables.count - 1].keys = result
                }
            }
            while true {
                skipWhitespaceAndComments(newlines: true)
                guard let scalar = peek() else {
                    finishSection()
                    return document
                }
                if scalar == "[" {
                    guard allowingTables else { throw error("Tables ([section]) are not supported; put every key at the top") }
                    let tableLine = line
                    advance()
                    if peek() == "[" { throw error("Arrays of tables ([[section]]) are not supported") }
                    skipWhitespaceAndComments(newlines: false)
                    let name = try parseKey()
                    skipWhitespaceAndComments(newlines: false)
                    guard peek() == "]" else { throw error("Expected “]” after the table name “\(name)”") }
                    advance()
                    skipWhitespaceAndComments(newlines: false)
                    if let next = peek(), next != "\n", next != "\r" {
                        throw error("Expected a line break after [\(name)]")
                    }
                    guard !document.tables.contains(where: { $0.name == name }) else {
                        throw ParseError(line: tableLine, message: "[\(name)] is there twice")
                    }
                    finishSection()
                    document.tables.append(Table(name: name, line: tableLine, keys: [:]))
                    result = [:]
                    continue
                }
                let keyLine = line
                let key = try parseKey()
                skipWhitespaceAndComments(newlines: false)
                guard peek() == "=" else { throw error("Expected “=” after “\(key)”") }
                advance()
                skipWhitespaceAndComments(newlines: false)
                let value = try parseValue()
                guard result[key] == nil else { throw ParseError(line: keyLine, message: "“\(key)” is set twice") }
                result[key] = value
                skipWhitespaceAndComments(newlines: false)
                if let next = peek(), next != "\n", next != "\r" {
                    throw error("Expected a line break after the value of “\(key)”")
                }
            }
        }

        private mutating func parseKey() throws -> String {
            if peek() == "\"" { return try parseBasicString() }
            if peek() == "'" { return try parseLiteralString() }
            var key = ""
            while let scalar = peek(), scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || scalar == "_" || scalar == "-" {
                key.unicodeScalars.append(scalar)
                advance()
            }
            if peek() == "." { throw error("Dotted keys are not supported") }
            guard !key.isEmpty else { throw error("Expected a key") }
            return key
        }

        private mutating func parseValue() throws -> Value {
            guard let scalar = peek() else { throw error("Expected a value") }
            switch scalar {
            case "\"":
                return .string(lookingAt("\"\"\"") ? try parseMultilineBasicString() : try parseBasicString())
            case "'":
                return .string(lookingAt("'''") ? try parseMultilineLiteralString() : try parseLiteralString())
            case "[":
                return try parseArray()
            case "t", "f":
                if lookingAt("true") { position += 4; return .bool(true) }
                if lookingAt("false") { position += 5; return .bool(false) }
                throw error("Expected a value")
            case "+", "-", "0"..."9":
                var digits = ""
                if scalar == "+" || scalar == "-" { digits.unicodeScalars.append(scalar); advance() }
                while let next = peek(), ("0"..."9").contains(next) || next == "_" {
                    if next != "_" { digits.unicodeScalars.append(next) }
                    advance()
                }
                guard let number = Int(digits) else { throw error("Only whole numbers are supported") }
                if let next = peek(), next == "." || next == "e" || next == "E" || next == ":" {
                    throw error("Only whole numbers are supported")
                }
                return .integer(number)
            default:
                throw error("Expected a value (strings need quotes)")
            }
        }

        private mutating func parseArray() throws -> Value {
            advance()
            var values: [Value] = []
            while true {
                skipWhitespaceAndComments(newlines: true)
                if peek() == "]" { advance(); return .array(values) }
                values.append(try parseValue())
                skipWhitespaceAndComments(newlines: true)
                switch peek() {
                case ",": advance()
                case "]": advance(); return .array(values)
                default: throw error("Expected “,” or “]” in the array")
                }
            }
        }

        private mutating func parseBasicString() throws -> String {
            advance()
            var result = ""
            while let scalar = peek() {
                advance()
                switch scalar {
                case "\"": return result
                case "\\": result.unicodeScalars.append(try parseEscape())
                case "\n": throw ParseError(line: line - 1, message: "Line break in a string; use \"\"\"…\"\"\" for several lines")
                default: result.unicodeScalars.append(scalar)
                }
            }
            throw error("Unterminated string")
        }

        private mutating func parseMultilineBasicString() throws -> String {
            position += 3
            skipFirstNewline()
            var result = ""
            while let scalar = peek() {
                if lookingAt("\"\"\"") {
                    position += 3
                    return result
                }
                advance()
                if scalar == "\\" {
                    // A backslash at the end of a line joins it with the next.
                    if let next = peek(), next == "\n" || next == "\r" || next == " " || next == "\t" {
                        while let next = peek(), next == "\n" || next == "\r" || next == " " || next == "\t" { advance() }
                    } else {
                        result.unicodeScalars.append(try parseEscape())
                    }
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
            throw error("Unterminated \"\"\" string")
        }

        private mutating func parseLiteralString() throws -> String {
            advance()
            var result = ""
            while let scalar = peek() {
                advance()
                if scalar == "'" { return result }
                if scalar == "\n" { throw ParseError(line: line - 1, message: "Line break in a string; use '''…''' for several lines") }
                result.unicodeScalars.append(scalar)
            }
            throw error("Unterminated string")
        }

        private mutating func parseMultilineLiteralString() throws -> String {
            position += 3
            skipFirstNewline()
            var result = ""
            while let scalar = peek() {
                if lookingAt("'''") {
                    position += 3
                    return result
                }
                advance()
                result.unicodeScalars.append(scalar)
            }
            throw error("Unterminated ''' string")
        }

        private mutating func parseEscape() throws -> Unicode.Scalar {
            guard let scalar = peek() else { throw error("Unterminated escape") }
            advance()
            switch scalar {
            case "n": return "\n"
            case "t": return "\t"
            case "r": return "\r"
            case "b": return "\u{08}"
            case "f": return "\u{0C}"
            case "\"": return "\""
            case "\\": return "\\"
            case "u", "U":
                let length = scalar == "u" ? 4 : 8
                guard position + length <= scalars.count else { throw error("Invalid \\\(scalar) escape") }
                let hex = String(String.UnicodeScalarView(scalars[position..<position + length]))
                guard let value = UInt32(hex, radix: 16), let result = Unicode.Scalar(value) else {
                    throw error("Invalid \\\(scalar) escape")
                }
                position += length
                return result
            default:
                throw error("Invalid escape “\\\(scalar)”")
            }
        }

        private mutating func skipFirstNewline() {
            if peek() == "\r" { advance() }
            if peek() == "\n" { advance() }
        }

        private mutating func skipWhitespaceAndComments(newlines: Bool) {
            while let scalar = peek() {
                if scalar == " " || scalar == "\t" || (newlines && (scalar == "\n" || scalar == "\r")) {
                    advance()
                } else if scalar == "#" {
                    while let next = peek(), next != "\n" { advance() }
                } else {
                    return
                }
            }
        }

        private func lookingAt(_ text: String) -> Bool {
            var index = position
            for scalar in text.unicodeScalars {
                guard index < scalars.count, scalars[index] == scalar else { return false }
                index += 1
            }
            return true
        }

        private func peek() -> Unicode.Scalar? {
            position < scalars.count ? scalars[position] : nil
        }

        private mutating func advance() {
            if position < scalars.count, scalars[position] == "\n" { line += 1 }
            position += 1
        }

        private func error(_ message: String) -> ParseError {
            ParseError(line: line, message: message)
        }
    }
}
