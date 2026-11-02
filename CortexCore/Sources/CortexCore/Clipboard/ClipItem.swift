import Foundation
import GRDB

/// One entry of the clipboard history.
public struct ClipItem: Codable, Sendable, Identifiable, Hashable, FetchableRecord, MutablePersistableRecord {
    public enum Kind: String, Codable, Sendable, DatabaseValueConvertible {
        case text, richText, image, files
    }

    public var id: Int64?
    /// SHA-256 over kind and stored representations; re-copying the same
    /// content finds the existing item instead of inserting a copy.
    public var contentHash: String
    public var kind: Kind
    /// Short single-line form for the list.
    public var preview: String
    /// Full plain-text form: the text itself, file paths, nil for a bare image.
    public var plainText: String?
    /// The text in an image clip, read on this Mac (`ImageTextIndexer`):
    /// nil until it has been read, "" if there is none. Not synced.
    public var recognizedText: String? = nil
    /// What the full-text index sees. For sensitive items with indexing
    /// turned off this is only the source app name.
    public var searchText: String
    public var isSensitive: Bool
    public var isPinned: Bool
    public var sourceBundleID: String?
    public var sourceAppName: String?
    public var byteSize: Int
    /// Small PNG for image items.
    public var thumbnail: Data?
    public var createdAt: Date
    /// Ordering key: a re-copy moves the item to the top.
    public var lastCopiedAt: Date

    public static let databaseTableName = "clipItem"
    static let representations = hasMany(ClipRepresentation.self)

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// What pasting as plain text writes: the text, the file paths, or for
    /// an image the text read from it (nil while there is none).
    public var textForPlainPaste: String? {
        if kind == .image, let recognizedText, !recognizedText.isEmpty { return recognizedText }
        return plainText
    }

    /// The text read from an image clip, nil while there is none.
    public var imageText: String? {
        guard kind == .image, let recognizedText, !recognizedText.isEmpty else { return nil }
        return recognizedText
    }

    public enum Columns {
        static let contentHash = Column(CodingKeys.contentHash)
        static let isPinned = Column(CodingKeys.isPinned)
        static let isSensitive = Column(CodingKeys.isSensitive)
        static let lastCopiedAt = Column(CodingKeys.lastCopiedAt)
    }
}

/// One stored pasteboard type of a clip. Small payloads live in the row;
/// images and large payloads live encrypted in the blob store.
public struct ClipRepresentation: Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var clipItemID: Int64
    public var position: Int
    public var type: String
    public var data: Data?
    public var blobID: String?
    public var byteSize: Int

    public static let databaseTableName = "clipRepresentation"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// The list row: everything but the full text.
public struct ClipSummary: Decodable, Sendable, Identifiable, Hashable, FetchableRecord {
    public var id: Int64
    public var kind: ClipItem.Kind
    public var preview: String
    public var isSensitive: Bool
    public var isPinned: Bool
    public var sourceBundleID: String?
    public var sourceAppName: String?
    public var byteSize: Int
    public var thumbnail: Data?
    public var lastCopiedAt: Date

    static let selection = "id, kind, preview, isSensitive, isPinned, sourceBundleID, sourceAppName, byteSize, thumbnail, lastCopiedAt"
}

/// A representation with its payload loaded (and decrypted, if it was a blob).
public struct LoadedRepresentation: Sendable, Hashable {
    public var type: String
    public var data: Data

    public init(type: String, data: Data) {
        self.type = type
        self.data = data
    }
}

/// Everything the preview pane and the paster need for one item.
public struct ClipDetail: Sendable {
    public var item: ClipItem
    public var representations: [LoadedRepresentation]

    public func data(for type: String) -> Data? {
        representations.first { $0.type == type }?.data
    }

    public var fileURLs: [URL] {
        guard let data = data(for: ClipType.fileURL), let string = String(data: data, encoding: .utf8) else { return [] }
        return string.split(separator: "\n").compactMap { URL(string: String($0)) }
    }

    public var imageData: Data? {
        data(for: ClipType.png) ?? data(for: ClipType.tiff)
    }
}

/// A recent text clip and when it was last copied (`ClipStore.recentTexts`).
public struct RecentClipText: Sendable, Equatable {
    public var text: String
    public var copiedAt: Date

    public init(text: String, copiedAt: Date) {
        self.text = text
        self.copiedAt = copiedAt
    }
}
