import CryptoKit
import Foundation
import Security

/// The 256-bit key that encrypts the database. Generated once, kept in the
/// Keychain, never written anywhere else.
public struct DatabaseKey: Sendable {
    public static let byteCount = 32
    static let keychainAccount = "database-key"

    let rawValue: Data

    public init(rawValue: Data) throws {
        guard rawValue.count == Self.byteCount else {
            throw AppDatabaseError.malformedKey(byteCount: rawValue.count)
        }
        self.rawValue = rawValue
    }

    public static func generate() -> DatabaseKey {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return try! DatabaseKey(rawValue: Data(bytes))
    }

    /// SQLCipher's raw-key syntax. The key is already random, so this skips
    /// the PBKDF2 derivation a passphrase would get and keeps opening fast.
    var sqlCipherPassphrase: String {
        "x'" + Self.hex(rawValue) + "'"
    }

    /// The raw key followed by a 16-byte salt, for a database with a
    /// plaintext header: its salt can't live in the file's first bytes, so
    /// it comes from the key. The salt isn't secret; deriving it keeps it
    /// unique per database without storing anything else.
    var sqlCipherPassphraseWithSalt: String {
        let salt = HMAC<SHA256>.authenticationCode(
            for: Data("cortex database salt v1".utf8), using: SymmetricKey(data: rawValue))
        return "x'" + Self.hex(rawValue) + Self.hex(Data(salt).prefix(16)) + "'"
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined()
    }

    /// Returns the stored key, or creates and stores one if there is no
    /// database yet. A database without a key is an error, not a reason to
    /// silently start over.
    static func loadOrCreate(in secrets: some SecretStore, databaseExists: Bool) throws -> DatabaseKey {
        if let data = try secrets.data(for: keychainAccount) {
            return try DatabaseKey(rawValue: data)
        }
        guard !databaseExists else {
            throw AppDatabaseError.keyMissing
        }
        let key = generate()
        try secrets.set(key.rawValue, for: keychainAccount)
        Log.keychain.info("Generated a new database key")
        return key
    }
}
