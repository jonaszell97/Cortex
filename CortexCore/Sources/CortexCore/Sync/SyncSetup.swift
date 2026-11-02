import Foundation

/// Why setting sync up failed, beyond what the server and the engine say.
public enum SyncSetupError: Error, Equatable, LocalizedError {
    case invalidServerURL
    case missingToken
    /// First device: the server already holds records, and this device's new
    /// key can't be the one that sealed them.
    case serverHoldsOtherData
    /// Joining: nothing was set up on the server yet.
    case serverIsEmpty
    case keychain(String)

    public var errorDescription: String? {
        switch self {
        case .invalidServerURL: "Enter the server address, for example https://cortex-sync.example.dev."
        case .missingToken: "Enter the server's token."
        case .serverHoldsOtherData:
            "The server already holds data from another sync key. To start over, reset the server's database first."
        case .serverIsEmpty: "The server has no data yet. Set up sync on the other Mac first, then join from here."
        case .keychain(let message): "The Keychain refused the sync key: \(message)"
        }
    }
}

/// Everything a cycle needs to talk to the server. The key and the token live
/// in the Keychain, the server URL in the app's settings (docs/SYNC.md, "Keys
/// and pairing").
public struct SyncCredentials: Sendable, Equatable {
    public var url: URL
    public var token: String
    public var key: SyncKey

    public init(url: URL, token: String, key: SyncKey) {
        self.url = url
        self.token = token
        self.key = key
    }

    public init(_ pairing: SyncPairing) {
        self.init(url: pairing.serverURL, token: pairing.token, key: pairing.key)
    }

    /// What another device joins with.
    public var pairing: SyncPairing {
        SyncPairing(serverURL: url, token: token, key: key)
    }

    /// The stored key and token for the server at `url`; nil if either is
    /// missing.
    public static func load(serverURL url: URL?, from secrets: some SecretStore) -> SyncCredentials? {
        guard let url,
              let tokenData = try? secrets.data(for: SyncKey.tokenKeychainAccount),
              let token = String(data: tokenData, encoding: .utf8), !token.isEmpty,
              let key = try? SyncKey.load(from: secrets)
        else { return nil }
        return SyncCredentials(url: url, token: token, key: key)
    }

    /// Stores the key and the token; on failure neither stays behind.
    public func save(to secrets: some SecretStore) throws {
        do {
            try key.save(to: secrets)
            try secrets.set(Data(token.utf8), for: SyncKey.tokenKeychainAccount)
        } catch {
            Self.remove(from: secrets)
            throw SyncSetupError.keychain(String(describing: error))
        }
    }

    public static func remove(from secrets: some SecretStore) {
        try? secrets.delete(SyncKey.keychainAccount)
        try? secrets.delete(SyncKey.tokenKeychainAccount)
    }
}

/// The steps of setting sync up that don't depend on the platform: checking
/// the address, and checking the server against the key before anything is
/// stored. The apps store the credentials and schedule the cycles.
public enum SyncSetup {
    /// Accepts "host.example", adds https, and requires a host.
    public static func parseServerURL(_ text: String) throws -> URL {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SyncSetupError.invalidServerURL }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host() != nil
        else { throw SyncSetupError.invalidServerURL }
        return url
    }

    /// Plain words for whatever went wrong.
    public static func message(for error: any Error) -> String {
        if let error = error as? SyncEngineError { return error.description }
        if let error = error as? SyncTransportError { return error.description }
        if let error = error as? SyncKeyError { return error.description }
        return error.localizedDescription
    }

    /// Checks that the server answers and accepts the token. Changes nothing.
    public static func testConnection(_ transport: any SyncTransport) async throws {
        _ = try await transport.health()
        _ = try await transport.changes(since: 0, limit: 1)
    }

    /// The first device: creates the sync key and queues the key check, which
    /// goes out with the first upload so other devices can verify their key.
    /// Refuses a server that already holds data, because the new key can't
    /// open it. Nothing is stored in the Keychain.
    public static func firstDevice(
        url: URL, token: String, database: AppDatabase, transport: any SyncTransport
    ) async throws -> SyncCredentials {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw SyncSetupError.missingToken }
        let credentials = SyncCredentials(url: url, token: token, key: .generate())
        let engine = SyncEngine(database: database, transport: transport, key: credentials.key, handlers: [])
        switch try await engine.verifyKey() {
        case .notFound: break
        case .matches, .mismatch: throw SyncSetupError.serverHoldsOtherData
        }
        try await engine.publishKeyCheck()
        return credentials
    }

    /// Another device: checks the pairing code's key against the server's key
    /// check. Nothing is stored in the Keychain.
    public static func join(
        _ pairing: SyncPairing, database: AppDatabase, transport: any SyncTransport
    ) async throws -> SyncCredentials {
        let credentials = SyncCredentials(pairing)
        let engine = SyncEngine(database: database, transport: transport, key: credentials.key, handlers: [])
        switch try await engine.verifyKey() {
        case .matches: return credentials
        case .mismatch: throw SyncEngineError.keyMismatch
        case .notFound: throw SyncSetupError.serverIsEmpty
        }
    }
}
