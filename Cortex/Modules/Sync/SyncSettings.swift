import Foundation
import CortexCore

/// Sync preferences, stored in UserDefaults (none of them are secret; the
/// token and the sync key are in the Keychain). Whether sync runs at all is
/// the Sync module's switch, off by default (docs/SYNC.md, "Design rules");
/// before modules it was "syncEnabled", which the switch still reads until it is
/// first set. What a collection sends besides its switch (sensitive clips, the
/// size cap) is the contributing module's setting.
@MainActor
@Observable
final class SyncSettings {
    private enum Key {
        static let serverURL = "syncServerURL"
    }

    @ObservationIgnored private let defaults: UserDefaults
    /// Bumped when a collection's switch changes, so readers are told.
    private var switches = 0

    var serverURL: URL? {
        didSet { defaults.set(serverURL?.absoluteString, forKey: Key.serverURL) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        serverURL = defaults.string(forKey: Key.serverURL).flatMap(URL.init(string:))
    }

    /// Whether a contribution's records are synced; on until switched off.
    func isSyncing(_ toggleKey: String) -> Bool {
        _ = switches
        return defaults.object(forKey: toggleKey) as? Bool ?? true
    }

    func setSyncing(_ toggleKey: String, _ isOn: Bool) {
        defaults.set(isOn, forKey: toggleKey)
        switches += 1
    }

    /// The switch and option values of a contribution, as they are now.
    func filterValues(of contribution: SyncContribution) -> SyncFilterValues {
        SyncFilterValues(isOn: isSyncing(contribution.toggleKey), options: contribution.options)
    }
}
