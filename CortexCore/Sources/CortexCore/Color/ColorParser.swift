import Foundation

/// Reads a colour from text that is nothing but a colour, as designers and
/// stylesheets write them: `#1A2B3C`, `#fff`, `1a2b3c80`, `rgb(26, 43, 60)`,
/// `rgb(26 43 60 / 50%)`, `hsl(210, 40%, 17%)`. Strict, so that a clip that
/// merely mentions a colour, or a number, is not taken for one.
public enum ColorParser {
    /// Longer text is never a colour; keeps the check cheap for list rows.
    static let maxLength = 64

    public static func parse(_ text: String) -> ColorValue? {
        guard text.utf8.count <= maxLength else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return nil }
        if first == "#" {
            return hex(trimmed.dropFirst(), allowShort: true)
        }
        if first.isHexDigit, let color = hex(Substring(trimmed), allowShort: false) {
            return color
        }
        return function(trimmed)
    }

    // MARK: - Hex

    /// Without `#`, only six or eight digits mixing letters and numbers:
    /// `123456` is a number and `facade` a word.
    private static func hex(_ digits: Substring, allowShort: Bool) -> ColorValue? {
        guard digits.allSatisfy(\.isHexDigit) else { return nil }
        if !allowShort {
            guard digits.contains(where: \.isLetter), digits.contains(where: \.isNumber) else { return nil }
        }
        let values = digits.compactMap(\.hexDigitValue)
        switch values.count {
        case 3 where allowShort, 4 where allowShort:
            let bytes = values.map { $0 * 17 }
            return ColorValue(red255: bytes[0], green255: bytes[1], blue255: bytes[2], alpha255: bytes.count == 4 ? bytes[3] : 255)
        case 6, 8:
            let bytes = stride(from: 0, to: values.count, by: 2).map { values[$0] * 16 + values[$0 + 1] }
            return ColorValue(red255: bytes[0], green255: bytes[1], blue255: bytes[2], alpha255: bytes.count == 4 ? bytes[3] : 255)
        default:
            return nil
        }
    }

    // MARK: - rgb() and hsl()

    private static func function(_ text: String) -> ColorValue? {
        guard text.hasSuffix(")"), let open = text.firstIndex(of: "(") else { return nil }
        let name = text[..<open].lowercased()
        guard ["rgb", "rgba", "hsl", "hsla"].contains(name) else { return nil }
        guard let arguments = arguments(text[text.index(after: open)..<text.index(before: text.endIndex)]) else { return nil }
        var alpha = 1.0
        if let text = arguments.alpha {
            guard let value = alphaValue(text) else { return nil }
            alpha = value
        }

        if name.hasPrefix("rgb") {
            let channels = arguments.values.compactMap(rgbChannel)
            guard channels.count == 3 else { return nil }
            return ColorValue(red: channels[0], green: channels[1], blue: channels[2], alpha: alpha)
        }
        guard let hue = hueValue(arguments.values[0]),
              let saturation = percentValue(arguments.values[1]),
              let lightness = percentValue(arguments.values[2])
        else { return nil }
        return ColorValue(hue: hue, saturation: saturation, lightness: lightness, alpha: alpha)
    }

    /// `26, 43, 60` or `26, 43, 60, 0.5` (commas), `26 43 60` or
    /// `26 43 60 / 50%` (spaces): three values and maybe an alpha.
    private static func arguments(_ inner: Substring) -> (values: [Substring], alpha: Substring?)? {
        if inner.contains(",") {
            guard !inner.contains("/") else { return nil }
            let parts = inner.split(separator: ",", omittingEmptySubsequences: false).map(trimmed)
            guard parts.count == 3 || parts.count == 4, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
            return (Array(parts.prefix(3)), parts.count == 4 ? parts[3] : nil)
        }
        let halves = inner.split(separator: "/", omittingEmptySubsequences: false)
        let values = halves[0].split(whereSeparator: \.isWhitespace)
        guard values.count == 3, halves.count <= 2 else { return nil }
        guard halves.count == 2 else { return (values, nil) }
        let alpha = trimmed(halves[1])
        return alpha.isEmpty ? nil : (values, alpha)
    }

    private static func trimmed(_ text: Substring) -> Substring {
        let start = text.firstIndex { !$0.isWhitespace } ?? text.endIndex
        let end = text.lastIndex { !$0.isWhitespace }.map(text.index(after:)) ?? start
        return text[start..<max(start, end)]
    }

    /// 0…255 or 0%…100%.
    private static func rgbChannel(_ text: Substring) -> Double? {
        if text.hasSuffix("%") { return percentValue(text) }
        guard let value = number(text), (0...255).contains(value) else { return nil }
        return value / 255
    }

    /// 0…1 or 0%…100%.
    private static func alphaValue(_ text: Substring) -> Double? {
        if text.hasSuffix("%") { return percentValue(text) }
        guard let value = number(text), (0...1).contains(value) else { return nil }
        return value
    }

    /// `40%`, or `40` as modern CSS allows in hsl().
    private static func percentValue(_ text: Substring) -> Double? {
        let digits = text.hasSuffix("%") ? text.dropLast() : text
        guard let value = number(digits), (0...100).contains(value) else { return nil }
        return value / 100
    }

    /// Degrees, with or without `deg`.
    private static func hueValue(_ text: Substring) -> Double? {
        let digits = text.lowercased().hasSuffix("deg") ? text.dropLast(3) : text
        guard let value = number(digits), abs(value) <= 3600 else { return nil }
        return value
    }

    /// A plain decimal number; no exponents, no `inf`.
    private static func number(_ text: Substring) -> Double? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "." || $0 == "-" || $0 == "+") }) else {
            return nil
        }
        return Double(text)
    }
}
