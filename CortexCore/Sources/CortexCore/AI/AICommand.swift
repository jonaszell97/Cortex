import Foundation

/// A command that sends a prompt to an AI vendor: `$ask why is the sky
/// blue` answers, `$img a cat on the moon` draws. The prompt is typed, or
/// taken from the clipboard as the form's suggestion, never on its own.
/// It resolves to a job, so nothing is sent until ⏎; `isRemote`, so it
/// never runs on sensitive input.
public struct AICommand: Command {
    public enum Kind: String, Sendable, CaseIterable {
        case ask, image
    }

    public let kind: Kind
    public let vendor: AIVendorID
    /// The model it asks: the one set in Settings. `$img` may be told
    /// another of the vendor's image models (its Model option).
    public let model: String
    /// Sends the request: the app adds the API key and counts the usage.
    let send: @Sendable (AIRequest) async throws -> AIResponse

    public init(_ kind: Kind, vendor: AIVendorID, model: String, send: @escaping @Sendable (AIRequest) async throws -> AIResponse) {
        self.kind = kind
        self.vendor = vendor
        self.model = model
        self.send = send
    }

    /// The commands, in the order they are listed.
    public static func all(
        vendor: AIVendorID, textModel: String, imageModel: String,
        send: @escaping @Sendable (AIRequest) async throws -> AIResponse
    ) -> [AICommand] {
        Kind.allCases.map { kind in
            AICommand(kind, vendor: vendor, model: kind == .image ? imageModel : textModel, send: send)
        }
    }

    /// The IDs of the actions they were, so usage counts carry over.
    public var id: String { "ai.\(kind.rawValue)" }

    public var name: String {
        switch kind {
        case .ask: "ask"
        case .image: "img"
        }
    }

    public var title: String {
        switch kind {
        case .ask: "Ask AI"
        case .image: "Generate Image"
        }
    }

    public var summary: String {
        switch kind {
        case .ask: "Sends a question to \(vendor.name) and pastes the answer."
        case .image: "Sends a description to \(vendor.name) and pastes the picture."
        }
    }

    public var symbol: String {
        switch kind {
        case .ask: "sparkles"
        case .image: "photo.badge.plus"
        }
    }

    public var keywords: [String] {
        let own: [String] = switch kind {
        case .ask: ["prompt", "chat", "question", "answer"]
        case .image: ["image", "picture", "draw", "prompt", "create"]
        }
        return ["ai", "gpt", vendor.name] + own
    }

    public var argument: CommandArgument? {
        let placeholder = switch kind {
        case .ask: "why is the sky blue"
        case .image: "a cat on the moon"
        }
        return CommandArgument(title: "Prompt", placeholder: placeholder, kind: .prompt, suggestions: .clipboardText)
    }

    public var isRemote: Bool { true }

    /// `$img`'s Model: the one set in Settings (the default), then the
    /// vendor's other image models. Remembered per command, like any
    /// option.
    public var options: [ActionOption] {
        guard kind == .image else { return [] }
        let models = [model] + vendor.imageModels.filter { $0 != model }
        return [ActionOption(
            id: Self.modelOptionID, title: "Model", kind: .choice(models.map { ActionOption.Choice($0, title: $0) }),
            defaultValue: model)]
    }

    static let modelOptionID = "model"

    /// The model chosen in the options; Settings' model when the remembered
    /// one is no longer offered.
    func model(for options: ActionOptionValues) -> String {
        guard let option = self.options.first, case .choice(let choices) = option.kind else { return model }
        let chosen = options[option]
        return choices.contains { $0.value == chosen } ? chosen : model
    }

    /// Says what will be sent to whom. Nothing is sent here: the job
    /// sends the prompt.
    public func resolve(_ invocation: CommandInvocation) async throws -> CommandOutcome {
        guard let text = invocation.input.text, accepts(invocation.input) else { throw QuickActionError("\(title) needs a prompt") }
        let request: AIRequest = switch kind {
        case .ask: .text(model: model, instructions: nil, input: text)
        case .image: .image(model: model(for: invocation.options), prompt: text)
        }
        let what = switch kind {
        case .ask: "pastes the answer"
        case .image: "pastes the picture"
        }
        let named = kind == .image ? "\(model) unless another model is chosen with ⇥" : model
        return .job(plan: "Sends the text to \(vendor.name) (\(named)) and \(what).") { [send] _ in
            switch try await send(request).content {
            case .text(let answer): return .text(answer)
            case .image(let png): return .image(png)
            }
        }
    }
}
