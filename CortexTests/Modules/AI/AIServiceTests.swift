import Foundation
import Testing
@testable import Cortex
import CortexCore

/// The AI module's service: the key from the Keychain, the settings, the
/// usage totals; and that Quick Actions never sends sensitive input.
@MainActor
@Suite struct AIServiceTests {
    let secrets = MemorySecrets()
    let defaults = UserDefaults(suiteName: "CortexTests-\(UUID().uuidString)")!
    var moduleDefaults: ModuleDefaults { ModuleDefaults(id: "ai", store: defaults) }
    var moduleSecrets: ModuleSecrets { ModuleSecrets(id: "ai", store: secrets) }

    /// Answers every text request with "Done." and counts them.
    final class Server: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var requests: Int { lock.withLock { count } }

        var client: HTTPClient {
            { [self] request in
                lock.withLock { count += 1 }
                let json = """
                    {"output": [{"type": "message", "content": [{"type": "output_text", "text": "Done."}]}],
                     "usage": {"input_tokens": 1000000, "output_tokens": 1000000}}
                    """
                return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
    }

    let server = Server()

    func service() -> AIService {
        AIService(settings: AISettings(defaults: moduleDefaults), secrets: moduleSecrets, defaults: moduleDefaults, http: server.client)
    }

    func run(_ action: AIAction, _ text: String) async throws -> ActionOutput {
        try await action.run(.text(text), context: ActionContext(fallbackOutputDirectory: URL(filePath: "/tmp"), temporaryDirectory: URL(filePath: "/tmp")))
    }

    @Test func withoutAKeyNothingIsSent() async throws {
        let service = service()
        let proofread = try #require(service.actions.first)
        await #expect(throws: QuickActionError("No OpenAI API key yet: add one in Cortex Settings → AI")) {
            try await run(proofread, "helo")
        }
        #expect(server.requests == 0)
        #expect(service.usage.requests == 0)
    }

    @Test func runsCountTheirUsageAndKeepIt() async throws {
        let service = service()
        try moduleSecrets.set("sk-test", for: service.apiKey(for: .openAI))
        #expect(secrets.accounts == ["ai.openai-api-key"])

        #expect(try await run(service.actions[0], "helo") == .text("Done."))
        #expect(server.requests == 1)
        #expect(service.usage.requests == 1)
        #expect(service.usage.entries.first?.model == "gpt-6-luna")
        #expect(abs(service.usage.estimatedCost - 0.60) < 1e-9)
        #expect(self.service().usage == service.usage, "kept in UserDefaults")

        service.resetUsage()
        #expect(service.usage.requests == 0)
        #expect(self.service().usage.requests == 0)
    }

    @Test func modelsDefaultToTheVendorsAndAreKeptPerVendor() {
        let settings = AISettings(defaults: moduleDefaults)
        #expect(settings.vendor == .openAI)
        #expect(settings.effectiveTextModel == "gpt-6-luna")
        #expect(settings.effectiveImageModel == "gpt-image-2.5-flare")

        settings.textModel = "  gpt-6-sol "
        #expect(settings.effectiveTextModel == "gpt-6-sol")
        #expect(defaults.string(forKey: "ai.openai.textModel") == "  gpt-6-sol ")
        #expect(AISettings(defaults: moduleDefaults).effectiveTextModel == "gpt-6-sol")

        let service = AIService(settings: settings, secrets: moduleSecrets, defaults: moduleDefaults)
        #expect(service.actions.map(\.model) == ["gpt-6-sol", "gpt-6-sol"])
        #expect(service.commands.map(\.model) == ["gpt-6-sol", "gpt-image-2.5-flare"])
    }

    // MARK: - Sensitive input

    func actionsScope(input: ResolvedActionInput, service: AIService) -> (ActionsScope, ActionsService) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "CortexTests-actions-\(UUID().uuidString)", directoryHint: .isDirectory)
        let actions = ActionsService(directory: directory, defaults: defaults)
        actions.contributedActions = { service.actions }
        let palette = FakePaletteHost()
        return (ActionsScope(service: actions, resolveInput: { input }, palette: { palette }), actions)
    }

    @Test func sensitiveInputIsNotOffered() throws {
        let service = service()
        let (plain, _) = actionsScope(input: ResolvedActionInput(input: .text("helo"), source: .pasteboard), service: service)
        plain.search("proofread")
        #expect(plain.list.items.first?.id == "ai.proofread")

        let secret = ResolvedActionInput(input: .text("hunter2"), source: .pasteboard, isSensitive: true)
        let (sensitive, _) = actionsScope(input: secret, service: service)
        sensitive.search("proofread")
        #expect(!sensitive.list.items.contains { $0.isRemote })
        sensitive.search("")
        #expect(!sensitive.list.items.contains { $0.isRemote })
        #expect(!sensitive.list.items.isEmpty, "the other actions still are")
        // A typed prompt is the user's own text: `$ask` is a command.
        #expect(service.commands.allSatisfy { !$0.matches(.text("hunter2")) })
    }

    @Test func sensitiveInputIsNeverSent() async throws {
        let service = service()
        try moduleSecrets.set("sk-test", for: service.apiKey(for: .openAI))
        let (_, actions) = actionsScope(input: ResolvedActionInput(input: .none, source: .pasteboard), service: service)
        await actions.run(service.actions[0], input: .text("hunter2"), isSensitive: true, delivery: .copy)
        #expect(server.requests == 0)
        #expect(actions.usage["ai.proofread"] == nil, "not counted as used")
    }
}
