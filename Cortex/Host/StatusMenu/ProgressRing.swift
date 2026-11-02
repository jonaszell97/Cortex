import AppKit

/// The menu bar icon while quick actions run: a ring that fills clockwise
/// from the top. A template image, so it follows the menu bar's appearance.
enum ProgressRing {
    static let size = NSSize(width: 18, height: 18)

    /// - Parameter progress: 0 to 1; nil (no job has reported progress yet)
    ///   shows a short arc.
    static func image(progress: Double?) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            let lineWidth: CGFloat = 2.2
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius = min(rect.width, rect.height) / 2 - lineWidth / 2 - 1

            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = lineWidth
            NSColor.black.withAlphaComponent(0.3).setStroke()
            track.stroke()

            let fraction = min(max(progress ?? 0.12, 0), 1)
            guard fraction > 0 else { return true }
            let arc = NSBezierPath()
            // Angles run counter-clockwise from three o'clock; start at twelve.
            arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * fraction, clockwise: true)
            arc.lineWidth = lineWidth
            arc.lineCapStyle = .round
            NSColor.black.setStroke()
            arc.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}
