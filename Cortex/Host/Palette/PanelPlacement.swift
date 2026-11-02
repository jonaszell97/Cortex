import Foundation

/// Where the palette opens. A palette that was dragged somewhere opens there
/// again, kept as the position of its centre relative to the screen (0…1 on
/// each axis), so it lands in the same place on a display of another size.
enum PanelPlacement {
    /// The panel's centre in `screen`, as fractions of its width and height.
    static func relativeCenter(of frame: CGRect, in screen: CGRect) -> CGPoint {
        CGPoint(
            x: (frame.midX - screen.minX) / screen.width,
            y: (frame.midY - screen.minY) / screen.height)
    }

    /// The origin for a panel of `size` whose centre is at `relativeCenter`
    /// (the middle when nil), on whole points, moved as far as needed to keep
    /// it on `screen`.
    static func origin(size: CGSize, relativeCenter: CGPoint?, in screen: CGRect) -> CGPoint {
        let center = relativeCenter ?? CGPoint(x: 0.5, y: 0.5)
        let x = (screen.minX + center.x * screen.width - size.width / 2).rounded()
        let y = (screen.minY + center.y * screen.height - size.height / 2).rounded()
        return CGPoint(
            x: min(max(x, screen.minX), max(screen.maxX - size.width, screen.minX)),
            y: min(max(y, screen.minY), max(screen.maxY - size.height, screen.minY)))
    }
}
