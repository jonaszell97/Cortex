import Foundation
import CortexCore

/// Clipboard preferences, stored in UserDefaults (none of them are secret).
@MainActor
@Observable
final class ClipboardSettings {
    private enum Key {
        static let retentionDays = "retentionDays"
        static let retentionMaxItems = "retentionMaxItems"
        static let sensitiveRetentionDays = "sensitiveRetentionDays"
        static let indexSensitiveText = "indexSensitiveText"
        static let detectSensitiveText = "detectSensitiveText"
        static let recognizeImageText = "recognizeImageText"
        static let pastePlainByDefault = "pastePlainByDefault"
        static let ignoredBundleIDs = "ignoredBundleIDs"
        static let isPaused = "isRecordingPaused"
        static let syncSensitive = "syncSensitiveClips"
        static let syncMaxClipMB = "syncMaxClipMB"
    }

    /// Items above this size are not recorded.
    nonisolated static let maxItemBytes = 25 * 1024 * 1024
    /// Capped below the sync server's 32 MB blob limit: a clip it refuses
    /// would be read and sealed again on every cycle.
    static let syncMaxClipMBRange = 1...30

    @ObservationIgnored private let defaults: UserDefaults

    /// 0 keeps items regardless of age.
    var retentionDays: Int { didSet { defaults.set(retentionDays, forKey: Key.retentionDays) } }
    /// 0 keeps any number of items.
    var retentionMaxItems: Int { didSet { defaults.set(retentionMaxItems, forKey: Key.retentionMaxItems) } }
    /// 0 means the same as `retentionDays`.
    var sensitiveRetentionDays: Int { didSet { defaults.set(sensitiveRetentionDays, forKey: Key.sensitiveRetentionDays) } }
    var indexSensitiveText: Bool { didSet { defaults.set(indexSensitiveText, forKey: Key.indexSensitiveText) } }
    /// Flags text that looks like a secret (`SensitiveTextDetector`) even
    /// when the app that copied it did not mark it.
    var detectSensitiveText: Bool { didSet { defaults.set(detectSensitiveText, forKey: Key.detectSensitiveText) } }
    /// Reads the text in image clips, so search finds screenshots by it
    /// (`ImageTextIndexer`).
    var recognizeImageText: Bool { didSet { defaults.set(recognizeImageText, forKey: Key.recognizeImageText) } }
    /// Swaps ⏎ and ⇧⏎.
    var pastePlainByDefault: Bool { didSet { defaults.set(pastePlainByDefault, forKey: Key.pastePlainByDefault) } }
    var ignoredBundleIDs: [String] { didSet { defaults.set(ignoredBundleIDs, forKey: Key.ignoredBundleIDs) } }
    var isPaused: Bool { didSet { defaults.set(isPaused, forKey: Key.isPaused) } }
    /// Sensitive clips travel only when this is on, on both Macs (docs/SYNC.md,
    /// "What syncs and what stays local").
    var syncSensitive: Bool { didSet { defaults.set(syncSensitive, forKey: Key.syncSensitive) } }
    /// Larger clips stay on this Mac, and arriving ones are ignored.
    var syncMaxClipMB: Int {
        didSet {
            let clamped = min(max(syncMaxClipMB, Self.syncMaxClipMBRange.lowerBound), Self.syncMaxClipMBRange.upperBound)
            if clamped != syncMaxClipMB { syncMaxClipMB = clamped }
            defaults.set(syncMaxClipMB, forKey: Key.syncMaxClipMB)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.retentionDays: 30,
            Key.retentionMaxItems: 2_000,
            Key.sensitiveRetentionDays: 0,
            Key.indexSensitiveText: true,
            Key.detectSensitiveText: true,
            Key.recognizeImageText: true,
            Key.pastePlainByDefault: false,
            Key.ignoredBundleIDs: [String](),
            Key.isPaused: false,
            Key.syncSensitive: false,
            Key.syncMaxClipMB: 10,
        ])
        retentionDays = defaults.integer(forKey: Key.retentionDays)
        retentionMaxItems = defaults.integer(forKey: Key.retentionMaxItems)
        sensitiveRetentionDays = defaults.integer(forKey: Key.sensitiveRetentionDays)
        indexSensitiveText = defaults.bool(forKey: Key.indexSensitiveText)
        detectSensitiveText = defaults.bool(forKey: Key.detectSensitiveText)
        recognizeImageText = defaults.bool(forKey: Key.recognizeImageText)
        pastePlainByDefault = defaults.bool(forKey: Key.pastePlainByDefault)
        ignoredBundleIDs = defaults.stringArray(forKey: Key.ignoredBundleIDs) ?? []
        isPaused = defaults.bool(forKey: Key.isPaused)
        syncSensitive = defaults.bool(forKey: Key.syncSensitive)
        let size = defaults.integer(forKey: Key.syncMaxClipMB)
        syncMaxClipMB = min(max(size, Self.syncMaxClipMBRange.lowerBound), Self.syncMaxClipMBRange.upperBound)
    }

    var retentionPolicy: RetentionPolicy {
        let day: TimeInterval = 86_400
        return RetentionPolicy(
            maxAge: retentionDays > 0 ? Double(retentionDays) * day : nil,
            maxCount: retentionMaxItems > 0 ? retentionMaxItems : nil,
            sensitiveMaxAge: sensitiveRetentionDays > 0 ? Double(sensitiveRetentionDays) * day : nil)
    }

    /// What the sync handler gets: the sync settings plus the ones that
    /// decide what a clip arriving here may do.
    var clipSyncOptions: ClipSyncOptions {
        ClipSyncOptions(
            syncSensitive: syncSensitive, maxClipBytes: syncMaxClipMB * 1024 * 1024,
            indexSensitive: indexSensitiveText, retention: retentionPolicy)
    }

    /// What the pasteboard monitor needs, as a value it can take off the main actor.
    struct RecordingOptions: Sendable {
        var isPaused: Bool
        var ignoredBundleIDs: Set<String>
        var indexSensitiveText: Bool
        var detectSensitiveText: Bool
    }

    var recordingOptions: RecordingOptions {
        RecordingOptions(
            isPaused: isPaused, ignoredBundleIDs: Set(ignoredBundleIDs),
            indexSensitiveText: indexSensitiveText, detectSensitiveText: detectSensitiveText)
    }

    var imageTextOptions: ImageTextIndexer.Options {
        ImageTextIndexer.Options(
            isEnabled: recognizeImageText, indexSensitiveText: indexSensitiveText,
            detectSensitiveText: detectSensitiveText)
    }
}
