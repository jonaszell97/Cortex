import Foundation

/// How a colour is written: what the colour picker copies and what a colour
/// clip's preview lists. The raw values are stored settings; never rename one.
public enum ColorFormat: String, CaseIterable, Sendable {
    /// `#1A2B3C`, `#1A2B3C80` with transparency.
    case hex
    /// `1A2B3C`
    case hexWithoutHash
    /// `rgb(26, 43, 60)`, `rgba(26, 43, 60, 0.5)`
    case rgb
    /// `hsl(210, 40%, 17%)`, `hsla(210, 40%, 17%, 0.5)`
    case hsl
    /// `Color(red: 0.102, green: 0.169, blue: 0.235)`
    case swiftUI

    public var title: String {
        switch self {
        case .hex: "Hex (#1A2B3C)"
        case .hexWithoutHash: "Hex without # (1A2B3C)"
        case .rgb: "CSS rgb()"
        case .hsl: "CSS hsl()"
        case .swiftUI: "SwiftUI Color"
        }
    }

    /// `uppercaseHex` applies to the hex formats only.
    public func string(for color: ColorValue, uppercaseHex: Bool = true) -> String {
        switch self {
        case .hex:
            "#" + Self.hexDigits(color, uppercase: uppercaseHex)
        case .hexWithoutHash:
            Self.hexDigits(color, uppercase: uppercaseHex)
        case .rgb:
            color.isOpaque
                ? "rgb(\(color.red255), \(color.green255), \(color.blue255))"
                : "rgba(\(color.red255), \(color.green255), \(color.blue255), \(Self.decimal(color.alpha, places: 2)))"
        case .hsl:
            Self.hslString(color)
        case .swiftUI:
            "Color(red: \(Self.decimal(color.red, places: 3)), green: \(Self.decimal(color.green, places: 3)), blue: \(Self.decimal(color.blue, places: 3))"
                + (color.isOpaque ? ")" : ", opacity: \(Self.decimal(color.alpha, places: 3)))")
        }
    }

    private static func hexDigits(_ color: ColorValue, uppercase: Bool) -> String {
        var bytes = [color.red255, color.green255, color.blue255]
        if !color.isOpaque { bytes.append(color.alpha255) }
        let digits = bytes.map { String(format: "%02X", $0) }.joined()
        return uppercase ? digits : digits.lowercased()
    }

    private static func hslString(_ color: ColorValue) -> String {
        let hsl = color.hsl
        var hue = Int(hsl.hue.rounded())
        if hue == 360 { hue = 0 }
        let values = "\(hue), \(Int((hsl.saturation * 100).rounded()))%, \(Int((hsl.lightness * 100).rounded()))%"
        return color.isOpaque ? "hsl(\(values))" : "hsla(\(values), \(decimal(color.alpha, places: 2)))"
    }

    /// Up to `places` decimals without trailing zeros: `0.5`, `1`, `0.102`.
    private static func decimal(_ value: Double, places: Int) -> String {
        let scale = pow(10, Double(places))
        let rounded = (value * scale).rounded() / scale
        var text = String(format: "%.\(places)f", rounded)
        while text.contains("."), text.last == "0" { text.removeLast() }
        if text.last == "." { text.removeLast() }
        return text
    }
}
