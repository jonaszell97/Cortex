import CryptoKit
import Foundation

/// Large clip payloads (images, big rich text) as individual files next to
/// the database, encrypted with AES-GCM. The key is derived from the database
/// key, so one Keychain item protects both.
public struct BlobStore: Sendable {
    public let directory: URL
    private let key: SymmetricKey

    init(directory: URL, databaseKey: DatabaseKey) {
        self.directory = directory
        self.key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: databaseKey.rawValue),
            // The app's old name. Part of the key: changing it makes every
            // existing blob unreadable.
            info: Data("the-mind blob store v1".utf8),
            outputByteCount: 32)
    }

    /// Writes `data` and returns its new blob ID.
    func write(_ data: Data) throws -> String {
        try ensureDirectory()
        let id = UUID().uuidString
        let sealed = try AES.GCM.seal(data, using: key)
        let url = fileURL(id)
        try sealed.combined!.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return id
    }

    func read(_ id: String) throws -> Data {
        let sealed = try AES.GCM.SealedBox(combined: Data(contentsOf: fileURL(id)))
        return try AES.GCM.open(sealed, using: key)
    }

    func delete(_ ids: some Sequence<String>) {
        for id in ids {
            try? FileManager.default.removeItem(at: fileURL(id))
        }
    }

    /// Blob IDs present on disk.
    func storedIDs() throws -> Set<String> {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return Set(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { !$0.hasPrefix(".") })
    }

    private func fileURL(_ id: String) -> URL {
        directory.appending(path: id, directoryHint: .notDirectory)
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }
}
