import Foundation
import Testing
@testable import Cortex
import CortexCore

@MainActor
@Suite struct ClipboardSettingsTests {
    let suiteName = "CortexTests-\(UUID().uuidString)"
    var defaults: UserDefaults { UserDefaults(suiteName: suiteName)! }

    @Test func defaultsMatchTheRoadmap() {
        let settings = ClipboardSettings(defaults: defaults)
        #expect(settings.retentionDays == 30)
        #expect(settings.retentionMaxItems == 2_000)
        #expect(settings.sensitiveRetentionDays == 0)
        #expect(settings.indexSensitiveText)
        #expect(settings.detectSensitiveText)
        #expect(!settings.pastePlainByDefault)
        #expect(settings.ignoredBundleIDs.isEmpty)
        #expect(!settings.isPaused)
        #expect(settings.recognizeImageText)
        #expect(settings.retentionPolicy == RetentionPolicy(maxAge: 30 * 86_400, maxCount: 2_000, sensitiveMaxAge: nil))
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func zeroMeansNoLimit() {
        let settings = ClipboardSettings(defaults: defaults)
        settings.retentionDays = 0
        settings.retentionMaxItems = 0
        settings.sensitiveRetentionDays = 7
        #expect(settings.retentionPolicy == RetentionPolicy(maxAge: nil, maxCount: nil, sensitiveMaxAge: 7 * 86_400))
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func changesPersist() {
        let settings = ClipboardSettings(defaults: defaults)
        settings.isPaused = true
        settings.ignoredBundleIDs = ["com.apple.TextEdit"]
        settings.pastePlainByDefault = true
        settings.detectSensitiveText = false
        settings.recognizeImageText = false

        let reloaded = ClipboardSettings(defaults: defaults)
        #expect(reloaded.isPaused)
        #expect(reloaded.ignoredBundleIDs == ["com.apple.TextEdit"])
        #expect(reloaded.pastePlainByDefault)
        #expect(reloaded.recordingOptions.ignoredBundleIDs == ["com.apple.TextEdit"])
        #expect(!reloaded.recordingOptions.detectSensitiveText)
        #expect(!reloaded.imageTextOptions.isEnabled && !reloaded.imageTextOptions.detectSensitiveText)
        #expect(defaults.object(forKey: "recognizeImageText") as? Bool == false)
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - Sync

    @Test func syncKeepsSensitiveClipsHereAndCapsTheSize() {
        let settings = ClipboardSettings(defaults: defaults)
        #expect(!settings.syncSensitive && settings.syncMaxClipMB == 10)
        settings.syncSensitive = true
        settings.syncMaxClipMB = 25
        let reloaded = ClipboardSettings(defaults: defaults)
        #expect(reloaded.syncSensitive && reloaded.syncMaxClipMB == 25)
        // The keys from before the Clipboard module owned them.
        #expect(defaults.bool(forKey: "syncSensitiveClips") && defaults.integer(forKey: "syncMaxClipMB") == 25)
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func theSyncSizeCapStaysInRange() {
        let settings = ClipboardSettings(defaults: defaults)
        settings.syncMaxClipMB = 0
        #expect(settings.syncMaxClipMB == 1)
        settings.syncMaxClipMB = 5_000
        #expect(settings.syncMaxClipMB == ClipboardSettings.syncMaxClipMBRange.upperBound)
        #expect(ClipboardSettings(defaults: defaults).syncMaxClipMB == ClipboardSettings.syncMaxClipMBRange.upperBound)
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func clipSyncOptionsCombineSyncAndRetentionSettings() {
        let settings = ClipboardSettings(defaults: defaults)
        settings.syncSensitive = true
        settings.syncMaxClipMB = 2
        settings.retentionDays = 1
        settings.retentionMaxItems = 0
        #expect(settings.clipSyncOptions == ClipSyncOptions(
            syncSensitive: true, maxClipBytes: 2 * 1024 * 1024, indexSensitive: true,
            retention: RetentionPolicy(maxAge: 86_400, maxCount: nil)))
        defaults.removePersistentDomain(forName: suiteName)
    }
}
