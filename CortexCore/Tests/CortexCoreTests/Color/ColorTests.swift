import Foundation
import Testing
@testable import CortexCore

@Suite struct ColorParserTests {
    static let slate = ColorValue(red255: 26, green255: 43, blue255: 60)

    static let colors: [(String, ColorValue)] = [
        ("#1A2B3C", slate),
        ("#1a2b3c", slate),
        ("  #1A2B3C\n", slate),
        ("1A2B3C", slate),
        ("#fff", ColorValue(red255: 255, green255: 255, blue255: 255)),
        ("#f008", ColorValue(red255: 255, green255: 0, blue255: 0, alpha255: 0x88)),
        ("#1A2B3C80", ColorValue(red255: 26, green255: 43, blue255: 60, alpha255: 0x80)),
        ("1a2b3c80", ColorValue(red255: 26, green255: 43, blue255: 60, alpha255: 0x80)),
        ("rgb(26, 43, 60)", slate),
        ("RGB(26,43,60)", slate),
        ("rgb(26 43 60)", slate),
        ("rgba(26, 43, 60, 0.5)", ColorValue(red255: 26, green255: 43, blue255: 60, alpha255: 128)),
        ("rgb(26 43 60 / 50%)", ColorValue(red255: 26, green255: 43, blue255: 60, alpha255: 128)),
        ("rgb(100%, 0%, 0%)", ColorValue(red: 1, green: 0, blue: 0)),
        ("hsl(210, 40%, 17%)", ColorValue(hue: 210, saturation: 0.4, lightness: 0.17)),
        ("hsl(210deg 40% 17%)", ColorValue(hue: 210, saturation: 0.4, lightness: 0.17)),
        ("hsla(0, 100%, 50%, 0.25)", ColorValue(red: 1, green: 0, blue: 0, alpha: 0.25)),
        ("hsl(-120, 100%, 50%)", ColorValue(red: 0, green: 0, blue: 1)),
    ]

    @Test(arguments: colors)
    func parses(_ text: String, _ expected: ColorValue) throws {
        let color = try #require(ColorParser.parse(text))
        #expect(color.red255 == expected.red255)
        #expect(color.green255 == expected.green255)
        #expect(color.blue255 == expected.blue255)
        #expect(color.alpha255 == expected.alpha255)
    }

    static let notColors = [
        "", "#", "#12", "#12345", "#1234567", "#GGGGGG",
        "123456", "facade", "abc", "fff", "1a2b",
        "The colour is #1A2B3C", "#1A2B3C;", "color: #1A2B3C",
        "rgb(26, 43)", "rgb(26, 43, 60, 0.5, 1)", "rgb(256, 0, 0)", "rgb(-1, 0, 0)",
        "rgb(26, , 60)", "rgb(26 43 60 /)", "rgb(26, 43, 60 / 0.5)", "rgba(26, 43, 60, 2)",
        "rgb()", "rgb(1e2, 0, 0)", "rgb(inf, 0, 0)", "hsl(210, 140%, 17%)", "cmyk(0, 0, 0, 0)",
        "rgb(26, 43, 60", String(repeating: "a", count: 80),
    ]

    @Test(arguments: notColors)
    func rejects(_ text: String) {
        #expect(ColorParser.parse(text) == nil)
    }
}

@Suite struct ColorFormatTests {
    let slate = ColorValue(red255: 26, green255: 43, blue255: 60)
    let translucent = ColorValue(red255: 26, green255: 43, blue255: 60, alpha255: 128)

    @Test func opaque() {
        #expect(ColorFormat.hex.string(for: slate) == "#1A2B3C")
        #expect(ColorFormat.hex.string(for: slate, uppercaseHex: false) == "#1a2b3c")
        #expect(ColorFormat.hexWithoutHash.string(for: slate) == "1A2B3C")
        #expect(ColorFormat.rgb.string(for: slate) == "rgb(26, 43, 60)")
        #expect(ColorFormat.hsl.string(for: slate) == "hsl(210, 40%, 17%)")
        #expect(ColorFormat.swiftUI.string(for: slate) == "Color(red: 0.102, green: 0.169, blue: 0.235)")
    }

    @Test func withTransparency() {
        #expect(ColorFormat.hex.string(for: translucent) == "#1A2B3C80")
        #expect(ColorFormat.rgb.string(for: translucent) == "rgba(26, 43, 60, 0.5)")
        #expect(ColorFormat.hsl.string(for: translucent) == "hsla(210, 40%, 17%, 0.5)")
        #expect(ColorFormat.swiftUI.string(for: translucent) == "Color(red: 0.102, green: 0.169, blue: 0.235, opacity: 0.502)")
    }

    @Test func greysAndPrimaries() {
        #expect(ColorFormat.hsl.string(for: ColorValue(red: 0.5, green: 0.5, blue: 0.5)) == "hsl(0, 0%, 50%)")
        #expect(ColorFormat.hsl.string(for: ColorValue(red: 1, green: 0, blue: 0)) == "hsl(0, 100%, 50%)")
        #expect(ColorFormat.hsl.string(for: ColorValue(red: 0, green: 1, blue: 0)) == "hsl(120, 100%, 50%)")
        #expect(ColorFormat.swiftUI.string(for: ColorValue(red: 1, green: 0, blue: 0)) == "Color(red: 1, green: 0, blue: 0)")
    }

    /// Every format reads back as the same colour (to the byte), except
    /// SwiftUI, which nothing pastes back as text.
    @Test(arguments: [ColorFormat.hex, .hexWithoutHash, .rgb])
    func roundTrips(_ format: ColorFormat) throws {
        for color in [slate, translucent, ColorValue(red255: 255, green255: 128, blue255: 0)] {
            let parsed = try #require(ColorParser.parse(format.string(for: color)))
            #expect(parsed.red255 == color.red255 && parsed.green255 == color.green255 && parsed.blue255 == color.blue255)
        }
    }

    @Test func clampsOutOfGamutComponents() {
        let color = ColorValue(red: 1.08, green: -0.02, blue: 0.5)
        #expect(ColorFormat.hex.string(for: color) == "#FF0080")
    }

    /// A picked colour is recorded like any copy; it must not be flagged as
    /// a secret.
    @Test(arguments: ColorFormat.allCases)
    func isNotTakenForASecret(_ format: ColorFormat) {
        for color in [slate, translucent] {
            #expect(SensitiveTextDetector.reason(for: format.string(for: color)) == nil)
        }
    }
}
