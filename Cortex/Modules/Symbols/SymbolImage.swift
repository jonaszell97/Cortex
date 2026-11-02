import AppKit

/// An SF Symbol as a picture, for pasting into apps that know no symbol names.
enum SymbolImage {
    /// A black silhouette as PNG with a transparent background, `pointSize`
    /// high (a symbol is about as wide as it is high). Multicolor symbols
    /// lose their colours. nil for a name the system does not know.
    @MainActor
    static func png(for name: String, pointSize: CGFloat = 256) -> Data? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil),
              let symbol = base.withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular))
        else { return nil }
        let width = Int(symbol.size.width.rounded(.up))
        let height = Int(symbol.size.height.rounded(.up))
        guard width > 0, height > 0,
              let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap)
        else { return nil }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        let rect = NSRect(x: 0, y: 0, width: width, height: height)
        symbol.draw(in: rect)
        // The symbol is a template image; paint what was drawn black.
        NSColor.black.setFill()
        rect.fill(using: .sourceIn)
        return bitmap.representation(using: .png, properties: [:])
    }
}
