import Foundation

/// Why a cycle failed, in the plain words of docs/SYNC.md, "The UI and status
/// messages".
public enum SyncFailure: Sendable, Equatable {
    case unreachable
    case unauthorized
    case keyMismatch
    case updateRequired
    case other(String)

    public init(_ error: any Error) {
        switch error as? SyncEngineError {
        case .unreachable?: self = .unreachable
        case .unauthorized?: self = .unauthorized
        case .keyMismatch?: self = .keyMismatch
        case .updateRequired?: self = .updateRequired
        default: self = .other((error as? SyncEngineError)?.description ?? error.localizedDescription)
        }
    }

    /// For the settings window.
    public var detail: String {
        switch self {
        case .unreachable: SyncEngineError.unreachable.description
        case .unauthorized: SyncEngineError.unauthorized.description
        case .keyMismatch: SyncEngineError.keyMismatch.description
        case .updateRequired: SyncEngineError.updateRequired.description
        case .other(let message): message
        }
    }

    /// For the status menu: "Sync paused: …".
    public var short: String {
        switch self {
        case .unreachable: "server unreachable"
        case .unauthorized: "token rejected"
        case .keyMismatch: "sync key doesn't match"
        case .updateRequired: "update Cortex on this Mac"
        case .other(let message): message
        }
    }
}

/// What the status menu and the settings window show. Errors appear only
/// there: no alerts, no notifications (docs/SYNC.md, "The UI and status messages").
public enum SyncStatus: Sendable, Equatable {
    /// Not set up, or switched off.
    case off
    /// On, and no cycle has finished yet.
    case waiting
    case syncing
    case synced(Date, sent: Int, received: Int)
    case failed(SyncFailure)

    /// The disabled line in the status menu; nil hides it.
    public func menuLine(lastSuccess: Date?, now: Date = .now) -> String? {
        switch self {
        case .off: nil
        case .waiting: lastSuccess.map { "Synced \(Self.age(since: $0, now: now))" } ?? "Not synced yet"
        case .syncing: "Syncing…"
        case .synced(let date, _, _): "Synced \(Self.age(since: date, now: now))"
        case .failed(let failure): "Sync paused: \(failure.short)"
        }
    }

    /// The status row of Settings → Sync.
    public func settingsLine(lastSuccess: Date?, now: Date = .now) -> String {
        switch self {
        case .off: return "Sync is off"
        case .waiting: return "Waiting for the first sync"
        case .syncing: return "Syncing…"
        case .synced(let date, let sent, let received):
            return "Last synced \(Self.time(date, now: now)) · \(sent) sent, \(received) received"
        case .failed(let failure):
            let last = lastSuccess.map { " · Last synced \(Self.time($0, now: now))" } ?? ""
            return failure.detail + last
        }
    }

    public static func age(since date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "just now"
        case ..<3_600: return "\(Int(seconds / 60)) min ago"
        case ..<86_400: return "\(Int(seconds / 3_600)) h ago"
        default: return "\(Int(seconds / 86_400)) d ago"
        }
    }

    private static func time(_ date: Date, now: Date) -> String {
        Calendar.current.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// How long to wait after failed cycles: 30 s, 1, 2, 5, 15, then 30 minutes
/// (docs/SYNC.md, "Scheduling"). A wake, a network change or "Sync Now" resets it.
public struct SyncBackoff: Sendable, Equatable {
    public static let delays: [TimeInterval] = [30, 60, 120, 300, 900, 1_800]

    public private(set) var failures = 0

    public init() {}

    /// The wait after one more failure.
    public mutating func nextDelay() -> TimeInterval {
        let delay = Self.delays[min(failures, Self.delays.count - 1)]
        failures += 1
        return delay
    }

    public mutating func reset() {
        failures = 0
    }
}
