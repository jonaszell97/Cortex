import Foundation

/// Why text could not be calculated. `unfinished` is input that may still
/// become valid as the user types (`3 +`, `sqrt(`); the palette shows nothing
/// for it rather than an error.
public enum CalcError: Error, Equatable, Sendable {
    case unfinished
    /// A character or token that does not belong where it is: `3 + * 2`, `3)`.
    case unexpected(String)
    case unknownName(String)
    /// A function name without its parentheses: `sqrt 4`.
    case needsParentheses(String)
    case tooDeep
    case divisionByZero
    /// The result, or a number typed, is too large for a Double.
    case overflow
    /// No real result: `sqrt(-1)`, `ln(0)`, `tan(pi/2)`.
    case undefined
    /// A word after a number, or after `to`, that is no unit: `3 flurbs`.
    case unknownUnit(String)
    /// `3 kg to cm`.
    case incompatibleUnits(CalcUnitKind, CalcUnitKind)

    /// What the palette's pane shows, in red.
    public var message: String {
        switch self {
        case .unfinished: "Unfinished calculation"
        case .unexpected(let text): "Unexpected “\(text)”"
        case .unknownName(let name): "Unknown name: \(name)"
        case .needsParentheses(let name): "Write \(name)(…)"
        case .tooDeep: "Too many nested parentheses"
        case .divisionByZero: "Division by zero"
        case .overflow: "The result is too large"
        case .undefined: "The result is undefined"
        case .unknownUnit(let name): "Unknown unit: \(name)"
        case .incompatibleUnits(let from, let to): "Can't convert \(from.rawValue) to \(to.rawValue)"
        }
    }
}
