import Foundation
import Testing
@testable import CortexCore

/// Answers every request with one canned response and keeps what was sent.
final class CannedHTTP: @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [URLRequest] = []
    let status: Int
    let body: Data

    init(status: Int = 200, json: String) {
        self.status = status
        body = Data(json.utf8)
    }

    var requests: [URLRequest] { lock.withLock { sent } }

    /// The JSON body of the last request.
    var lastBody: [String: Any] {
        guard let data = requests.last?.httpBody else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    var client: HTTPClient {
        { [self] request in
            lock.withLock { sent.append(request) }
            return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }
}

@Suite struct OpenAIVendorTests {
    static let textAnswer = """
        {"id": "resp_1", "status": "completed",
         "output": [
           {"type": "reasoning", "summary": []},
           {"type": "message", "role": "assistant",
            "content": [{"type": "output_text", "text": "Hello, "}, {"type": "output_text", "text": "world."}]}
         ],
         "usage": {"input_tokens": 120, "input_tokens_details": {"cached_tokens": 20},
                   "output_tokens": 30, "output_tokens_details": {"reasoning_tokens": 10}, "total_tokens": 150}}
        """

    @Test func textGoesToTheResponsesAPI() async throws {
        let http = CannedHTTP(json: Self.textAnswer)
        let vendor = OpenAIVendor(apiKey: "sk-test", http: http.client)
        let response = try await vendor.perform(.text(model: "gpt-6-luna", instructions: "Fix it.", input: "helo wrld"))

        #expect(response.content == .text("Hello, world."))
        #expect(response.usage == AIUsage(vendor: .openAI, model: "gpt-6-luna", inputTokens: 120, cachedInputTokens: 20, outputTokens: 30))
        let request = try #require(http.requests.first)
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        let body = http.lastBody
        #expect(body["model"] as? String == "gpt-6-luna")
        #expect(body["instructions"] as? String == "Fix it.")
        #expect(body["input"] as? String == "helo wrld")
        #expect(body["store"] as? Bool == false, "not kept at OpenAI")
    }

    @Test func jsonAnswersAreAskedForWithAStrictSchema() async throws {
        let http = CannedHTTP(json: Self.textAnswer)
        let schema = AIJSONSchema(name: "answer", json: #"{"type": "object", "properties": {}, "required": [], "additionalProperties": false}"#)
        let response = try await OpenAIVendor(apiKey: "sk", http: http.client)
            .perform(.json(model: "m", instructions: "File it.", input: "text", schema: schema))
        #expect(response.content == .text("Hello, world."))
        let body = http.lastBody
        #expect(body["instructions"] as? String == "File it.")
        #expect(body["input"] as? String == "text")
        #expect(body["store"] as? Bool == false)
        let format = try #require((body["text"] as? [String: Any])?["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        #expect(format["name"] as? String == "answer")
        #expect(format["strict"] as? Bool == true)
        #expect((format["schema"] as? [String: Any])?["type"] as? String == "object")
    }

    @Test func askSendsNoInstructions() async throws {
        let http = CannedHTTP(json: Self.textAnswer)
        _ = try await OpenAIVendor(apiKey: "sk", http: http.client).perform(.text(model: "m", instructions: nil, input: "Why?"))
        #expect(http.lastBody["instructions"] == nil)
        #expect(http.lastBody["input"] as? String == "Why?")
    }

    @Test func imagesGoToTheImagesAPI() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        let http = CannedHTTP(json: """
            {"created": 1, "data": [{"b64_json": "\(png.base64EncodedString())"}],
             "usage": {"input_tokens": 12, "input_tokens_details": {"text_tokens": 12, "image_tokens": 0},
                       "output_tokens": 4160, "total_tokens": 4172}}
            """)
        let response = try await OpenAIVendor(apiKey: "sk", http: http.client)
            .perform(.image(model: "gpt-image-2.5-flare", prompt: "A red fox"))

        #expect(response.content == .image(png))
        #expect(response.usage == AIUsage(vendor: .openAI, model: "gpt-image-2.5-flare", inputTokens: 12, outputTokens: 4160))
        #expect(http.requests.first?.url?.absoluteString == "https://api.openai.com/v1/images/generations")
        #expect(http.lastBody["prompt"] as? String == "A red fox")
        #expect(http.lastBody["n"] as? Int == 1)
        #expect(http.lastBody["output_format"] as? String == "png")
    }

    @Test func errorsSayWhatOpenAISaid() async {
        let rejected = CannedHTTP(status: 401, json: #"{"error": {"message": "Incorrect API key provided: sk-***"}}"#)
        await #expect(throws: QuickActionError("OpenAI rejected the API key. Check it in Settings → AI.")) {
            try await OpenAIVendor(apiKey: "sk", http: rejected.client).perform(.text(model: "m", instructions: nil, input: "x"))
        }
        let bad = CannedHTTP(status: 400, json: #"{"error": {"message": "The model `gpt-7` does not exist."}}"#)
        await #expect(throws: QuickActionError("OpenAI: The model `gpt-7` does not exist.")) {
            try await OpenAIVendor(apiKey: "sk", http: bad.client).perform(.text(model: "gpt-7", instructions: nil, input: "x"))
        }
        let broken = CannedHTTP(status: 502, json: "<html>Bad gateway</html>")
        await #expect(throws: QuickActionError("OpenAI answered with HTTP 502")) {
            try await OpenAIVendor(apiKey: "sk", http: broken.client).perform(.text(model: "m", instructions: nil, input: "x"))
        }
    }

    @Test func anAnswerWithoutTextSaysWhy() async {
        let http = CannedHTTP(json: #"{"output": [], "status": "incomplete", "incomplete_details": {"reason": "max_output_tokens"}}"#)
        await #expect(throws: QuickActionError("OpenAI stopped without an answer (max output tokens)")) {
            try await OpenAIVendor(apiKey: "sk", http: http.client).perform(.text(model: "m", instructions: nil, input: "x"))
        }
    }
}

@Suite struct AIPricingTests {
    @Test func defaultModelsHavePrices() {
        for vendor in AIVendorID.allCases {
            #expect(AIPricing.price(of: vendor.defaultTextModel, vendor: vendor) != nil)
            #expect(AIPricing.price(of: vendor.defaultImageModel, vendor: vendor) != nil)
        }
    }

    @Test func costCountsCachedInputAtItsOwnPrice() throws {
        // 1M input, a quarter of it cached, and 2M output.
        let usage = AIUsage(vendor: .openAI, model: "gpt-6-luna", inputTokens: 1_000_000, cachedInputTokens: 250_000, outputTokens: 2_000_000)
        let cost = try #require(AIPricing.cost(of: usage))
        #expect(abs(cost - (0.75 * 0.10 + 0.25 * 0.01 + 2 * 0.50)) < 1e-9)
    }

    @Test func snapshotsCostLikeTheirModel() {
        #expect(AIPricing.price(of: "gpt-image-2.5-flare-2026-09-08", vendor: .openAI) == AIPricing.price(of: "gpt-image-2.5-flare", vendor: .openAI))
        #expect(AIPricing.price(of: "GPT-6-Luna", vendor: .openAI) != nil)
        #expect(AIPricing.price(of: "gpt-6-luna-pro", vendor: .openAI) == nil, "another model, not a snapshot")
        #expect(AIPricing.price(of: "my-finetune", vendor: .openAI) == nil)
    }

    @Test func totalsAddUpByModel() {
        var totals = AIUsageTotals(since: Date(timeIntervalSince1970: 0))
        totals.add(AIUsage(vendor: .openAI, model: "gpt-6-luna", inputTokens: 1_000_000, outputTokens: 0))
        totals.add(AIUsage(vendor: .openAI, model: "gpt-6-luna", inputTokens: 0, outputTokens: 1_000_000))
        totals.add(AIUsage(vendor: .openAI, model: "my-finetune", inputTokens: 500, outputTokens: 50))

        #expect(totals.entries.map(\.model) == ["gpt-6-luna", "my-finetune"])
        #expect(totals.entries[0].requests == 2)
        #expect(totals.entries[0].inputTokens == 1_000_000 && totals.entries[0].outputTokens == 1_000_000)
        #expect(abs(totals.estimatedCost - 0.60) < 1e-9)
        #expect(totals.entries[1].unpricedRequests == 1 && totals.entries[1].estimatedCost == 0)
        #expect(totals.requests == 3 && totals.unpricedRequests == 1)

        let decoded = try? JSONDecoder().decode(AIUsageTotals.self, from: JSONEncoder().encode(totals))
        #expect(decoded == totals)
    }
}

/// Records what the AI actions and commands send, and answers.
final class AIRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [AIRequest] = []
    var answer = AIResponse.Content.text("  Fixed.\n\n")

    var sent: [AIRequest] { lock.withLock { requests } }

    var send: @Sendable (AIRequest) async throws -> AIResponse {
        { [self] request in
            lock.withLock { requests.append(request) }
            return AIResponse(content: answer, usage: AIUsage(vendor: .openAI, model: request.model, inputTokens: 1, outputTokens: 1))
        }
    }
}

private func context() -> ActionContext {
    ActionContext(fallbackOutputDirectory: URL(filePath: "/tmp"), temporaryDirectory: URL(filePath: "/tmp"))
}

@Suite struct AIActionTests {
    let recorder = AIRecorder()
    var actions: [AIAction] { AIAction.all(vendor: .openAI, textModel: "text-model", send: recorder.send) }

    func action(_ kind: AIAction.Kind) -> AIAction { actions.first { $0.kind == kind }! }

    func run(_ kind: AIAction.Kind, _ text: String) async throws -> ActionOutput {
        try await action(kind).run(.text(text), context: context())
    }

    @Test func idsAreStableAndApartFromTheBuiltIns() {
        #expect(actions.map(\.id) == ["ai.proofread", "ai.summarize"])
        let builtIns = Set(ActionCatalog.builtIns.map(\.id))
        #expect(actions.allSatisfy { !builtIns.contains($0.id) })
        #expect(actions.allSatisfy { $0.matches(.text("Hi")) }, "offered on any text")
    }

    @Test func remoteNeverInstantAndOnlyOnText() {
        for action in actions {
            #expect(action.isRemote && !action.isInstant)
            #expect(action.accepts(.text("Hi")))
            #expect(!action.accepts(.text(" \n ")))
            #expect(!action.accepts(.none) && !action.accepts(.image(Data())) && !action.accepts(.files([URL(filePath: "/a")])))
        }
        #expect(ActionCatalog.builtIns.allSatisfy { !$0.isRemote })
    }

    @Test func planNamesTheServiceAndModel() {
        #expect(action(.proofread).plan(for: .text("x")) == "Sends the text to OpenAI (text-model) and pastes the corrected text.")
    }

    @Test func proofreadAndSummarizeSendInstructions() async throws {
        #expect(try await run(.proofread, "Fixd.") == .text("Fixed."), "trimmed like the input")
        #expect(try await run(.summarize, "Long text\n") == .text("Fixed.\n"), "keeps a final line break")
        guard case .text(let model, let instructions?, let input) = recorder.sent.first else {
            Issue.record("no instructions sent")
            return
        }
        #expect(model == "text-model" && input == "Fixd.")
        #expect(instructions.contains("Proofread"))
        guard case .text(_, let summary?, _) = recorder.sent.last else { return }
        #expect(summary.contains("Summarize"))
    }
}

@Suite struct AICommandTests {
    let recorder = AIRecorder()
    var commands: [AICommand] {
        AICommand.all(vendor: .openAI, textModel: "text-model", imageModel: "image-model", send: recorder.send)
    }

    func command(_ kind: AICommand.Kind) -> AICommand { commands.first { $0.kind == kind }! }

    func run(_ kind: AICommand.Kind, _ text: String) async throws -> ActionOutput {
        try await command(kind).output(.text(text), context: context())
    }

    /// The plan of the job a command resolves to; nothing is sent for it.
    func plan(_ kind: AICommand.Kind, _ text: String = "x") async throws -> String {
        guard case .job(let plan, _) = try await command(kind).resolve(.text(text)) else { throw QuickActionError("not a job") }
        #expect(recorder.sent.isEmpty, "resolving contacts nobody")
        return plan
    }

    @Test func namesAndIDsAreThoseOfTheActionsTheyWere() {
        #expect(commands.map(\.id) == ["ai.ask", "ai.image"], "usage counts carry over")
        #expect(commands.map(\.name) == ["ask", "img"])
        let builtIns = Set(CommandCatalog.builtIns.map(\.name))
        #expect(commands.allSatisfy { !builtIns.contains($0.name) })
        #expect(CommandCatalog.problems(in: CommandCatalog.builtIns + commands).isEmpty)
    }

    @Test func thePromptIsTypedAndOnlySuggestedFromTheClipboard() throws {
        for command in commands {
            let argument = try #require(command.argument)
            #expect(argument.kind == .prompt)
            #expect(argument.isRequired)
            #expect(argument.suggestions == .clipboardText)
            #expect(!command.matches(.text("Hi")), "never offered in > on the clipboard")
            #expect(command.isRemote)
            #expect(!command.accepts(.none) && !command.accepts(.text("  ")))
        }
        #expect(command(.ask).usage == "ask why is the sky blue")
    }

    @Test func planNamesTheServiceAndModel() async throws {
        #expect(try await plan(.ask) == "Sends the text to OpenAI (text-model) and pastes the answer.")
        #expect(try await plan(.image).contains("(image-model unless"))
    }

    @Test func theyResolveToJobsAndSendNothingUntilTheJobRuns() async throws {
        for kind in AICommand.Kind.allCases {
            let outcome = try await command(kind).resolve(.text("A fox"))
            #expect(outcome.kind == .job)
            #expect(recorder.sent.isEmpty, "\(kind): resolving contacts nobody")
            #expect(CommandAction(command(kind), outcome: outcome).isInstant == false, "it runs in the background")
        }
        await #expect(throws: QuickActionError("Ask AI needs a prompt")) { try await command(.ask).resolve(.text("  ")) }
        guard case .job(_, let run) = try await command(.ask).resolve(.text("Hi")) else { throw QuickActionError("not a job") }
        #expect(recorder.sent.isEmpty)
        _ = try await run(context())
        #expect(recorder.sent == [.text(model: "text-model", instructions: nil, input: "Hi")], "the job sends it")
    }

    @Test func generateImageOffersTheVendorsImageModels() throws {
        #expect(command(.ask).options.isEmpty)
        let option = try #require(command(.image).options.first)
        #expect(option.id == "model")
        #expect(option.defaultValue == "image-model", "the model set in Settings")
        #expect(option.kind == .choice(["image-model", "gpt-image-2.5-flare", "gpt-image-2"].map { ActionOption.Choice($0, title: $0) }))

        let flare = AICommand(.image, vendor: .openAI, model: "gpt-image-2.5-flare", send: recorder.send)
        guard case .choice(let choices) = flare.options.first?.kind else { throw QuickActionError("no choice") }
        #expect(choices.map(\.value) == ["gpt-image-2.5-flare", "gpt-image-2"], "no duplicate")
    }

    @Test func generateImageUsesTheChosenModel() async throws {
        recorder.answer = .image(Data([1]))
        let image = command(.image)
        let option = try #require(image.options.first)
        var options = ActionOptionValues()
        options[option] = "gpt-image-2"
        let chosen = ActionContext(
            fallbackOutputDirectory: URL(filePath: "/tmp"), temporaryDirectory: URL(filePath: "/tmp"), options: options)
        _ = try await image.output(.text("A fox"), context: chosen)
        options[option] = "gone-model"
        let stale = ActionContext(
            fallbackOutputDirectory: URL(filePath: "/tmp"), temporaryDirectory: URL(filePath: "/tmp"), options: options)
        _ = try await image.output(.text("A fox"), context: stale)
        #expect(recorder.sent == [
            .image(model: "gpt-image-2", prompt: "A fox"),
            .image(model: "image-model", prompt: "A fox"),
        ], "a remembered model no longer offered falls back to Settings'")
    }

    @Test func askSendsThePromptAsItIs() async throws {
        #expect(try await run(.ask, "What is 2+2?") == .text("  Fixed.\n\n"), "answers are pasted as they come")
        #expect(recorder.sent == [.text(model: "text-model", instructions: nil, input: "What is 2+2?")])
    }

    @Test func generateImageReturnsThePicture() async throws {
        recorder.answer = .image(Data([1, 2, 3]))
        #expect(try await run(.image, "A red fox") == .image(Data([1, 2, 3])))
        #expect(recorder.sent == [.image(model: "image-model", prompt: "A red fox")])
    }
}
