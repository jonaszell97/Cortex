import Foundation

/// How a result is written. `display` is for reading, in the system's
/// number format; `plain` is for pasting into code.
public enum CalcFormatter {
    /// Outside this range of decimal exponents, `display` switches to
    /// scientific notation (`1.5e20`, `2e-9`).
    static let positionalExponents = -6...14

    /// Rounded to `digits` significant digits (1 to 15), with the locale's decimal
    /// separator and grouping: `1.777777778`, `2,073,600` (`2.073.600` in
    /// German), `0.3` for `0.1 + 0.2`.
    public static func display(_ value: Double, digits: Int = 10, locale: Locale = .current) -> String {
        let digits = min(max(digits, 1), 15)
        // `%e` rounds the mantissa and carries into the exponent
        // (9.9999999999 becomes 1e1), so both are read back from it.
        let scientific = String(format: "%.*e", locale: Locale(identifier: "en_US_POSIX"), digits - 1, value)
        guard let rounded = Double(scientific), rounded != 0 else { return "0" }
        // Foundation writes `E` with a locale given, `e` without.
        let parts = scientific.split { $0 == "e" || $0 == "E" }
        let exponent = Int(parts[1])!

        if positionalExponents.contains(exponent) {
            return rounded.formatted(.number.precision(.significantDigits(1...digits)).locale(locale))
        }
        var mantissa = String(parts[0])
        if mantissa.contains(".") {
            while mantissa.hasSuffix("0") { mantissa.removeLast() }
            if mantissa.hasSuffix(".") { mantissa.removeLast() }
        }
        let separator = locale.decimalSeparator ?? "."
        return mantissa.replacingOccurrences(of: ".", with: separator) + "e\(exponent)"
    }

    /// `value` rounded to `digits` significant digits.
    static func rounded(_ value: Double, digits: Int) -> Double {
        guard value.isFinite, value != 0 else { return value }
        return Double(String(format: "%.*e", locale: Locale(identifier: "en_US_POSIX"), digits - 1, value)) ?? value
    }

    /// The shortest text that reads back as the same Double, with a `.`
    /// decimal point and no grouping: `1.7777777777777777`, `2073600`,
    /// `1e+20`.
    public static func plain(_ value: Double) -> String {
        if value == 0 { return "0" }
        let text = "\(value)"
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }
}
