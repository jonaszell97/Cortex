import AppKit
import CortexCore

/// Lets the user pick a pixel on screen. Tests hand in a fake, so no
/// eyedropper appears.
@MainActor
protocol ColorSampling: AnyObject {
    /// The picked colour in sRGB, or nil if the user pressed Esc.
    func sample() async -> ColorValue?
}

/// The system eyedropper (`NSColorSampler`). It is drawn by macOS, so it
/// needs no Screen Recording permission.
@MainActor
final class SystemColorSampler: ColorSampling {
    func sample() async -> ColorValue? {
        let color = await withCheckedContinuation { (continuation: CheckedContinuation<NSColor?, Never>) in
            NSColorSampler().show { continuation.resume(returning: $0) }
        }
        return color.flatMap(Self.sRGB)
    }

    /// The sampled colour is in the display's colour space (Display P3 on
    /// recent Macs); hex values mean sRGB everywhere else. Colours outside
    /// sRGB are clamped by `ColorValue`.
    static func sRGB(_ color: NSColor) -> ColorValue? {
        guard let converted = color.usingColorSpace(.sRGB) else { return nil }
        return ColorValue(
            red: converted.redComponent, green: converted.greenComponent, blue: converted.blueComponent,
            alpha: converted.alphaComponent)
    }
}
