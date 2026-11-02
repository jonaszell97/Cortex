import CryptoKit
import Foundation

/// What was on the pasteboard at one moment, already filtered down to the
/// stored types. Built by the macOS pasteboard monitor or by an importer.
public struct ClipSnapshot: Sendable {
    /// Stored types only, in `ClipType.stored` order.
    public var representations: [LoadedRepresentation]
    public var plainText: String?
    public var isSensitive: Bool
    public var sourceBundleID: String?
    public var sourceAppName: String?
    public var copiedAt: Date
    /// Differs from `copiedAt` only for imported items.
    public var createdAt: Date?

    public init(
        representations: [LoadedRepresentation],
        plainText: String?,
        isSensitive: Bool,
        sourceBundleID: String? = nil,
        sourceAppName: String? = nil,
        copiedAt: Date = .now,
        createdAt: Date? = nil
    ) {
        let order = Dictionary(uniqueKeysWithValues: ClipType.stored.enumerated().map { ($1, $0) })
        self.representations = representations
            .filter { order[$0.type] != nil }
            .sorted { order[$0.type]! < order[$1.type]! }
        self.plainText = plainText ?? representations.first { $0.type == ClipType.plainText }
            .flatMap { String(data: $0.data, encoding: .utf8) }
        self.isSensitive = isSensitive
        self.sourceBundleID = sourceBundleID
        self.sourceAppName = sourceAppName
        self.copiedAt = copiedAt
        self.createdAt = createdAt
    }

    public var isEmpty: Bool { representations.isEmpty }

    public var byteSize: Int { representations.reduce(0) { $0 + $1.data.count } }

    private var types: Set<String> { Set(representations.map(\.type)) }

    /// Files win. An image without any text is an image, even when RTF, RTFD
    /// or HTML come with it (Safari's "Copy Image" adds an RTFD holding just
    /// the picture). With text, rich text wins over the image, because apps
    /// like Word and Pages put a picture of the selection next to the text.
    /// Anything else is text.
    public var kind: ClipItem.Kind {
        let types = types
        let hasImage = !types.isDisjoint(with: ClipType.images)
        if types.contains(ClipType.fileURL) { return .files }
        if hasImage && !hasText { return .image }
        if types.contains(ClipType.rtf) || types.contains(ClipType.flatRTFD) || types.contains(ClipType.html) {
            return .richText
        }
        return hasImage ? .image : .text
    }

    /// Whether the plain-text form has anything visible, ignoring the object
    /// replacement character that stands in for attachments.
    var hasText: Bool {
        guard let plainText else { return false }
        return plainText.contains { !$0.isWhitespace && $0 != "\u{FFFC}" }
    }

    public var contentHash: String {
        var hasher = SHA256()
        hasher.update(data: Data(kind.rawValue.utf8))
        for representation in representations {
            hasher.update(data: Data(representation.type.utf8))
            withUnsafeBytes(of: UInt64(representation.data.count).littleEndian) { hasher.update(bufferPointer: $0) }
            hasher.update(data: representation.data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// File URLs are stored as one representation, one absolute URL per line.
    public static func fileURLRepresentation(_ urls: [URL]) -> LoadedRepresentation {
        LoadedRepresentation(
            type: ClipType.fileURL,
            data: Data(urls.map(\.absoluteString).joined(separator: "\n").utf8))
    }

    var fileURLs: [URL] {
        guard let data = representations.first(where: { $0.type == ClipType.fileURL })?.data,
              let string = String(data: data, encoding: .utf8)
        else { return [] }
        return string.split(separator: "\n").compactMap { URL(string: String($0)) }
    }
}

enum PreviewText {
    static let maxLength = 300

    /// Collapses whitespace runs (including newlines) to single spaces.
    static func make(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(min(text.count, maxLength))
        var pendingSpace = false
        for character in text {
            if character.isWhitespace {
                pendingSpace = !result.isEmpty
                continue
            }
            if pendingSpace { result.append(" ") }
            pendingSpace = false
            result.append(character)
            if result.count >= maxLength { break }
        }
        return result
    }
}
