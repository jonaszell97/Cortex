import Foundation

/// Computes a `CalcExpression` in `Double`. Every step is checked, so the
/// result is always a finite number: division by zero, overflow and results
/// that are not real numbers throw.
public enum CalcEvaluator {
    public static func evaluate(_ expression: CalcExpression) throws(CalcError) -> Double {
        switch expression {
        case .number(let value):
            return value
        case .constant(let constant):
            return constant.value
        case .negate(let operand):
            return -(try evaluate(operand))
        case .percent(let operand):
            return try evaluate(operand) / 100
        case .degrees(let operand):
            return try evaluate(operand) * .pi / 180
        case .binary(let op, let left, let right):
            return try binary(op, evaluate(left), evaluate(right))
        case .function(let function, let argument):
            return try apply(function, evaluate(argument))
        }
    }

    /// Parses and evaluates text in one step.
    public static func evaluate(_ text: String, decimalSeparator: Character = ".") throws(CalcError) -> Double {
        try evaluate(CalcParser.parse(text, decimalSeparator: decimalSeparator))
    }

    private static func binary(_ op: CalcOperator, _ left: Double, _ right: Double) throws(CalcError) -> Double {
        switch op {
        case .add:
            return try checked(left + right)
        case .subtract:
            return try checked(left - right)
        case .multiply:
            return try checked(left * right)
        case .divide:
            guard right != 0 else { throw .divisionByZero }
            return try checked(left / right)
        case .power:
            if left == 0, right < 0 { throw .divisionByZero }
            return try checked(Foundation.pow(left, right))
        }
    }

    private static func apply(_ function: CalcFunction, _ x: Double) throws(CalcError) -> Double {
        switch function {
        case .sqrt:
            guard x >= 0 else { throw .undefined }
            return x.squareRoot()
        case .abs:
            return Swift.abs(x)
        case .round:
            return x.rounded()
        case .floor:
            return x.rounded(.down)
        case .ceil:
            return x.rounded(.up)
        case .ln:
            guard x > 0 else { throw .undefined }
            return Foundation.log(x)
        case .log:
            guard x > 0 else { throw .undefined }
            return Foundation.log10(x)
        case .sin, .cos, .tan:
            return try trigonometric(function, x)
        }
    }

    /// At multiples of π/2 the exact value, so `sin(pi)` is 0 and not
    /// 1.2e-16, and `tan(pi/2)` is undefined rather than 1.6e16.
    private static func trigonometric(_ function: CalcFunction, _ x: Double) throws(CalcError) -> Double {
        let quarters = x / (Double.pi / 2)
        let nearest = quarters.rounded()
        // Near 0 the functions are exact anyway, and snapping would turn
        // `sin(1e-12)` into 0.
        if nearest != 0, Swift.abs(quarters - nearest) < 1e-10, Swift.abs(nearest) < 1e12 {
            let quarter = Int(nearest).modulo(4)
            switch function {
            case .sin: return [0, 1, 0, -1][quarter]
            case .cos: return [1, 0, -1, 0][quarter]
            default:
                guard quarter.isMultiple(of: 2) else { throw .undefined }
                return 0
            }
        }
        switch function {
        case .sin: return Foundation.sin(x)
        case .cos: return Foundation.cos(x)
        default: return try checked(Foundation.tan(x))
        }
    }

    private static func checked(_ value: Double) throws(CalcError) -> Double {
        if value.isNaN { throw .undefined }
        if value.isInfinite { throw .overflow }
        return value
    }
}

private extension Int {
    /// Always 0..<divisor, also for negative numbers.
    func modulo(_ divisor: Int) -> Int {
        ((self % divisor) + divisor) % divisor
    }
}
