import Foundation

/// A module that hooks into the palette: its trigger, its part of the
/// placeholder and its scope.
struct PaletteRoute {
    let id: ModuleID
    let trigger: PaletteTrigger
    /// "snippets" becomes "; snippets" in the search placeholder.
    let placeholder: String?
    let scope: any PaletteScope
}

/// Which module a query goes to (docs/ARCHITECTURE.md, "Trigger resolution").
/// Pure, so it can be tested.
enum PaletteRouting {
    /// Escapes every trigger, present or future: `\;sig` searches the
    /// default module for `;sig`.
    static let escape: Character = "\\"

    /// 1. A query starting with `\` goes to the default module without the
    ///    backslash.
    /// 2. Otherwise the route with the longest matching prefix wins and gets
    ///    the query without it (`::` beats `:`).
    /// 3. Otherwise the default module gets the whole query.
    ///
    /// The route is nil when the default module is off and no trigger matches.
    static func resolve(_ query: String, in routes: [PaletteRoute]) -> (route: PaletteRoute?, text: String) {
        let defaultRoute = routes.first { $0.trigger == .default }
        if query.first == escape {
            return (defaultRoute, String(query.dropFirst()))
        }
        let matches = routes.compactMap { route -> (PaletteRoute, String)? in
            guard case .prefix(let prefix) = route.trigger, !prefix.isEmpty, query.hasPrefix(prefix) else { return nil }
            return (route, prefix)
        }
        if let (route, prefix) = matches.max(by: { $0.1.count < $1.1.count }) {
            return (route, String(query.dropFirst(prefix.count)))
        }
        return (defaultRoute, query)
    }

    /// "Search clipboard · ;snippets · +reading · >actions · :emoji", in
    /// route order. The separator is not a comma so a trigger such as `;`
    /// or `:` cannot be mistaken for punctuation.
    static func placeholder(for routes: [PaletteRoute]) -> String {
        let parts = routes.compactMap { route -> String? in
            guard let placeholder = route.placeholder else { return nil }
            switch route.trigger {
            case .default: return placeholder
            case .prefix(let prefix): return prefix + placeholder
            }
        }
        return "Search " + parts.joined(separator: " · ")
    }
}
