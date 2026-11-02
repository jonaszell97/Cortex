import Foundation

// The sync protocol as Swift types (docs/SYNC.md, "Server API"). `SyncAPI` speaks
// it over HTTP; the tests speak it to `InMemorySyncServer`. The engine only sees
// `SyncTransport`.

/// A record as the server sees it. `seq` is set on records that were pulled.
public struct SyncWireRecord: Codable, Sendable, Equatable {
    /// The server's collection name. A String, not `SyncCollection`, so a
    /// collection added by a newer build is skipped instead of failing the page.
    public var collection: String
    public var id: String
    public var seq: Int64?
    public var modifiedAt: Int64
    public var device: String
    public var deleted: Bool
    public var keep: Bool
    public var blobs: [String]
    /// The sealed payload; nil for a tombstone.
    public var payload: Data?

    public init(
        collection: SyncCollection, id: String, seq: Int64? = nil, modifiedAt: Int64, device: String,
        deleted: Bool, keep: Bool = false, blobs: [String] = [], payload: Data?
    ) {
        self.collection = collection.rawValue
        self.id = id
        self.seq = seq
        self.modifiedAt = modifiedAt
        self.device = device
        self.deleted = deleted
        self.keep = keep
        self.blobs = blobs
        self.payload = payload
    }

    public var syncCollection: SyncCollection? { SyncCollection(rawValue: collection) }

    private enum CodingKeys: String, CodingKey {
        case collection, id, seq, modifiedAt, device, deleted, keep, blobs, payload
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        collection = try c.decode(String.self, forKey: .collection)
        id = try c.decode(String.self, forKey: .id)
        seq = try c.decodeIfPresent(Int64.self, forKey: .seq)
        modifiedAt = try c.decode(Int64.self, forKey: .modifiedAt)
        device = try c.decode(String.self, forKey: .device)
        deleted = try c.decode(Bool.self, forKey: .deleted)
        keep = try c.decodeIfPresent(Bool.self, forKey: .keep) ?? false
        blobs = try c.decodeIfPresent([String].self, forKey: .blobs) ?? []
        payload = try c.decodeIfPresent(Data.self, forKey: .payload)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(collection, forKey: .collection)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(seq, forKey: .seq)
        try c.encode(modifiedAt, forKey: .modifiedAt)
        try c.encode(device, forKey: .device)
        try c.encode(deleted, forKey: .deleted)
        try c.encode(keep, forKey: .keep)
        try c.encode(blobs, forKey: .blobs)
        // The server requires the key, with null for a tombstone.
        try c.encode(payload, forKey: .payload)
    }
}

public struct SyncHealth: Codable, Sendable, Equatable {
    public var status: String
    public var epoch: String
    /// How long `/v1/changes` can wait for a push, in seconds; nil from a
    /// server that can't (docs/SYNC.md, "Waiting for changes").
    public var maxWait: Int?

    public init(status: String, epoch: String, maxWait: Int? = nil) {
        self.status = status
        self.epoch = epoch
        self.maxWait = maxWait
    }
}

public struct SyncChangesPage: Codable, Sendable, Equatable {
    public var records: [SyncWireRecord]
    public var cursor: Int64
    public var more: Bool
    public var epoch: String

    public init(records: [SyncWireRecord], cursor: Int64, more: Bool, epoch: String) {
        self.records = records
        self.cursor = cursor
        self.more = more
        self.epoch = epoch
    }
}

public struct SyncPushResult: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case applied, stale }

    public var collection: String
    public var id: String
    public var status: Status
    public var seq: Int64

    public init(collection: String, id: String, status: Status, seq: Int64) {
        self.collection = collection
        self.id = id
        self.status = status
        self.seq = seq
    }
}

public struct SyncPushResponse: Codable, Sendable, Equatable {
    public var results: [SyncPushResult]
    public var epoch: String

    public init(results: [SyncPushResult], epoch: String) {
        self.results = results
        self.epoch = epoch
    }
}

public struct SyncMissingBlobs: Codable, Sendable, Equatable {
    public var missing: [String]
    public var epoch: String

    public init(missing: [String], epoch: String) {
        self.missing = missing
        self.epoch = epoch
    }
}

public struct SyncPutBlobResult: Codable, Sendable, Equatable {
    /// False: the blob existed already and the server kept its bytes.
    public var stored: Bool
    public var epoch: String

    public init(stored: Bool, epoch: String) {
        self.stored = stored
        self.epoch = epoch
    }
}

public struct SyncBlobDownload: Sendable, Equatable {
    public var data: Data
    public var epoch: String

    public init(data: Data, epoch: String) {
        self.data = data
        self.epoch = epoch
    }
}

public enum SyncTransportError: Error, Equatable, CustomStringConvertible {
    /// No answer: off the Tailnet, DNS, TLS, a timeout.
    case unreachable
    /// 401: the token is wrong.
    case unauthorized
    /// 413: the body was over the server's limit.
    case payloadTooLarge
    case server(status: Int)
    /// The answer isn't what the protocol says.
    case malformedResponse
    /// The answer is larger than this client accepts, and was not read.
    case responseTooLarge

    public var description: String {
        switch self {
        case .unreachable: "The sync server can't be reached."
        case .unauthorized: "The sync server rejected the token."
        case .payloadTooLarge: "The sync server refused a request as too large."
        case .server(let status): "The sync server answered \(status)."
        case .malformedResponse: "The sync server sent an unexpected answer."
        case .responseTooLarge: "The sync server sent a larger answer than expected."
        }
    }
}

/// The server's operations. Every response carries the server's epoch
/// (docs/SYNC.md, "The epoch"), which the engine checks on each one.
public protocol SyncTransport: Sendable {
    func health() async throws -> SyncHealth
    func changes(since cursor: Int64, limit: Int) async throws -> SyncChangesPage
    /// Like `changes(since:limit:)`, but when nothing is newer than `cursor`
    /// the server holds the answer up to `wait` seconds for a push. Only for a
    /// server whose health has `maxWait`.
    func changes(since cursor: Int64, limit: Int, wait: Int) async throws -> SyncChangesPage
    func push(device: String, records: [SyncWireRecord]) async throws -> SyncPushResponse
    func missingBlobs(_ ids: [String]) async throws -> SyncMissingBlobs
    func putBlob(id: String, data: Data) async throws -> SyncPutBlobResult
    /// The sealed bytes, or nil if the server has no such blob.
    func blob(id: String) async throws -> SyncBlobDownload?
}

extension SyncTransport {
    /// Transports that can't wait answer at once; `SyncChangeWaiter` notices
    /// that and stops asking.
    public func changes(since cursor: Int64, limit: Int, wait: Int) async throws -> SyncChangesPage {
        try await changes(since: cursor, limit: limit)
    }
}
