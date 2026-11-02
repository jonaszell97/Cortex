import Foundation

/// OpenAI: text through the Responses API, pictures through the Images API.
/// Responses are not stored on OpenAI's side (`store: false`).
public struct OpenAIVendor: AIVendor {
    public let id = AIVendorID.openAI
    let apiKey: String
    let baseURL: URL
    let http: HTTPClient

    /// Picture generation can take well over a minute.
    static let timeout: TimeInterval = 300

    public init(apiKey: String, baseURL: URL = URL(string: "https://api.openai.com/v1/")!, http: @escaping HTTPClient) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.http = http
    }

    public func perform(_ request: AIRequest) async throws -> AIResponse {
        switch request {
        case .text(let model, let instructions, let input):
            var body: [String: Any] = ["model": model, "input": input, "store": false]
            if let instructions { body["instructions"] = instructions }
            return try await respond(model: model, body: body)

        case .json(let model, let instructions, let input, let schema):
            guard let parsed = try? JSONSerialization.jsonObject(with: Data(schema.json.utf8)) else {
                throw QuickActionError("The answer's schema is not valid JSON")
            }
            let format: [String: Any] = ["type": "json_schema", "name": schema.name, "schema": parsed, "strict": true]
            let body: [String: Any] = [
                "model": model, "instructions": instructions, "input": input, "store": false, "text": ["format": format],
            ]
            return try await respond(model: model, body: body)

        case .image(let model, let prompt):
            let body: [String: Any] = ["model": model, "prompt": prompt, "n": 1, "output_format": "png"]
            let response = try await post("images/generations", body: body, as: ImageResponse.self)
            guard let encoded = response.data.first?.b64JSON, let png = Data(base64Encoded: encoded) else {
                throw QuickActionError("OpenAI sent no picture")
            }
            let usage = AIUsage(
                vendor: id, model: model, inputTokens: response.usage?.inputTokens ?? 0,
                outputTokens: response.usage?.outputTokens ?? 0)
            return AIResponse(content: .image(png), usage: usage)
        }
    }

    /// A request to the Responses API, answered with its text.
    private func respond(model: String, body: [String: Any]) async throws -> AIResponse {
        let response = try await post("responses", body: body, as: TextResponse.self)
        let text = response.output
            .filter { $0.type == "message" }
            .flatMap { $0.content ?? [] }
            .filter { $0.type == "output_text" }
            .compactMap(\.text)
            .joined()
        guard !text.isEmpty else {
            if let reason = response.incompleteDetails?.reason {
                throw QuickActionError("OpenAI stopped without an answer (\(reason.replacingOccurrences(of: "_", with: " ")))")
            }
            throw QuickActionError("OpenAI sent no text")
        }
        let usage = AIUsage(
            vendor: id, model: model, inputTokens: response.usage?.inputTokens ?? 0,
            cachedInputTokens: response.usage?.inputTokensDetails?.cachedTokens ?? 0,
            outputTokens: response.usage?.outputTokens ?? 0)
        return AIResponse(content: .text(text), usage: usage)
    }

    private func post<Response: Decodable>(_ path: String, body: [String: Any], as type: Response.Type) async throws -> Response {
        var request = URLRequest(url: baseURL.appending(path: path), timeoutInterval: Self.timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await http(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw QuickActionError("Could not reach OpenAI: \(error.localizedDescription)")
        }
        guard (200..<300).contains(response.statusCode) else {
            throw Self.error(status: response.statusCode, body: data)
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw QuickActionError("OpenAI sent an answer Cortex cannot read")
        }
    }

    /// What the user should read for a failed request: OpenAI's own message
    /// where it sent one.
    static func error(status: Int, body: Data) -> QuickActionError {
        let message = (try? JSONDecoder().decode(ErrorResponse.self, from: body))?.error.message
        switch status {
        case 401:
            return QuickActionError("OpenAI rejected the API key. Check it in Settings → AI.")
        case 429:
            return QuickActionError(message.map { "OpenAI: \($0)" } ?? "OpenAI's rate limit or quota is reached")
        default:
            return QuickActionError(message.map { "OpenAI: \($0)" } ?? "OpenAI answered with HTTP \(status)")
        }
    }

    // MARK: - Wire format

    struct TextResponse: Decodable {
        struct Item: Decodable {
            let type: String
            let content: [Content]?
        }

        struct Content: Decodable {
            let type: String
            let text: String?
        }

        struct IncompleteDetails: Decodable {
            let reason: String?
        }

        struct Usage: Decodable {
            struct InputDetails: Decodable {
                let cachedTokens: Int?
                enum CodingKeys: String, CodingKey { case cachedTokens = "cached_tokens" }
            }

            let inputTokens: Int?
            let inputTokensDetails: InputDetails?
            let outputTokens: Int?

            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens", inputTokensDetails = "input_tokens_details", outputTokens = "output_tokens"
            }
        }

        let output: [Item]
        let incompleteDetails: IncompleteDetails?
        let usage: Usage?

        enum CodingKeys: String, CodingKey {
            case output, usage, incompleteDetails = "incomplete_details"
        }
    }

    struct ImageResponse: Decodable {
        struct Image: Decodable {
            let b64JSON: String?
            enum CodingKeys: String, CodingKey { case b64JSON = "b64_json" }
        }

        struct Usage: Decodable {
            let inputTokens: Int?
            let outputTokens: Int?
            enum CodingKeys: String, CodingKey { case inputTokens = "input_tokens", outputTokens = "output_tokens" }
        }

        let data: [Image]
        let usage: Usage?
    }

    struct ErrorResponse: Decodable {
        struct Detail: Decodable {
            let message: String?
        }

        let error: Detail
    }
}
