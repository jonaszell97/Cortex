import Foundation
import GRDB

/// What the engine needs from each kind of data (docs/SYNC.md, "Architecture"):
/// clips, snippets and action files each provide one (Steps 4 to 6). The engine
/// owns everything generic: cursor, epoch, sealing, last-writer-wins and the
/// `syncRecord` bookkeeping. The handler only turns local data into a payload and
/// a payload back into local data.
public protocol SyncEntityHandler: Sendable {
    /// `clip`, `snippet` or `action`: the `syncRecord.entity` this handler owns.
    var entity: SyncCollection { get }

    /// The highest payload `v` this build understands. A record with a higher
    /// one stops the pull ("update Cortex on this Mac", docs/SYNC.md, "Applying
    /// remote records").
    var supportedVersion: Int { get }

    /// Runs at the start of every cycle, before the pull. Actions scan their
    /// folder here (docs/SYNC.md, "The sync cycle", "Scan files").
    func beforeCycle(database: AppDatabase) async throws

    /// The payload for a pending, non-deleted row, or nil if the filters
    /// exclude it (a `files` clip, an oversized clip, a sensitive clip with
    /// sensitive sync off). A nil answer clears `pending` without a push.
    func outgoing(localKey: String, key: SyncKey, database: AppDatabase) async throws -> SyncOutgoing?

    /// Decodes a remote payload (JSON with a `v`), fetches the blobs it needs
    /// and returns what to write. Runs outside any transaction; the returned
    /// `apply` runs inside the page's write transaction.
    func prepare(payload: Data, blobs: SyncBlobSource) async throws -> SyncPreparedRecord

    /// Deletes the local data of `localKey` for a remote tombstone that is
    /// newer than the local write. Runs inside the page's write transaction.
    func applyDeletion(localKey: String, in db: Database) throws
}

extension SyncEntityHandler {
    public func beforeCycle(database: AppDatabase) async throws {}
}

/// A payload ready to seal: JSON that carries a `v`, the blobs it refers to
/// (by the IDs `SyncKey.blobID(for:)` gave them) and the `keep` flag.
public struct SyncOutgoing: Sendable {
    public struct Blob: Sendable {
        public var id: String
        public var plaintext: Data

        public init(id: String, plaintext: Data) {
            self.id = id
            self.plaintext = plaintext
        }
    }

    public var payload: Data
    public var blobs: [Blob]
    /// Exempt from server pruning (pinned clips).
    public var keep: Bool

    public init(payload: Data, blobs: [Blob] = [], keep: Bool = false) {
        self.payload = payload
        self.blobs = blobs
        self.keep = keep
    }
}

/// The remote write that is being applied: the version it carries.
public struct SyncRemoteWrite: Sendable, Equatable {
    public var modifiedAt: Int64
    public var device: String
}

public enum SyncApplyOutcome: Sendable, Equatable {
    case applied
    /// Stored, but the result differs from what the remote payload says: a
    /// clip whose `lastCopiedAt` is later here, a snippet that lost its
    /// keyword to a clash, a snippet adopted with local content. The engine
    /// records a new local write for it (later than the remote one, so it wins
    /// everywhere) and pushes it, which makes both Macs converge.
    case mergedLocally
    /// The handler chose not to store it (for example a clip that local
    /// retention would purge right away). The engine records nothing for it.
    case ignored
}

/// A remote record, decoded and ready to write.
public struct SyncPreparedRecord: Sendable {
    /// The record's `syncRecord.localKey` (clip: content hash, snippet:
    /// `syncID`, action: file name). It must hash to the record's ID, or the
    /// record is skipped.
    public var localKey: String
    /// Writes the data. Runs in a savepoint inside the page's transaction, so
    /// a throw undoes just this record, and only if the remote write is newer
    /// than the local one. The engine updates `syncRecord` afterwards,
    /// whatever the write's triggers left there.
    public var apply: @Sendable (Database, SyncRemoteWrite) throws -> SyncApplyOutcome
    /// Runs instead of `apply` when the local write is newer than the remote
    /// one, inside the page's transaction. Actions keep the losing version in
    /// `.conflicts/` here. Must not throw.
    public var superseded: (@Sendable (Database, SyncRemoteWrite) -> Void)?

    public init(
        localKey: String,
        superseded: (@Sendable (Database, SyncRemoteWrite) -> Void)? = nil,
        apply: @escaping @Sendable (Database, SyncRemoteWrite) throws -> SyncApplyOutcome
    ) {
        self.localKey = localKey
        self.superseded = superseded
        self.apply = apply
    }
}

public enum SyncBlobError: Error, Equatable {
    /// The server doesn't have the blob. Only this record is skipped.
    case missing(String)
    /// The blob is larger than any this client downloads. Only this record is skipped.
    case tooLarge(String)
}

/// Downloads and opens blobs for `prepare`.
public struct SyncBlobSource: Sendable {
    let fetch: @Sendable (String) async throws -> Data

    /// The plaintext of a blob. Throws `SyncBlobError.missing` if the server
    /// has no such blob, and stops the sync if it doesn't open with the key.
    public func blob(id: String) async throws -> Data {
        try await fetch(id)
    }
}
