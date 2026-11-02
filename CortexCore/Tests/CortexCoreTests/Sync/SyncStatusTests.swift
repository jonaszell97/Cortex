import Foundation
import Testing
import CortexCore

@Suite struct SyncStatusTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func backoffFollowsTheSchedule() {
        var backoff = SyncBackoff()
        let delays = (0..<8).map { _ in backoff.nextDelay() }
        #expect(delays == [30, 60, 120, 300, 900, 1_800, 1_800, 1_800])
        backoff.reset()
        #expect(backoff.failures == 0)
        #expect(backoff.nextDelay() == 30)
    }

    @Test func theMenuLineIsShortAndHiddenWhenOff() {
        #expect(SyncStatus.off.menuLine(lastSuccess: nil, now: now) == nil)
        #expect(SyncStatus.syncing.menuLine(lastSuccess: nil, now: now) == "Syncing…")
        #expect(SyncStatus.waiting.menuLine(lastSuccess: nil, now: now) == "Not synced yet")
        #expect(SyncStatus.synced(now.addingTimeInterval(-20), sent: 0, received: 0).menuLine(lastSuccess: nil, now: now) == "Synced just now")
        #expect(SyncStatus.synced(now.addingTimeInterval(-180), sent: 0, received: 0).menuLine(lastSuccess: nil, now: now) == "Synced 3 min ago")
        #expect(SyncStatus.synced(now.addingTimeInterval(-7_300), sent: 0, received: 0).menuLine(lastSuccess: nil, now: now) == "Synced 2 h ago")
        #expect(SyncStatus.synced(now.addingTimeInterval(-3 * 86_400), sent: 0, received: 0).menuLine(lastSuccess: nil, now: now) == "Synced 3 d ago")
        #expect(SyncStatus.failed(.unreachable).menuLine(lastSuccess: now, now: now) == "Sync paused: server unreachable")
    }

    @Test func failuresUseThePlainWordsOfThePlan() {
        #expect(SyncFailure(SyncEngineError.unreachable).detail == "Server unreachable — check your network or VPN")
        #expect(SyncFailure(SyncEngineError.unauthorized).detail == "Token rejected")
        #expect(SyncFailure(SyncEngineError.keyMismatch).detail == "Sync key doesn't match")
        #expect(SyncFailure(SyncEngineError.updateRequired).detail == "Update Cortex on this Mac")
        #expect(SyncFailure(SyncEngineError.server(status: 500)) == .other("The sync server answered 500"))
        #expect(SyncFailure(SyncEngineError.keyMismatch) == .keyMismatch)
    }

    @Test func theSettingsLineCountsWhatMoved() {
        let line = SyncStatus.synced(now, sent: 3, received: 7).settingsLine(lastSuccess: now, now: now)
        #expect(line.hasPrefix("Last synced ") && line.hasSuffix("· 3 sent, 7 received"))
        let failed = SyncStatus.failed(.unauthorized).settingsLine(lastSuccess: now, now: now)
        #expect(failed.hasPrefix("Token rejected · Last synced "))
        #expect(SyncStatus.failed(.unauthorized).settingsLine(lastSuccess: nil, now: now) == "Token rejected")
    }
}
