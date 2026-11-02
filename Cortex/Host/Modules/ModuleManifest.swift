import Foundation

/// Stable forever: the enabled flag, option keys and usage data are stored
/// under it. Lowercase, no dots: "clipboard", "snippets", "emoji".
struct ModuleID: Hashable, Sendable, RawRepresentable, ExpressibleByStringLiteral, CustomStringConvertible {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(stringLiteral value: String) {
        rawValue = value
    }

    var description: String { rawValue }

    /// Lowercase letters, digits and hyphens, starting with a letter.
    var isWellFormed: Bool {
        guard let first = rawValue.unicodeScalars.first, ("a"..."z").contains(first) else { return false }
        return rawValue.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }
}

enum PaletteTrigger: Equatable, Sendable {
    /// Shown when the query has no trigger. Exactly one module (Clipboard).
    case `default`
    /// The query starts with this. The longest match wins, so `::` beats `:`.
    case prefix(String)
}

enum ModuleRequirement: Hashable, Sendable, CustomStringConvertible {
    case database
    /// Another module that has to be on (AI needs Quick Actions).
    case module(ModuleID)

    var description: String {
        switch self {
        case .database: "Needs the database"
        case .module(let id): "Needs the \(id) module"
        }
    }
}

enum ModulePermission: Hashable, Sendable {
    /// Pasting, event taps.
    case accessibility
    /// Reading the Finder selection.
    case finderAutomation
    /// Capturing the screen (reading text in a region of it).
    case screenRecording
}

/// A further palette scope of a module under a trigger of its own, such as
/// Knowledge's `!` for to-dos next to its `?`. The module returns the scope
/// from `palette(_:)`.
struct PaletteSubscope: Sendable, Equatable {
    /// The route's ID, which `PaletteHost.open(_:)` takes; distinct from
    /// every module's ID ("todos").
    let id: ModuleID
    let trigger: String
    /// Its part of the search placeholder: "todos" becomes "!todos".
    let placeholder: String?
}

/// Everything the host needs to know about a module without starting it.
struct ModuleManifest: Sendable {
    let id: ModuleID
    /// "Snippets"
    let name: String
    /// One sentence for Settings.
    let summary: String
    /// SF Symbol for the Settings sidebar.
    let symbol: String
    /// nil: the module does not appear in the palette (Scrolling, Sync).
    let trigger: PaletteTrigger?
    /// The module's part of the search placeholder: "snippets" becomes ";snippets".
    let placeholder: String?
    /// More scopes under their own triggers, after the module's own in the
    /// placeholder.
    let subscopes: [PaletteSubscope]
    let enabledByDefault: Bool
    /// A switch the feature had before modules: while the module's own switch
    /// was never set, this key's value says whether it is enabled
    /// ("scrollReversal", "syncEnabled").
    let legacyEnabledKey: String?
    /// Without these the module cannot run; Settings shows it switched off with the reason.
    let requirements: Set<ModuleRequirement>
    /// Asked for during onboarding and shown in Settings → Permissions while enabled.
    let permissions: Set<ModulePermission>
    /// Position in Settings, the placeholder and the status menu.
    let order: Int

    init(
        id: ModuleID, name: String, summary: String, symbol: String,
        trigger: PaletteTrigger? = nil, placeholder: String? = nil, subscopes: [PaletteSubscope] = [],
        enabledByDefault: Bool = true, legacyEnabledKey: String? = nil, requirements: Set<ModuleRequirement> = [],
        permissions: Set<ModulePermission> = [], order: Int
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.symbol = symbol
        self.trigger = trigger
        self.placeholder = placeholder
        self.subscopes = subscopes
        self.enabledByDefault = enabledByDefault
        self.legacyEnabledKey = legacyEnabledKey
        self.requirements = requirements
        self.permissions = permissions
        self.order = order
    }

    /// What is wrong with a set of manifests: malformed or duplicate IDs,
    /// duplicate or empty triggers, not exactly one default module, and
    /// requirements on modules that do not exist. Empty when all is well.
    static func problems(in manifests: [ModuleManifest]) -> [String] {
        var problems: [String] = []
        var seenIDs: Set<ModuleID> = []
        var prefixes: [String: ModuleID] = [:]
        var defaults: [ModuleID] = []
        var seenSubscopes: Set<ModuleID> = []
        let ids = Set(manifests.map(\.id))

        for manifest in manifests {
            let id = manifest.id
            if !id.isWellFormed {
                problems.append("Module ID \"\(id)\" is not lowercase letters, digits and hyphens")
            }
            if !seenIDs.insert(id).inserted {
                problems.append("Module ID \"\(id)\" is used twice")
            }
            switch manifest.trigger {
            case .default:
                defaults.append(id)
            case .prefix(let prefix) where prefix.isEmpty:
                problems.append("Module \"\(id)\" has an empty trigger")
            case .prefix(let prefix):
                if let other = prefixes[prefix] {
                    problems.append("Modules \"\(other)\" and \"\(id)\" both use the trigger \"\(prefix)\"")
                } else {
                    prefixes[prefix] = id
                }
            case nil:
                break
            }
            for subscope in manifest.subscopes {
                if !subscope.id.isWellFormed {
                    problems.append("Scope ID \"\(subscope.id)\" of \"\(id)\" is not lowercase letters, digits and hyphens")
                }
                if ids.contains(subscope.id) || !seenSubscopes.insert(subscope.id).inserted {
                    problems.append("Scope ID \"\(subscope.id)\" of \"\(id)\" is used twice")
                }
                if subscope.trigger.isEmpty {
                    problems.append("Module \"\(id)\" has a scope with an empty trigger")
                } else if let other = prefixes[subscope.trigger] {
                    problems.append("Modules \"\(other)\" and \"\(id)\" both use the trigger \"\(subscope.trigger)\"")
                } else {
                    prefixes[subscope.trigger] = id
                }
            }
            for case .module(let required) in manifest.requirements {
                if required == id {
                    problems.append("Module \"\(id)\" requires itself")
                } else if !ids.contains(required) {
                    problems.append("Module \"\(id)\" requires the unknown module \"\(required)\"")
                }
            }
        }
        if defaults.count != 1 {
            let names = defaults.map { "\"\($0)\"" }.joined(separator: ", ")
            problems.append("Exactly one module must be the palette's default, not \(defaults.isEmpty ? "none" : names)")
        }
        return problems
    }
}
