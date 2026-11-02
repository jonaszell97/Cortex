import Foundation

/// How the palette looks.
enum PaletteStyle: String, CaseIterable, Identifiable, Sendable {
    /// A plain glass panel with the system accent colour, like most clipboard managers.
    case classic
    /// A frosted pane tinted with the app icon's indigo, purple and amber.
    case glass

    var id: Self { self }

    var title: String {
        switch self {
        case .classic: "Classic"
        case .glass: "Liquid Glass"
        }
    }
}

/// Palette preferences, stored in UserDefaults on this Mac.
@MainActor
@Observable
final class PaletteSettings {
    private enum Key {
        static let style = "paletteStyle"
        static let position = "palettePosition"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var style: PaletteStyle { didSet { defaults.set(style.rawValue, forKey: Key.style) } }
    /// Where the palette was dragged to, as its centre relative to the screen
    /// (see `PanelPlacement`). Nil keeps it in the middle of the screen.
    var position: CGPoint? {
        didSet {
            if let position {
                defaults.set([position.x, position.y], forKey: Key.position)
            } else {
                defaults.removeObject(forKey: Key.position)
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        style = defaults.string(forKey: Key.style).flatMap(PaletteStyle.init(rawValue:)) ?? .classic
        if let saved = defaults.array(forKey: Key.position) as? [Double], saved.count == 2 {
            position = CGPoint(x: saved[0], y: saved[1])
        }
    }
}
