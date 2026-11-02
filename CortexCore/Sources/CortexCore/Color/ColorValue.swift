import Foundation

/// A colour in sRGB, each component 0…1. What the colour picker copies and
/// what a colour clip's swatch shows.
public struct ColorValue: Sendable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    /// Components outside 0…1 (a Display P3 colour outside sRGB) are clamped.
    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = Self.clamp(red)
        self.green = Self.clamp(green)
        self.blue = Self.clamp(blue)
        self.alpha = Self.clamp(alpha)
    }

    /// 0…255 per component.
    public init(red255: Int, green255: Int, blue255: Int, alpha255: Int = 255) {
        self.init(red: Double(red255) / 255, green: Double(green255) / 255, blue: Double(blue255) / 255, alpha: Double(alpha255) / 255)
    }

    /// Hue in degrees (0..<360), saturation and lightness 0…1.
    public init(hue: Double, saturation: Double, lightness: Double, alpha: Double = 1) {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 360
        let s = Self.clamp(saturation)
        let l = Self.clamp(lightness)
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func channel(_ t: Double) -> Double {
            let t = t < 0 ? t + 1 : t > 1 ? t - 1 : t
            if t < 1 / 6 { return p + (q - p) * 6 * t }
            if t < 1 / 2 { return q }
            if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
            return p
        }
        self.init(red: channel(h + 1 / 3), green: channel(h), blue: channel(h - 1 / 3), alpha: alpha)
    }

    public var isOpaque: Bool { alpha255 == 255 }

    public var red255: Int { Self.byte(red) }
    public var green255: Int { Self.byte(green) }
    public var blue255: Int { Self.byte(blue) }
    public var alpha255: Int { Self.byte(alpha) }

    /// Hue in degrees (0..<360), saturation and lightness 0…1.
    public var hsl: (hue: Double, saturation: Double, lightness: Double) {
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let lightness = (maximum + minimum) / 2
        let delta = maximum - minimum
        guard delta > 0 else { return (0, 0, lightness) }
        let saturation = delta / (1 - abs(2 * lightness - 1))
        let hue: Double
        switch maximum {
        case red: hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
        case green: hue = (blue - red) / delta + 2
        default: hue = (red - green) / delta + 4
        }
        return ((hue * 60 + 360).truncatingRemainder(dividingBy: 360), saturation, lightness)
    }

    private static func clamp(_ value: Double) -> Double {
        value.isNaN ? 0 : min(max(value, 0), 1)
    }

    private static func byte(_ value: Double) -> Int {
        Int((value * 255).rounded())
    }
}
