import Foundation
import CortexCore

/// A module whose data Sync carries between Macs. Sync asks the active
/// modules for their contributions whenever it needs them, so a module that
/// is switched off is neither sent nor applied, and Sync names no module.
@MainActor
protocol SyncContributing: AnyObject {
    var syncContributions: [SyncContribution] { get }
}

/// One kind of record a module syncs, and what Sync needs to carry it.
struct SyncContribution: Identifiable {
    /// The wire format's collection (CortexCore).
    let collection: SyncCollection
    /// Its switch in Settings → Sync: "Clipboard history".
    let title: String
    /// Where that switch is stored ("syncClips"); on until switched off.
    let toggleKey: String
    /// Settings of this collection's sync, shown below its switch and greyed
    /// out while it is off.
    var options: [ModuleOption] = []
    /// A handler for one cycle, with the settings as they are now.
    let makeHandler: @MainActor () -> any SyncEntityHandler
    /// Whether changed option values let in records the old ones kept back
    /// (sensitive clips allowed, a larger size cap): the collection's rows
    /// are then offered again and its older records pulled again. A switch
    /// turned on always does that.
    var needsRestart: (_ old: SyncFilterValues, _ new: SyncFilterValues) -> Bool = { _, _ in false }
    /// A folder whose changes call for a cycle, for records without pending
    /// rows in the database (action files).
    var watchedFolder: URL?
    /// Awaited before the first cycle after Sync starts (the clipboard's
    /// orphan sweep and purge).
    var waitUntilReady: @MainActor () async -> Void = {}
    /// A cycle wrote remote records: reload what shows them.
    var didApplyRemoteChanges: @MainActor () -> Void = {}

    var id: SyncCollection { collection }
}

/// A contribution's switch and the values of its options, by option ID, as
/// Sync last applied them. Toggles and integers count; other kinds of option
/// do not decide what is sent.
struct SyncFilterValues: Equatable {
    var isOn: Bool
    var toggles: [String: Bool] = [:]
    var integers: [String: Int] = [:]

    init(isOn: Bool, toggles: [String: Bool] = [:], integers: [String: Int] = [:]) {
        self.isOn = isOn
        self.toggles = toggles
        self.integers = integers
    }

    @MainActor
    init(isOn: Bool, options: [ModuleOption]) {
        self.isOn = isOn
        for option in options {
            switch option.kind {
            case .toggle(let value): toggles[option.id] = value.wrappedValue
            case .integer(let value, _, _): integers[option.id] = value.wrappedValue
            default: break
            }
        }
    }

    /// Whether going from `old` to `new` lets in records that were kept
    /// back: the switch turned on, or, while on, the contribution says so.
    static func needsRestart(_ contribution: SyncContribution, from old: Self, to new: Self) -> Bool {
        new.isOn && (!old.isOn || contribution.needsRestart(old, new))
    }
}
