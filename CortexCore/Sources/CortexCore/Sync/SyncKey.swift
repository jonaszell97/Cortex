import CryptoKit
import Foundation

public enum SyncKeyError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case malformedKey(byteCount: Int)
    /// A payload or blob doesn't open with this key: a different key, or
    /// data that was changed or moved to another record.
    case cannotOpen
    case malformedPairingCode

    public var description: String {
        switch self {
        case .malformedKey(let byteCount):
            "The sync key has \(byteCount) bytes instead of \(SyncKey.byteCount)."
        case .cannotOpen:
            "The sync key doesn't match."
        case .malformedPairingCode:
            "This isn't a Cortex pairing code."
        }
    }

    public var errorDescription: String? { description }
}

/// The end-to-end key shared by the two Macs (docs/SYNC.md, "Keys and pairing").
/// The server only ever sees what it seals, and IDs it derives.
///
/// Two subkeys come from it by HKDF-SHA256, like `BlobStore`'s: one seals
/// payloads and blobs with AES-GCM, the other derives record and blob IDs
/// with HMAC-SHA256, so the server can't link an ID to content (a plain hash
/// of a short password would be guessable).
public struct SyncKey: Sendable, Equatable {
    public static let byteCount = 32
    /// Keychain account of the key. Never stored anywhere else.
    public static let keychainAccount = "sync-key"
    /// Keychain account of the server's bearer token.
    public static let tokenKeychainAccount = "sync-token"

    public let rawValue: Data
    private let payloadKey: SymmetricKey
    private let idKey: SymmetricKey

    public init(rawValue: Data) throws {
        guard rawValue.count == Self.byteCount else {
            throw SyncKeyError.malformedKey(byteCount: rawValue.count)
        }
        self.rawValue = rawValue
        let master = SymmetricKey(data: rawValue)
        // The info strings are part of the keys: changing one makes every
        // record on the server unreadable.
        payloadKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: master, info: Data("cortex sync payload v1".utf8), outputByteCount: 32)
        idKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: master, info: Data("cortex sync id v1".utf8), outputByteCount: 32)
    }

    public static func generate() -> SyncKey {
        let raw = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        return try! SyncKey(rawValue: raw)
    }

    public static func == (lhs: SyncKey, rhs: SyncKey) -> Bool {
        lhs.rawValue == rhs.rawValue
    }

    // MARK: - Keychain

    public static func load(from secrets: some SecretStore) throws -> SyncKey? {
        try secrets.data(for: keychainAccount).map(SyncKey.init(rawValue:))
    }

    public func save(to secrets: some SecretStore) throws {
        try secrets.set(rawValue, for: Self.keychainAccount)
    }

    // MARK: - IDs

    /// The server's ID of a record: the first 32 hex chars of
    /// HMAC(idKey, collection + "\0" + localKey). The same on both Macs, so
    /// the same clip copied on each merges into one record.
    public func recordID(_ collection: SyncCollection, localKey: String) -> String {
        hmacHex(Data((collection.rawValue + "\0" + localKey).utf8))
    }

    /// The server's ID of a blob: HMAC(idKey, "blob\0" + SHA256(plaintext)),
    /// 32 hex chars. It deduplicates and is stable across Macs.
    public func blobID(for plaintext: Data) -> String {
        hmacHex(Data("blob\0".utf8) + Data(SHA256.hash(data: plaintext)))
    }

    private func hmacHex(_ message: Data) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: idKey)
        return mac.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Sealing

    /// AES-GCM over a payload, bound to its record and to everything the
    /// server stores in the clear about it (protocol v2, docs/SYNC.md, "Sealing
    /// and authenticated metadata"): the AAD is `"v2/" + collection + "/" + id +
    /// "/" + modifiedAt + "/" + device + "/" + deleted`. Whoever holds only the
    /// token can't move a payload to another record, restamp an old one to win
    /// last-writer-wins, or turn a record into a tombstone.
    public func seal(_ plaintext: Data, for header: SyncRecordHeader) throws -> Data {
        try Self.seal(plaintext, using: payloadKey, aad: header.aad)
    }

    public func open(_ sealed: Data, for header: SyncRecordHeader) throws -> Data {
        try Self.open(sealed, using: payloadKey, aad: header.aad)
    }

    /// Opens a payload sealed by protocol v1, whose AAD was only
    /// `collection + "/" + id`. Such a record proves the key, but nothing
    /// about its metadata, so it is never applied.
    func openV1(_ sealed: Data, collection: SyncCollection, id: String) throws -> Data {
        try Self.open(sealed, using: payloadKey, aad: Data((collection.rawValue + "/" + id).utf8))
    }

    /// The plaintext of every tombstone: a tombstone is sealed like any other
    /// record, so only a Mac with the key can delete.
    static let tombstoneContents = Data(#"{"v":2,"deleted":true}"#.utf8)

    private struct TombstoneProbe: Decodable {
        var deleted: Bool?
    }

    /// Whether an opened payload says it is a tombstone.
    static func isTombstone(_ plaintext: Data) -> Bool {
        (try? JSONDecoder().decode(TombstoneProbe.self, from: plaintext))?.deleted == true
    }

    /// Blob bytes are sealed the same way, with the blob ID as AAD. The ID is
    /// a MAC of the content, and records name their blobs inside their
    /// sealed payload, so blobs need no metadata.
    public func sealBlob(_ plaintext: Data, id: String) throws -> Data {
        try Self.seal(plaintext, using: payloadKey, aad: Data(id.utf8))
    }

    public func openBlob(_ sealed: Data, id: String) throws -> Data {
        try Self.open(sealed, using: payloadKey, aad: Data(id.utf8))
    }

    private static func seal(_ plaintext: Data, using key: SymmetricKey, aad: Data) throws -> Data {
        // The default 12-byte nonce always has a combined representation.
        try AES.GCM.seal(plaintext, using: key, authenticating: aad).combined!
    }

    private static func open(_ sealed: Data, using key: SymmetricKey, aad: Data) throws -> Data {
        do {
            return try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key, authenticating: aad)
        } catch {
            throw SyncKeyError.cannotOpen
        }
    }

    // MARK: - Key check

    /// Setting up sync pushes this record (`meta` collection); joining from the
    /// second Mac opens it first, so a wrong key fails at setup with a clear
    /// message instead of on every record later.
    public static let keyCheckLocalKey = "keycheck"
    static let keyCheckContents = Data("cortex sync key check v1".utf8)

    public var keyCheckID: String { recordID(.meta, localKey: Self.keyCheckLocalKey) }

    public func sealedKeyCheck(modifiedAt: Int64, device: String) throws -> Data {
        let header = SyncRecordHeader(collection: .meta, id: keyCheckID, modifiedAt: modifiedAt, device: device, deleted: false)
        return try seal(Self.keyCheckContents, for: header)
    }

    /// Whether a record is the key check, sealed with this key. One sealed by
    /// protocol v1 counts too: its contents are fixed, so its metadata
    /// doesn't matter.
    public func opensKeyCheck(_ record: SyncWireRecord) -> Bool {
        guard record.id == keyCheckID, record.syncCollection == .meta, !record.deleted,
              let sealed = record.payload
        else { return false }
        let opened = (try? open(sealed, for: SyncRecordHeader(record, collection: .meta)))
            ?? (try? openV1(sealed, collection: .meta, id: record.id))
        return opened == Self.keyCheckContents
    }
}

/// What the server keeps in the clear about a record. Sealing binds all of it
/// to the payload (`SyncKey.seal(_:for:)`).
public struct SyncRecordHeader: Sendable, Equatable {
    public var collection: SyncCollection
    public var id: String
    public var modifiedAt: Int64
    public var device: String
    public var deleted: Bool

    public init(collection: SyncCollection, id: String, modifiedAt: Int64, device: String, deleted: Bool) {
        self.collection = collection
        self.id = id
        self.modifiedAt = modifiedAt
        self.device = device
        self.deleted = deleted
    }

    /// The header of a pulled record whose collection is known.
    public init(_ record: SyncWireRecord, collection: SyncCollection) {
        self.init(
            collection: collection, id: record.id, modifiedAt: record.modifiedAt, device: record.device,
            deleted: record.deleted)
    }

    /// The fields are separated by "/", which none of them can contain:
    /// collections and IDs are fixed sets and hex, device IDs match
    /// `[A-Za-z0-9._-]` on the server.
    var aad: Data {
        Data("v2/\(collection.rawValue)/\(id)/\(modifiedAt)/\(device)/\(deleted)".utf8)
    }
}

/// Everything the second Mac needs to join (docs/SYNC.md, "Keys and pairing"), as
/// one string: `cxsync1:<base64url({"u": url, "t": token, "k": key})>`. It holds
/// the key, so it travels only by AirDrop or Universal Clipboard, never by chat
/// or mail.
public struct SyncPairing: Sendable, Equatable {
    public static let prefix = "cxsync1:"

    public var serverURL: URL
    public var token: String
    public var key: SyncKey

    public init(serverURL: URL, token: String, key: SyncKey) {
        self.serverURL = serverURL
        self.token = token
        self.key = key
    }

    private struct Contents: Codable {
        var u: String
        var t: String
        var k: Data
    }

    public var code: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = try! encoder.encode(Contents(u: serverURL.absoluteString, t: token, k: key.rawValue))
        return Self.prefix + json.base64EncodedString()
            .replacing("+", with: "-")
            .replacing("/", with: "_")
            .replacing("=", with: "")
    }

    /// Parses a pasted code. Surrounding whitespace is ignored.
    public init(code: String) throws {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(Self.prefix) else { throw SyncKeyError.malformedPairingCode }
        var base64 = String(trimmed.dropFirst(Self.prefix.count))
            .replacing("-", with: "+")
            .replacing("_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let json = Data(base64Encoded: base64),
              let contents = try? JSONDecoder().decode(Contents.self, from: json),
              let url = URL(string: contents.u),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host() != nil,
              !contents.t.isEmpty,
              let key = try? SyncKey(rawValue: contents.k)
        else {
            throw SyncKeyError.malformedPairingCode
        }
        self.init(serverURL: url, token: contents.t, key: key)
    }
}
