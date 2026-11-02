import Foundation

// The decrypted payloads of the synced collections (docs/SYNC.md, "Handling per
// data type"). Each has a top-level `v`; a record with a higher `v` than a build
// knows stops the pull ("update Cortex on this Mac"). Adding an optional field
// doesn't need a new `v`, changing the meaning of one does.

extension Date {
    /// Milliseconds since 1970, which is what the database keeps of a date.
    var syncMilliseconds: Int64 {
        Int64((timeIntervalSince1970 * 1000).rounded())
    }

    init(syncMilliseconds ms: Int64) {
        self.init(timeIntervalSince1970: Double(ms) / 1000)
    }
}

struct ClipPayload: Codable, Sendable, Equatable {
    static let version = 1

    struct Representation: Codable, Sendable, Equatable {
        var type: String
        /// Inline bytes (base64 in the JSON), up to `ClipStore.inlineLimit`.
        var data: Data?
        /// Blob ID of images and larger payloads.
        var blob: String?
        var size: Int
    }

    var v: Int
    var contentHash: String
    var kind: ClipItem.Kind
    var representations: [Representation]
    var plainText: String?
    var isSensitive: Bool
    var isPinned: Bool
    var sourceBundleID: String?
    var sourceAppName: String?
    var createdAt: Int64
    var lastCopiedAt: Int64
}

struct SnippetPayload: Codable, Sendable, Equatable {
    static let version = 1

    var v: Int
    var syncID: String
    var name: String
    var keyword: String?
    var body: String
    var tags: [String]
    var createdAt: Int64
    var updatedAt: Int64
}

struct ReadingItemPayload: Codable, Sendable, Equatable {
    static let version = 1

    var v: Int
    /// Normalized; the record key.
    var url: String
    var title: String?
    var note: String?
    var sourceAppName: String?
    var addedAt: Int64
    /// nil while unread.
    var readAt: Int64?
}

struct ActionFilePayload: Codable, Sendable, Equatable {
    static let version = 1

    var v: Int
    var fileName: String
    var contents: String
}

struct KnowledgeFilePayload: Codable, Sendable, Equatable {
    static let version = 1

    var v: Int
    /// Relative to the knowledge folder; the record key.
    var path: String
    /// The file's modification date, in milliseconds.
    var modified: Int64
    /// The bytes (base64 in the JSON), up to `KnowledgeFileSync.inlineLimit`.
    var data: Data?
    /// Blob ID of a larger file (pictures in `assets/`).
    var blob: String?
    var size: Int
}
