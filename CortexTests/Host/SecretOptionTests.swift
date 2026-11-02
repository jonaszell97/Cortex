import Foundation
import Testing
@testable import Cortex
import CortexCore

/// A module's `.secret` option: saved in the Keychain under its own account,
/// never read back into the field.
@MainActor
@Suite struct SecretOptionTests {
    let store = MemorySecrets()
    var secrets: ModuleSecrets { ModuleSecrets(id: "writer", store: store) }

    @Test func savesWhatWasTypedUnderTheModulesAccount() throws {
        let key = secrets.key("apiKey", title: "API key")
        let option = SecretOption(key: key, secrets: secrets)
        #expect(!option.isSet)

        option.draft = "  sk-123\n"
        option.save()
        #expect(option.isSet && option.draft.isEmpty && option.error == nil)
        #expect(store.accounts == ["writer.apiKey"])
        #expect(secrets.string(for: key) == "sk-123")
        #expect(SecretOption(key: key, secrets: secrets).isSet, "a new page shows it as saved")
    }

    @Test func nothingTypedSavesNothing() {
        let option = SecretOption(key: secrets.key("apiKey", title: "API key"), secrets: secrets)
        option.draft = "   "
        option.save()
        #expect(!option.isSet && store.accounts.isEmpty)
    }

    @Test func removeDeletesTheKeychainItem() throws {
        let key = secrets.key("apiKey", title: "API key")
        try secrets.set("sk-123", for: key)
        let option = SecretOption(key: key, secrets: secrets)
        #expect(option.isSet)
        option.remove()
        #expect(!option.isSet && store.accounts.isEmpty)
    }

    @Test func aRefusingKeychainIsReported() {
        let option = SecretOption(
            key: ModuleSecretKey(account: "writer.apiKey", title: "API key"),
            secrets: ModuleSecrets(id: "writer", store: RefusingSecrets()))
        option.draft = "sk-123"
        option.save()
        #expect(!option.isSet)
        #expect(option.draft == "sk-123", "kept, to try again")
        #expect(option.error?.hasPrefix("The Keychain refused it") == true)
    }

    @Test func modulesDeclareSecretsAsOptions() throws {
        let services = ModuleServices(
            defaults: UserDefaults(suiteName: "CortexTests-\(UUID().uuidString)")!, secrets: store)
        let host = ModuleHost([FakeDefault.self, FakeWithSecret.self], services: services)
        let module = try #require(host.modules[1] as? FakeWithSecret)
        guard case .secret(let key) = module.options.first?.kind else {
            Issue.record("expected a secret option")
            return
        }
        #expect(key.account == "secretive.token")
        try host.secrets(for: "secretive").set("t0k3n", for: key)
        #expect(module.context.secrets.string(for: key) == "t0k3n")
    }
}

private struct RefusingSecrets: SecretStore {
    struct Refused: Error {}
    func data(for account: String) throws -> Data? { nil }
    func set(_ data: Data, for account: String) throws { throw Refused() }
    func delete(_ account: String) throws { throw Refused() }
}

final class FakeWithSecret: FakeModule, CortexModule {
    static let manifest = ModuleManifest(id: "secretive", name: "Secretive", summary: "", symbol: "key", order: 60)
    var options: [ModuleOption] {
        [ModuleOption(id: "token", title: "Token", kind: .secret(context.secrets.key("token", title: "Token")))]
    }
}
