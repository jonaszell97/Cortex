import Foundation
import Testing
@testable import CortexCore

@Suite struct SyncSetupTests {
    let server = InMemorySyncServer()
    let url = URL(string: "https://cortex-sync.example.dev")!

    @Test func serverAddressesAreChecked() throws {
        #expect(try SyncSetup.parseServerURL(" https://sync.example.dev/ ").host() == "sync.example.dev")
        #expect(try SyncSetup.parseServerURL("sync.example.dev").scheme == "https")
        #expect(try SyncSetup.parseServerURL("http://100.64.0.1:8000").port == 8000)
        for bad in ["", "   ", "ftp://sync.example.dev", "https://"] {
            #expect(throws: SyncSetupError.invalidServerURL) { try SyncSetup.parseServerURL(bad) }
        }
    }

    @Test func credentialsAreStoredTogetherAndRemovedTogether() throws {
        let secrets = DatabaseKeyTests.MemoryStore()
        #expect(SyncCredentials.load(serverURL: url, from: secrets) == nil)
        let credentials = SyncCredentials(url: url, token: InMemorySyncServer.token, key: .generate())
        try credentials.save(to: secrets)
        #expect(SyncCredentials.load(serverURL: url, from: secrets) == credentials)
        // The server URL is the app's setting; without it there is nothing to talk to.
        #expect(SyncCredentials.load(serverURL: nil, from: secrets) == nil)
        #expect(try SyncCredentials(credentials.pairing) == SyncCredentials(SyncPairing(code: credentials.pairing.code)))
        SyncCredentials.remove(from: secrets)
        #expect(try secrets.data(for: SyncKey.keychainAccount) == nil)
        #expect(try secrets.data(for: SyncKey.tokenKeychainAccount) == nil)
    }

    @Test func aDeviceJoinsOnlyWithTheKeyOfTheServer() async throws {
        let first = try makeTestDatabase(), phone = try makeTestDatabase()
        let transport = DirectTransport(server: server)
        let stranger = SyncPairing(serverURL: url, token: InMemorySyncServer.token, key: .generate())

        await #expect(throws: SyncSetupError.serverIsEmpty) {
            try await SyncSetup.join(stranger, database: phone, transport: transport)
        }
        await #expect(throws: SyncSetupError.missingToken) {
            try await SyncSetup.firstDevice(url: url, token: " \n", database: first, transport: transport)
        }

        let credentials = try await SyncSetup.firstDevice(
            url: url, token: InMemorySyncServer.token, database: first, transport: transport)
        // The key check goes out with the first upload.
        try await SyncEngine(database: first, transport: transport, key: credentials.key, handlers: []).runCycle()

        let joined = try await SyncSetup.join(credentials.pairing, database: phone, transport: transport)
        #expect(joined == credentials)
        await #expect(throws: SyncEngineError.keyMismatch) {
            try await SyncSetup.join(stranger, database: phone, transport: transport)
        }
        await #expect(throws: SyncSetupError.serverHoldsOtherData) {
            try await SyncSetup.firstDevice(url: url, token: InMemorySyncServer.token, database: phone, transport: transport)
        }
    }
}
