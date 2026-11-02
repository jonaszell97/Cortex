import Foundation
import Testing
@testable import Cortex
import CortexCore

@MainActor
@Suite struct SyncSettingsTests {
    let suiteName = "CortexTests-\(UUID().uuidString)"
    var defaults: UserDefaults { UserDefaults(suiteName: suiteName)! }

    @Test func everyCollectionSyncsUntilSwitchedOff() {
        let settings = SyncSettings(defaults: defaults)
        #expect(settings.serverURL == nil)
        #expect(settings.isSyncing("syncClips") && settings.isSyncing("syncSnippets") && settings.isSyncing("syncActions"))
        #expect(settings.isSyncing("syncReadingList") && settings.isSyncing("syncKnowledge"))
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func changesPersistUnderTheOldKeys() {
        let settings = SyncSettings(defaults: defaults)
        settings.serverURL = URL(string: "https://cortex-sync.example.dev")
        settings.setSyncing("syncSnippets", false)

        #expect(defaults.string(forKey: "syncServerURL") == "https://cortex-sync.example.dev")
        #expect(defaults.object(forKey: "syncSnippets") as? Bool == false)
        let reloaded = SyncSettings(defaults: defaults)
        #expect(reloaded.serverURL?.absoluteString == "https://cortex-sync.example.dev")
        #expect(!reloaded.isSyncing("syncSnippets") && reloaded.isSyncing("syncClips"))
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func filterValuesAreTheSwitchAndTheOptions() throws {
        let database = try makeTestDatabase()
        let clipboard = ClipboardService(database: database, settings: ClipboardSettings(defaults: defaults))
        let clips = ClipboardModule.syncContribution(for: clipboard)
        let settings = SyncSettings(defaults: defaults)
        #expect(settings.filterValues(of: clips) == SyncFilterValues(
            isOn: true, toggles: ["sensitive": false], integers: ["maxClipMB": 10]))

        clipboard.settings.syncSensitive = true
        clipboard.settings.syncMaxClipMB = 25
        settings.setSyncing("syncClips", false)
        #expect(settings.filterValues(of: clips) == SyncFilterValues(
            isOn: false, toggles: ["sensitive": true], integers: ["maxClipMB": 25]))
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func widerFiltersRestartTheirCollection() throws {
        let database = try makeTestDatabase()
        let clips = ClipboardModule.syncContribution(
            for: ClipboardService(database: database, settings: ClipboardSettings(defaults: defaults)))
        let snippets = SnippetsModule.syncContribution(
            for: SnippetsService(database: database, settings: SnippetsSettings(defaults: defaults)))
        func restarts(_ contribution: SyncContribution, _ old: SyncFilterValues, _ new: SyncFilterValues) -> Bool {
            SyncFilterValues.needsRestart(contribution, from: old, to: new)
        }
        let base = SyncFilterValues(isOn: true, toggles: ["sensitive": false], integers: ["maxClipMB": 10])

        var change = base
        change.toggles["sensitive"] = true
        #expect(restarts(clips, base, change))
        change = base
        change.integers["maxClipMB"] = 20
        #expect(restarts(clips, base, change))

        // Narrower filters have nothing new to pull or send.
        var narrow = base
        narrow.integers["maxClipMB"] = 5
        #expect(!restarts(clips, base, narrow))
        narrow.isOn = false
        #expect(!restarts(clips, base, narrow))

        // A collection switched back on.
        var off = base
        off.isOn = false
        #expect(restarts(clips, off, base))
        #expect(restarts(snippets, SyncFilterValues(isOn: false), SyncFilterValues(isOn: true)))
        #expect(!restarts(snippets, SyncFilterValues(isOn: true), SyncFilterValues(isOn: true)))
        // Sensitive on while clips are off restarts nothing yet.
        var sensitiveOnly = off
        sensitiveOnly.toggles["sensitive"] = true
        #expect(!restarts(clips, off, sensitiveOnly))
        defaults.removePersistentDomain(forName: suiteName)
    }
}
