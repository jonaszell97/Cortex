import Foundation

/// Waits on the server for records this device hasn't pulled yet
/// (docs/SYNC.md, "Waiting for changes"), so another device's change starts a
/// cycle here within seconds instead of at the next periodic one. It only
/// watches: the cycle it asks for does the pulling.
public enum SyncChangeWaiter {
    /// How long one request waits: well below what proxies allow a request.
    public static let seconds = 25

    /// Returns true once there is something to pull (records after the
    /// cursor, or a new epoch), and false when the server can't wait for
    /// changes or a request fails. Quiet answers are asked again with the
    /// cursor as it is then. Ends with false when the task is cancelled.
    public static func wait(
        transport: any SyncTransport, database: AppDatabase, seconds: Int = seconds
    ) async -> Bool {
        do {
            let health = try await transport.health()
            guard let maxWait = health.maxWait, maxWait > 0 else { return false }
            let wait = min(seconds, maxWait)
            while !Task.isCancelled {
                let state = try database.syncState()
                guard state.epoch == health.epoch else { return true }
                let start = ContinuousClock.now
                let page = try await transport.changes(since: state.cursor, limit: 1, wait: wait)
                if page.epoch != health.epoch || !page.records.isEmpty { return true }
                // A quiet answer long before the wait is up: something on the
                // way doesn't hold requests. Asking again would never stop.
                if ContinuousClock.now - start < .seconds(wait) / 2 {
                    Log.sync.notice("The sync server answered a waiting request at once; not waiting for changes")
                    return false
                }
            }
        } catch is CancellationError {
        } catch {
            Log.sync.info("Stopped waiting for changes: \(String(describing: error), privacy: .public)")
        }
        return false
    }
}
