import SwiftUI
import CortexCore

/// AI actions in `>`: Proofread and Summarize, on the clipboard, a clip or
/// the selection; and the commands `$ask` and `$img` on a typed prompt. With
/// the user's own API key (OpenAI so far; vendors are `AIVendorID`). Text is
/// sent only when one is run, never in the background and never when it is
/// marked sensitive. Settings shows what was used and roughly what it cost.
/// Other modules send their own requests through `AIAPI`.
@MainActor
final class AIModule: CortexModule, ActionContributing, CommandContributing, AIAPI {
    static let manifest = ModuleManifest(
        id: "ai", name: "AI",
        summary: "Proofreads and summarizes in Quick Actions, answers and draws with $ask and $img, with your own API key.",
        symbol: "sparkles", enabledByDefault: false, requirements: [.module("actions")], order: 35)

    let service: AIService
    private let settings: AISettings

    init(context: ModuleContext) {
        settings = AISettings(defaults: context.defaults)
        service = AIService(settings: settings, secrets: context.secrets, defaults: context.defaults)
    }

    var options: [ModuleOption] {
        let settings = settings
        let vendor = settings.vendor
        return [
            ModuleOption(
                id: "vendor", title: "Service",
                help: "Text you run an AI action on is sent to \(vendor.name), and only then: nothing is sent in the background, and nothing marked sensitive (passwords, clips from password managers).",
                kind: .choice(
                    Binding(get: { settings.vendor.rawValue }, set: { settings.vendor = AIVendorID(rawValue: $0) ?? .openAI }),
                    AIVendorID.allCases.map { ($0.rawValue, $0.name) })),
            ModuleOption(
                id: "apiKey", title: "API key", help: "Kept in the Keychain. Create one at \(vendor.keysURL.absoluteString)",
                kind: .secret(service.apiKey(for: vendor))),
            ModuleOption(
                id: "textModel", title: "Text model", help: "For Proofread, Summarize, Ask AI and the knowledge base's $note, $todo and $tidy. Empty: \(vendor.defaultTextModel).",
                kind: .text(Bindable(settings).textModel, prompt: vendor.defaultTextModel)),
            ModuleOption(
                id: "imageModel", title: "Image model", help: "For Generate Image. Empty: \(vendor.defaultImageModel).",
                kind: .text(Bindable(settings).imageModel, prompt: vendor.defaultImageModel)),
        ]
    }

    var settingsView: AnyView? {
        AnyView(AISettingsView(service: service))
    }

    // MARK: - ActionContributing

    var contributedActions: [any QuickAction] {
        service.actions
    }

    // MARK: - CommandContributing

    var contributedCommands: [any Command] {
        service.commands
    }

    // MARK: - AIAPI

    var vendor: AIVendorID { settings.vendor }
    var textModel: String { settings.effectiveTextModel }

    var send: @Sendable (AIRequest) async throws -> AIResponse {
        let vendor = settings.vendor
        return { [service] request in try await service.send(request, to: vendor) }
    }
}
