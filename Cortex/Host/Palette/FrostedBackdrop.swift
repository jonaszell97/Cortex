import AppKit
import SwiftUI

/// The glass style's frosted surface: whatever is behind the panel, blurred
/// by the window server.
///
/// Not Liquid Glass: `.glassEffect` is clear enough that a busy or warm
/// wallpaper shows through and turns the icon's colours on top of it muddy,
/// and its soft, refracting edge gave the transparent window an irregular
/// shadow outline. This frosts evenly, and its rounded mask gives the window
/// a clean shape to cast its shadow from. It is kept active although Cortex
/// is never the active app, which would otherwise grey it out.
struct FrostedBackdrop: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.maskImage = Self.mask(cornerRadius: cornerRadius)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}

    /// A rounded rectangle that stretches to any size; SwiftUI's clip shapes
    /// do not reach a behind-window blur, only a mask image does.
    private static func mask(cornerRadius radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

extension View {
    /// A pane of Liquid Glass. Before macOS 26, which does not have it, the
    /// frosted surface of the glass style, with a faint rim to keep the edge
    /// visible over windows of the same colour.
    @ViewBuilder
    func glassPane(cornerRadius: CGFloat) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            let shape = RoundedRectangle(cornerRadius: cornerRadius)
            background(FrostedBackdrop(cornerRadius: cornerRadius))
                .clipShape(shape)
                .overlay(shape.strokeBorder(.separator, lineWidth: 0.5))
        }
    }
}
