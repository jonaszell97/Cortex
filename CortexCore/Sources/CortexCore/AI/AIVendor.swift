import Foundation

/// The services the AI actions can send text to. Stable: the chosen vendor,
/// its API key's Keychain account and the usage totals are stored under the
/// raw value.
///
/// Another vendor is a case here, a type conforming to `AIVendor`, and its
/// list prices in `AIPricing`.
public enum AIVendorID: String, Sendable, Codable, CaseIterable, Identifiable {
    case openAI = "openai"

    public var id: Self { self }

    /// "OpenAI", for Settings and the palette.
    public var name: String {
        switch self {
        case .openAI: "OpenAI"
        }
    }

    public var defaultTextModel: String {
        switch self {
        case .openAI: "gpt-6-luna"
        }
    }

    public var defaultImageModel: String {
        switch self {
        case .openAI: "gpt-image-2.5-flare"
        }
    }

    /// The image models `$img` offers next to the one set in Settings.
    public var imageModels: [String] {
        switch self {
        case .openAI: ["gpt-image-2.5-flare", "gpt-image-2"]
        }
    }

    /// Where an API key is created.
    public var keysURL: URL {
        switch self {
        case .openAI: URL(string: "https://platform.openai.com/api-keys")!
        }
    }

    public func makeVendor(apiKey: String, http: @escaping HTTPClient = { try await URLSession.shared.send($0) }) -> any AIVendor {
        switch self {
        case .openAI: OpenAIVendor(apiKey: apiKey, http: http)
        }
    }
}

/// Sends a request and returns the body and the response, so tests can
/// answer without a network.
public typealias HTTPClient = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

extension URLSession {
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// One thing asked of a vendor.
public enum AIRequest: Sendable, Equatable {
    /// `input` answered under `instructions` (nil: the input is the whole
    /// prompt).
    case text(model: String, instructions: String?, input: String)
    /// A picture of what `prompt` describes.
    case image(model: String, prompt: String)
    /// `input` answered under `instructions` with JSON that fits `schema`
    /// (`$note`, `$todo`, `$tidy`). The answer is that JSON, as text.
    case json(model: String, instructions: String, input: String, schema: AIJSONSchema)

    public var model: String {
        switch self {
        case .text(let model, _, _), .image(let model, _), .json(let model, _, _, _): model
        }
    }
}

/// The shape a `.json` answer must have: a JSON Schema in the strict subset
/// the vendors enforce (every property required, optional ones nullable, no
/// other properties).
public struct AIJSONSchema: Sendable, Equatable {
    /// Letters, digits, `_` and `-`: "knowledge_note".
    public var name: String
    /// The schema, as JSON.
    public var json: String

    public init(name: String, json: String) {
        self.name = name
        self.json = json
    }
}

/// A vendor's answer and what it was billed for.
public struct AIResponse: Sendable, Equatable {
    public enum Content: Sendable, Equatable {
        case text(String)
        /// PNG data.
        case image(Data)
    }

    public var content: Content
    public var usage: AIUsage

    public init(content: Content, usage: AIUsage) {
        self.content = content
        self.usage = usage
    }
}

/// Tokens one request was billed for, as the vendor reported them.
public struct AIUsage: Sendable, Equatable, Codable {
    public var vendor: AIVendorID
    public var model: String
    /// All input tokens, cached ones included.
    public var inputTokens: Int
    /// The part of `inputTokens` read from the vendor's prompt cache.
    public var cachedInputTokens: Int
    /// Text, reasoning or image tokens produced.
    public var outputTokens: Int

    public init(vendor: AIVendorID, model: String, inputTokens: Int, cachedInputTokens: Int = 0, outputTokens: Int) {
        self.vendor = vendor
        self.model = model
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
    }
}

/// A service that answers `AIRequest`s. Errors meant for the user are
/// `QuickActionError`s.
public protocol AIVendor: Sendable {
    var id: AIVendorID { get }
    func perform(_ request: AIRequest) async throws -> AIResponse
}
