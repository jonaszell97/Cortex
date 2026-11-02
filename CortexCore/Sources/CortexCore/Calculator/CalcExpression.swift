import Foundation

/// A parsed calculation, before it is evaluated.
public indirect enum CalcExpression: Equatable, Sendable {
    case number(Double)
    case constant(CalcConstant)
    case negate(CalcExpression)
    /// Postfix `%`: divides by 100.
    case percent(CalcExpression)
    /// Postfix `°`: degrees to radians, for `sin(30°)`.
    case degrees(CalcExpression)
    case binary(CalcOperator, CalcExpression, CalcExpression)
    case function(CalcFunction, CalcExpression)
}

public enum CalcOperator: Equatable, Sendable {
    case add, subtract, multiply, divide, power

    var symbol: String {
        switch self {
        case .add: "+"
        case .subtract: "−"
        case .multiply: "×"
        case .divide: "÷"
        case .power: "^"
        }
    }
}

public enum CalcFunction: String, CaseIterable, Sendable {
    case sqrt, abs, round, floor, ceil, ln, log, sin, cos, tan
}

public enum CalcConstant: CaseIterable, Sendable {
    case pi, e

    /// The names it is typed as; the first is how it is shown.
    var names: [String] {
        switch self {
        case .pi: ["π", "pi"]
        case .e: ["e"]
        }
    }

    var value: Double {
        switch self {
        case .pi: Double.pi
        case .e: M_E
        }
    }

    static func named(_ name: String) -> CalcConstant? {
        allCases.first { $0.names.contains(name.lowercased()) }
    }
}

// MARK: - Text

extension CalcExpression {
    /// How the palette's pane shows what was understood: `1920 ÷ 1080`,
    /// `−(1 + 2)`, `(−2)^2`, `sqrt(2) × π`. Parentheses only where needed.
    public var text: String {
        switch self {
        case .number(let value):
            CalcFormatter.plain(value)
        case .constant(let constant):
            constant.names[0]
        case .negate(let operand):
            // `−(−3)` rather than `−−3`.
            "−" + operand.text(parenthesizedBelow: .power)
        case .percent(let operand):
            operand.text(parenthesizedBelow: .percent) + "%"
        case .degrees(let operand):
            operand.text(parenthesizedBelow: .percent) + "°"
        case .binary(let op, let left, let right):
            Self.binaryText(op, left, right)
        case .function(let function, let argument):
            "\(function.rawValue)(\(argument.text))"
        }
    }

    private static func binaryText(_ op: CalcOperator, _ left: CalcExpression, _ right: CalcExpression) -> String {
        let level = Precedence(op)
        // Left-associative operators need parentheses on the right at the
        // same level (`1 − (2 − 3)`); `^` is right-associative, so the other
        // way around (`(2^3)^2`).
        let leftText = op == .power
            ? left.text(parenthesizedBelow: .atom)
            : left.text(parenthesizedBelow: level)
        let rightText = op == .power
            ? right.text(parenthesizedBelow: .power)
            : right.text(parenthesizedBelow: level.next)
        return op == .power ? "\(leftText)^\(rightText)" : "\(leftText) \(op.symbol) \(rightText)"
    }

    private func text(parenthesizedBelow minimum: Precedence) -> String {
        precedence < minimum ? "(\(text))" : text
    }

    private var precedence: Precedence {
        switch self {
        case .number, .constant, .function: .atom
        case .negate: .negate
        case .percent, .degrees: .percent
        case .binary(let op, _, _): Precedence(op)
        }
    }
}

/// Binding strength, weakest first. `−2^2` is `−(2^2)`, as in maths.
private enum Precedence: Int, Comparable {
    case sum, product, negate, power, percent, atom

    init(_ op: CalcOperator) {
        switch op {
        case .add, .subtract: self = .sum
        case .multiply, .divide: self = .product
        case .power: self = .power
        }
    }

    var next: Precedence { Precedence(rawValue: rawValue + 1) ?? .atom }

    static func < (lhs: Precedence, rhs: Precedence) -> Bool { lhs.rawValue < rhs.rawValue }
}
