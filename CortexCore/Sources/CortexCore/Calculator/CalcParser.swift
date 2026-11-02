import Foundation

/// Reads a calculation into a `CalcExpression`, by recursive descent.
///
/// By binding strength, weakest first: `+ −`; `* / × ·`; unary `−` and `+`;
/// `^` (also `**`, right-associative, so `2^3^2` is `2^9`); postfix `%` and
/// `°` (degrees, in radians: `sin(30°)`).
/// `−2^2` is `−4`, as in maths. Functions take one argument in parentheses
/// (`sqrt(2)`); constants are `pi`, `π` and `e`. Names are case-insensitive.
/// No implicit multiplication (`2pi`) and no variables.
///
/// Parentheses still open at the end are closed (`(1 + 2` is 3), since the
/// calculation is evaluated as it is typed. Input that ends where more must
/// follow (`3 +`, `sqrt(`, `sq`) throws `CalcError.unfinished`, never a
/// real error.
public enum CalcParser {
    /// Deeper nesting is an error rather than a risk to the stack.
    static let maxDepth = 100

    public static func parse(_ text: String, decimalSeparator: Character = ".") throws(CalcError) -> CalcExpression {
        try parse(tokens: CalcLexer.tokens(text, decimalSeparator: decimalSeparator))
    }

    static func parse(tokens: [CalcToken]) throws(CalcError) -> CalcExpression {
        var parser = Parser(tokens: tokens)
        let expression = try parser.sum()
        if let token = parser.current {
            throw .unexpected(token.text)
        }
        return expression
    }

    private struct Parser {
        let tokens: [CalcToken]
        var index = 0
        var depth = 0

        var current: CalcToken? { index < tokens.count ? tokens[index] : nil }

        mutating func sum() throws(CalcError) -> CalcExpression {
            var expression = try product()
            while let token = current, token == .plus || token == .minus {
                index += 1
                expression = .binary(token == .plus ? .add : .subtract, expression, try product())
            }
            return expression
        }

        mutating func product() throws(CalcError) -> CalcExpression {
            var expression = try unary()
            while let token = current, token == .times || token == .divide {
                index += 1
                expression = .binary(token == .times ? .multiply : .divide, expression, try unary())
            }
            return expression
        }

        /// Every level of nesting passes through here, so the depth is
        /// counted here.
        mutating func unary() throws(CalcError) -> CalcExpression {
            depth += 1
            defer { depth -= 1 }
            guard depth <= CalcParser.maxDepth else { throw .tooDeep }

            switch current {
            case .minus:
                index += 1
                return .negate(try unary())
            case .plus:
                index += 1
                return try unary()
            default:
                return try power()
            }
        }

        mutating func power() throws(CalcError) -> CalcExpression {
            let base = try postfix()
            guard current == .power else { return base }
            index += 1
            return .binary(.power, base, try unary())
        }

        mutating func postfix() throws(CalcError) -> CalcExpression {
            var expression = try primary()
            while let token = current, token == .percent || token == .degree {
                index += 1
                expression = token == .percent ? .percent(expression) : .degrees(expression)
            }
            return expression
        }

        mutating func primary() throws(CalcError) -> CalcExpression {
            guard let token = current else { throw .unfinished }
            index += 1
            switch token {
            case .number(let value):
                return .number(value)
            case .identifier(let name):
                return try named(name)
            case .openParenthesis:
                return try parenthesized()
            default:
                throw .unexpected(token.text)
            }
        }

        mutating func named(_ name: String) throws(CalcError) -> CalcExpression {
            if let function = CalcFunction(rawValue: name.lowercased()) {
                switch current {
                case .openParenthesis:
                    index += 1
                    return .function(function, try parenthesized())
                case nil:
                    throw .unfinished
                default:
                    throw .needsParentheses(function.rawValue)
                }
            }
            if let constant = CalcConstant.named(name) {
                return .constant(constant)
            }
            // `sq` on the way to `sqrt`.
            if current == nil, Self.names.contains(where: { $0.hasPrefix(name.lowercased()) }) {
                throw .unfinished
            }
            throw .unknownName(name)
        }

        static let names = CalcFunction.allCases.map(\.rawValue) + CalcConstant.allCases.flatMap(\.names)

        /// After `(`: the inner sum and its `)`, which may be missing at the end.
        mutating func parenthesized() throws(CalcError) -> CalcExpression {
            let expression = try sum()
            switch current {
            case .closeParenthesis:
                index += 1
            case nil:
                break
            case let token?:
                throw .unexpected(token.text)
            }
            return expression
        }
    }
}
