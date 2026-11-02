import Foundation
import CortexCore

/// Sends the AI actions' requests with the vendor's API key from the
/// Keychain, and counts what they used.
@MainActor
@Observable
final class AIService {
    let settings: AISettings
    /// Since the last reset; stored as JSON in "ai.usage".
    private(set) var usage: AIUsageTotals

    @ObservationIgnored private let secrets: ModuleSecrets
    @ObservationIgnored private let defaults: ModuleDefaults
    @ObservationIgnored private let http: HTTPClient
    @ObservationIgnored private let log = Log.logger("ai")

    init(
        settings: AISettings, secrets: ModuleSecrets, defaults: ModuleDefaults,
        http: @escaping HTTPClient = { try await URLSession.shared.send($0) }
    ) {
        self.settings = settings
        self.secrets = secrets
        self.defaults = defaults
        self.http = http
        usage = defaults.data("usage").flatMap { try? JSONDecoder().decode(AIUsageTotals.self, from: $0) } ?? AIUsageTotals()
    }

    /// The vendor's API key, account "ai.<vendor>-api-key".
    func apiKey(for vendor: AIVendorID) -> ModuleSecretKey {
        secrets.key("\(vendor.rawValue)-api-key", title: "API key")
    }

    /// The actions (Proofread, Summarize) with the vendor and model as they
    /// are set now.
    var actions: [AIAction] {
        let vendor = settings.vendor
        return AIAction.all(vendor: vendor, textModel: settings.effectiveTextModel) { [self] request in
            try await send(request, to: vendor)
        }
    }

    /// The commands (`$ask`, `$img`) with the vendor and models as they are
    /// set now.
    var commands: [AICommand] {
        let vendor = settings.vendor
        return AICommand.all(
            vendor: vendor, textModel: settings.effectiveTextModel, imageModel: settings.effectiveImageModel
        ) { [self] request in
            try await send(request, to: vendor)
        }
    }

    /// Only ever called when an action is run. The key is read from the
    /// Keychain for each request, never kept.
    func send(_ request: AIRequest, to vendor: AIVendorID) async throws -> AIResponse {
        guard let key = secrets.string(for: apiKey(for: vendor)) else {
            throw QuickActionError("No \(vendor.name) API key yet: add one in Cortex Settings → AI")
        }
        let response = try await vendor.makeVendor(apiKey: key, http: http).perform(request)
        record(response.usage)
        return response
    }

    private func record(_ entry: AIUsage) {
        log.info("\(entry.model, privacy: .public): \(entry.inputTokens) in, \(entry.outputTokens) out")
        usage.add(entry)
        save()
    }

    /// Starts counting from zero.
    func resetUsage() {
        usage = AIUsageTotals()
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(usage) {
            defaults.set(data, for: "usage")
        }
    }
}
