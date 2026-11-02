import Foundation

/// How often and how recently emoji or symbols were used: the "frequently
/// used" row and the tie-break in search. Each use adds one point; points halve
/// every 30 days, so one used a lot long ago gives way to one used lately.
public struct UsageRanking: Codable, Sendable, Equatable {
    struct Record: Codable, Sendable, Equatable {
        var score: Double
        var lastUsed: Date
    }

    public static let halfLife: TimeInterval = 30 * 86_400
    /// Records kept; the lowest scoring ones are dropped beyond this.
    static let maxRecords = 120

    private var records: [String: Record] = [:]

    public init() {}

    public var isEmpty: Bool { records.isEmpty }

    public func score(of emoji: String, now: Date = .now) -> Double {
        records[emoji].map { Self.decayed($0, to: now) } ?? 0
    }

    public mutating func recordUse(of emoji: String, now: Date = .now) {
        let used = Record(score: score(of: emoji, now: now) + 1, lastUsed: now)
        records[emoji] = used
        guard records.count > Self.maxRecords else { return }
        // The one just used always stays, or a new one could never build up
        // uses once the others all score higher.
        records[emoji] = nil
        let keep = records.sorted { Self.decayed($0.value, to: now) > Self.decayed($1.value, to: now) }
            .prefix(Self.maxRecords - 1)
        records = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        records[emoji] = used
    }

    /// The emoji used most, best first.
    public func top(_ count: Int, now: Date = .now) -> [String] {
        records
            .map { ($0.key, Self.decayed($0.value, to: now)) }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
            .prefix(count)
            .map(\.0)
    }

    private static func decayed(_ record: Record, to now: Date) -> Double {
        let age = max(0, now.timeIntervalSince(record.lastUsed))
        return record.score * pow(0.5, age / halfLife)
    }
}
