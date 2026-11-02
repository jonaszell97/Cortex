import Foundation

/// What is typed after `=`: a calculation, a quantity (`5 ft`) or a
/// conversion (`3 in to cm`).
///
/// `<expression> [<unit> [(to | as | in | → | ->) <unit>]]`. The expression
/// is a plain number (`(1920/1080) m to ft`); units do not take part in the
/// arithmetic. `in` is both inches and "convert to": it converts only when
/// the text before it already ends in a unit and a unit follows it, so
/// `3 in to cm`, `3 in in cm` and `3 m in ft` all work.
public struct CalcQuery: Equatable, Sendable {
    public let expression: CalcExpression
    /// The unit typed after the expression.
    public let unit: CalcUnit?
    /// The unit to convert to.
    public let target: CalcUnit?

    public static func parse(_ text: String, decimalSeparator: Character = ".") throws(CalcError) -> CalcQuery {
        let text = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        func expression(_ text: Substring) throws(CalcError) -> CalcExpression {
            try CalcParser.parse(String(text), decimalSeparator: decimalSeparator)
        }

        // A conversion, from the last separator whose left side ends in a unit.
        for match in text.matches(of: separator).reversed() {
            let head = text[..<match.range.lowerBound]
            guard let source = UnitCatalog.suffix(of: head) else { continue }
            let value = try expression(source.rest)
            let tail = text[match.range.upperBound...].trimmingCharacters(in: .whitespaces)
            if let target = UnitCatalog.unit(named: tail) {
                return CalcQuery(expression: value, unit: source.unit, target: target)
            }
            if tail.isEmpty || UnitCatalog.isPrefix(Substring(tail)) { throw .unfinished }
            throw .unknownUnit(tail)
        }

        // A quantity, if what comes before the unit is a calculation.
        if let quantity = UnitCatalog.suffix(of: text), let value = try? expression(quantity.rest) {
            return CalcQuery(expression: value, unit: quantity.unit, target: nil)
        }

        do {
            return CalcQuery(expression: try expression(text), unit: nil, target: nil)
        } catch {
            // `3 c` on the way to `3 cm`; `3 flurbs`.
            if let trailing = trailingWord(text), (try? expression(trailing.rest)) != nil {
                if UnitCatalog.isPrefix(trailing.word) { throw .unfinished }
                throw .unknownUnit(String(trailing.word))
            }
            throw error
        }
    }

    /// ` to `, ` as `, ` in ` (or at the end, while the target is still to
    /// come), `→`, `->`.
    private nonisolated(unsafe) static let separator = #/(?i)\s+(?:to|as|in)(?=\s|$)|\s*(?:→|->)\s*/#

    /// The letters at the end, after something that is not a letter, and
    /// the text before them.
    private static func trailingWord(_ text: Substring) -> (word: Substring, rest: Substring)? {
        let start = text.lastIndex { !$0.isLetter }.map(text.index(after:)) ?? text.startIndex
        let word = text[start...]
        let rest = text[..<start].trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty, !rest.isEmpty else { return nil }
        return (word, Substring(rest))
    }

    public func evaluate() throws(CalcError) -> CalcResult {
        let value = try CalcEvaluator.evaluate(expression)
        guard let unit, let target else { return CalcResult(value: value, unit: unit) }
        guard unit.kind == target.kind else { throw .incompatibleUnits(unit.kind, target.kind) }
        let converted = unit.convert(value, to: target)
        guard converted.isFinite else { throw .overflow }
        return CalcResult(value: converted, unit: target)
    }

    /// What the palette's pane shows: `1920 ÷ 1080`, `5 feet`,
    /// `3 inches → centimetres`, `(1920 ÷ 1080) metres`.
    public var text: String {
        guard let unit else { return expression.text }
        var amount: String
        switch expression {
        case .number, .constant, .function: amount = expression.text
        default: amount = "(\(expression.text))"
        }
        let isOne = expression == .number(1) || expression == .negate(.number(1))
        amount += " " + (isOne ? unit.name : unit.plural)
        guard let target else { return amount }
        return amount + " → " + target.plural
    }
}

/// A calculated value, with the unit it is in, if any.
public struct CalcResult: Equatable, Sendable {
    public let value: Double
    public let unit: CalcUnit?

    public init(value: Double, unit: CalcUnit?) {
        self.value = value
        self.unit = unit
    }
}
