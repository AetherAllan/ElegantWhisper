@testable import ElegantWhisper
import Foundation
import XCTest

final class LLMRefinerTests: XCTestCase {
    func testRefinementMetricsSummaryLine() {
        let start = ContinuousClock().now
        var metrics = RefinementMetrics(asrFinalizedIn: .milliseconds(420), requestStartedAt: start)
        metrics.firstByteAt = start.advanced(by: .milliseconds(780))
        metrics.completedAt = start.advanced(by: .milliseconds(1_290))

        XCTAssertEqual(
            metrics.summaryLine(),
            "polishMetrics ASR finalize: 420 ms | LLM TTFB: 780 ms | LLM generation: 510 ms | Total polish: 1.29 s"
        )
    }

    func testAcceptsSmallConservativeCorrection() {
        let refiner = LLMRefiner(settings: .shared)

        XCTAssertNil(refiner.rejectionReason(original: "我在写配森和杰森", corrected: "我在写 Python 和 JSON", finishReason: nil))
    }

    func testAcceptsLightPunctuationCorrection() {
        let refiner = LLMRefiner(settings: .shared)

        XCTAssertNil(refiner.rejectionReason(original: "今天很好我们继续", corrected: "今天很好，我们继续。", finishReason: nil))
    }

    func testRejectsEmptyCorrection() {
        let refiner = LLMRefiner(settings: .shared)

        XCTAssertEqual(refiner.rejectionReason(original: "hello world", corrected: "", finishReason: nil), .empty)
    }

    func testRejectsLargeRewrite() {
        let refiner = LLMRefiner(settings: .shared)

        XCTAssertEqual(
            refiner.rejectionReason(
                original: "打开设置",
                corrected: "下面是一个完整的操作指南，第一步打开系统设置，第二步找到隐私权限，第三步逐项检查。",
                finishReason: nil
            ),
            .tooLong
        )
    }

    func testAllowsShorterCorrectionWhenEditIsStillConservative() {
        let refiner = LLMRefiner(settings: .shared)

        XCTAssertNil(refiner.rejectionReason(
            original: "abcdefghijklmnopqrst",
            corrected: "abcdefghi",
            finishReason: nil
        ))
    }

    func testRejectsHighEditRatioWithReason() {
        let refiner = LLMRefiner(settings: .shared)

        XCTAssertEqual(
            refiner.rejectionReason(original: "请打开设置页面", corrected: "明天去买咖啡豆", finishReason: nil),
            .editRatio
        )
    }

    func testRejectsTruncatedLLMChoice() {
        let refiner = LLMRefiner(settings: .shared)
        let choice = ChatResponse.Choice(
            message: ChatMessage(role: "assistant", content: "这是被截断的前半段"),
            finishReason: "length"
        )

        XCTAssertEqual(
            refiner.rejectionReason(
                original: "这是一个比较长的原始转写，不能因为模型截断就丢掉后半段。",
                corrected: refiner.normalizeModelOutput(choice.message.content ?? ""),
                finishReason: choice.finishReason
            ),
            .finishLength
        )
    }

    func testRejectsNullContentFromReasoningOnlyProviderResponse() throws {
        let json = """
        {
          "model": "reasoning-model",
          "choices": [
            {
              "message": { "role": "assistant", "content": null, "reasoning": "thinking only" },
              "finish_reason": "length"
            }
          ]
        }
        """
        let response = try JSONDecoder().decode(ChatResponse.self, from: Data(json.utf8))
        let choice = response.choices[0]

        XCTAssertEqual(
            LLMRefiner(settings: .shared).rejectionReason(
                original: "我想用配森解析杰森",
                corrected: choice.message.content ?? "",
                finishReason: choice.finishReason
            ),
            .finishLength
        )
    }

    func testProviderErrorReasonClassifiesFreeDailyLimitWithoutLoggingBody() {
        let data = Data("""
        {
          "error": {
            "message": "Rate limit exceeded: free-models-per-day. Add credits.",
            "code": 429
          },
          "user_id": "should-not-be-logged"
        }
        """.utf8)

        XCTAssertEqual(LLMProviderErrorReason.classify(data), "free-models-per-day")
    }

    func testAcceptsWrappedModelCorrection() {
        let refiner = LLMRefiner(settings: .shared)
        let choice = ChatResponse.Choice(
            message: ChatMessage(role: "assistant", content: "Corrected text: “我在写 Python 和 JSON”"),
            finishReason: "stop"
        )
        let corrected = refiner.normalizeModelOutput(choice.message.content ?? "")

        XCTAssertNil(refiner.rejectionReason(original: "我在写配森和杰森", corrected: corrected, finishReason: choice.finishReason))
        XCTAssertEqual(corrected, "我在写 Python 和 JSON")
    }

    func testProviderInfersOpenRouterFromExistingBaseURL() {
        let settings = makeSettings()
        settings.apiBaseURL = "https://openrouter.ai/api/v1"

        XCTAssertEqual(settings.llmProvider, .openRouterFree)
    }

    func testOpenRouterRequestAddsAttributionHeaderWithoutDictionaryHotwords() throws {
        let settings = makeSettings()
        let stylePacks = try makeStylePackStore()
        settings.llmProvider = .openRouterFree
        settings.apiBaseURL = "https://openrouter.ai/api/v1"
        settings.model = "openrouter/free"
        settings.apiKey = "test-key"
        defer { settings.apiKey = "" }

        let request = try XCTUnwrap(LLMRefiner(settings: settings, stylePacks: stylePacks).makeRequest(text: "我想用配森解析杰森"))

        XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
        XCTAssertEqual(request.timeoutInterval, 25)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-OpenRouter-Title"), AppConstants.productName)

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "nvidia/nemotron-3-nano-30b-a3b:free")
        XCTAssertEqual(json["max_tokens"] as? Int, 192)
        let reasoning = try XCTUnwrap(json["reasoning"] as? [String: Any])
        XCTAssertEqual(reasoning["effort"] as? String, "none")
        XCTAssertEqual(reasoning["exclude"] as? Bool, true)
        let responseFormat = try XCTUnwrap(json["response_format"] as? [String: Any])
        XCTAssertEqual(responseFormat["type"] as? String, "json_schema")
        let jsonSchema = try XCTUnwrap(responseFormat["json_schema"] as? [String: Any])
        XCTAssertEqual(jsonSchema["name"] as? String, "dictation_polish_result")
        XCTAssertEqual(jsonSchema["strict"] as? Bool, true)
        let schema = try XCTUnwrap(jsonSchema["schema"] as? [String: Any])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        XCTAssertEqual(schema["required"] as? [String], ["corrected_text"])

        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let systemPrompt = try XCTUnwrap(messages.first?["content"] as? String)
        XCTAssertFalse(systemPrompt.contains("User dictionary"))
        XCTAssertFalse(systemPrompt.contains(LLMPromptBuilder.hotwordPlaceholder))
    }

    func testOldOpenRouterFreeRouterSettingUsesStableFreeModel() {
        let settings = makeSettings()
        settings.llmProvider = .openRouterFree
        settings.model = "openrouter/free"

        XCTAssertEqual(settings.model, "nvidia/nemotron-3-nano-30b-a3b:free")
    }

    func testLongRequestGetsLargerOutputBudget() throws {
        let settings = makeSettings()
        let stylePacks = try makeStylePackStore()
        settings.apiKey = "test-key"
        defer { settings.apiKey = "" }

        let longText = String(repeating: "这是一段较长的语音转写内容，", count: 80)
        let request = try XCTUnwrap(LLMRefiner(settings: settings, stylePacks: stylePacks).makeRequest(text: longText))
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])

        XCTAssertGreaterThan(json["max_tokens"] as? Int ?? 0, 256)
    }

    func testPlainTextProviderDoesNotSendStructuredResponseFormat() throws {
        let settings = makeSettings()
        let stylePacks = try makeStylePackStore()
        settings.llmProvider = .openAI
        settings.apiKey = "test-key"
        defer { settings.apiKey = "" }

        let request = try XCTUnwrap(LLMRefiner(settings: settings, stylePacks: stylePacks).makeRequest(text: "我想用配森解析杰森"))
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])

        XCTAssertNil(json["response_format"])
        XCTAssertNil(json["reasoning"])
    }

    func testStructuredOutputExtractsCorrectedText() throws {
        let provider = OpenRouterProvider()
        let data = try chatResponseData(content: #"{"corrected_text":"我用 Python 解析 JSON。"}"#)

        let parsed = try XCTUnwrap(provider.parseResponse(data: data, mode: .structuredOutput))

        XCTAssertEqual(parsed.candidateText, "我用 Python 解析 JSON。")
    }

    func testStructuredOutputDecodeFailureFallsBackToRawContent() throws {
        let provider = OpenRouterProvider()
        let refiner = LLMRefiner(settings: .shared)
        let data = try chatResponseData(content: "Corrected text: “我用 Python 解析 JSON。”")

        let parsed = try XCTUnwrap(provider.parseResponse(data: data, mode: .structuredOutput))

        XCTAssertEqual(refiner.normalizeModelOutput(parsed.candidateText), "我用 Python 解析 JSON。")
    }

    func testStructuredOutputStillRejectsTooLongCorrection() throws {
        let provider = OpenRouterProvider()
        let refiner = LLMRefiner(settings: .shared)
        let longCorrection = String(repeating: "很长", count: 80)
        let data = try chatResponseData(content: #"{"corrected_text":"\#(longCorrection)"}"#)

        let parsed = try XCTUnwrap(provider.parseResponse(data: data, mode: .structuredOutput))

        XCTAssertEqual(
            refiner.rejectionReason(original: "短句", corrected: parsed.candidateText, finishReason: parsed.finishReason),
            .tooLong
        )
    }

    func testStructuredOutputFinishLengthStillRejected() throws {
        let provider = OpenRouterProvider()
        let refiner = LLMRefiner(settings: .shared)
        let data = try chatResponseData(content: #"{"corrected_text":"我用 Python"}"#, finishReason: "length")

        let parsed = try XCTUnwrap(provider.parseResponse(data: data, mode: .structuredOutput))

        XCTAssertEqual(
            refiner.rejectionReason(original: "我用配森", corrected: parsed.candidateText, finishReason: parsed.finishReason),
            .finishLength
        )
    }

    func testStructuredUnsupportedFallsBackAndCachesModel() throws {
        let cache = makeCapabilityCache()
        let provider = OpenRouterProvider(capabilityCache: cache)
        let context = providerContext(model: "test/model:free")
        let data = Data("""
        {
          "error": {
            "message": "unsupported response_format json_schema",
            "code": "invalid_request"
          }
        }
        """.utf8)

        let fallback = provider.fallbackMode(
            afterHTTPStatus: 400,
            data: data,
            mode: .structuredOutput,
            context: context
        )

        XCTAssertEqual(fallback, .plainText)
        XCTAssertFalse(cache.supportsStructuredOutput(for: .openRouterFree, model: "test/model:free"))
        XCTAssertEqual(provider.firstMode(for: context), .plainText)
    }

    func testStructuredUnsupportedCacheSkipsResponseFormatInRequest() throws {
        let settings = makeSettings()
        let stylePacks = try makeStylePackStore()
        let cache = makeCapabilityCache()
        settings.llmProvider = .openRouterFree
        settings.apiBaseURL = "https://openrouter.ai/api/v1"
        settings.model = "test/model:free"
        settings.apiKey = "test-key"
        defer { settings.apiKey = "" }
        cache.markStructuredOutputUnsupported(provider: .openRouterFree, model: "test/model:free")

        let request = try XCTUnwrap(LLMRefiner(
            settings: settings,
            stylePacks: stylePacks,
            capabilityCache: cache
        ).makeRequest(text: "我想用配森解析杰森"))
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])

        XCTAssertNil(json["response_format"])
    }

    func testGenericUnsupportedParameterDoesNotDisableStructuredOutput() throws {
        let cache = makeCapabilityCache()
        let provider = OpenRouterProvider(capabilityCache: cache)
        let context = providerContext(model: "test/model:free")
        let data = Data("""
        {
          "error": {
            "message": "unsupported parameter: reasoning",
            "code": "invalid_request"
          }
        }
        """.utf8)

        let fallback = provider.fallbackMode(
            afterHTTPStatus: 400,
            data: data,
            mode: .structuredOutput,
            context: context
        )

        XCTAssertNil(fallback)
        XCTAssertTrue(cache.supportsStructuredOutput(for: .openRouterFree, model: "test/model:free"))
    }

    @MainActor
    func testConnectionFallsBackToPlainWhenStructuredOutputIsUnsupported() async throws {
        let settings = makeSettings()
        let stylePacks = try makeStylePackStore()
        let cache = makeCapabilityCache()
        let protocolClass = TestConnectionURLProtocol.self
        protocolClass.reset(responses: [
            (
                400,
                """
                {"error":{"message":"unsupported response_format json_schema","code":"invalid_request"}}
                """
            ),
            (
                200,
                """
                {"model":"test/model:free","choices":[{"message":{"role":"assistant","content":"我用 Python 解析 JSON。"},"finish_reason":"stop"}]}
                """
            )
        ])
        defer { protocolClass.reset(responses: []) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [protocolClass]
        let session = URLSession(configuration: configuration)
        settings.llmProvider = .openRouterFree
        settings.apiBaseURL = "https://openrouter.ai/api/v1"
        settings.model = "test/model:free"
        settings.apiKey = "test-key"
        defer { settings.apiKey = "" }

        let finished = expectation(description: "test connection")
        var result: (Bool, String)?
        LLMRefiner(
            settings: settings,
            stylePacks: stylePacks,
            capabilityCache: cache,
            urlSession: session
        ).testConnection { ok, message in
            result = (ok, message)
            finished.fulfill()
        }

        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(result?.0, true)
        XCTAssertEqual(result?.1, "Connection OK (test/model:free)")
        XCTAssertFalse(cache.supportsStructuredOutput(for: .openRouterFree, model: "test/model:free"))
        let bodies = protocolClass.requestBodies()
        XCTAssertEqual(bodies.count, 2)
        XCTAssertTrue(bodies[0].contains("\"response_format\""))
        XCTAssertFalse(bodies[1].contains("\"response_format\""))
    }

    func testShortInputStillBuildsRefinementRequest() throws {
        let settings = makeSettings()
        let stylePacks = try makeStylePackStore()
        settings.apiKey = "test-key"
        defer { settings.apiKey = "" }

        let request = try XCTUnwrap(LLMRefiner(settings: settings, stylePacks: stylePacks).makeRequest(text: "好"))
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])

        XCTAssertEqual(json["max_tokens"] as? Int, 192)
    }

    func testOutputBudgetIgnoresSystemPromptLength() throws {
        let settings = makeSettings()
        let stylePacks = try makeStylePackStore()
        settings.apiKey = "test-key"
        defer { settings.apiKey = "" }

        var pack = StylePackStore.builtinPacks[0]
        pack.active = true
        pack.systemPrompt = "\(String(repeating: "System prompt sentence. ", count: 500))\n\n\(LLMPromptBuilder.hotwordPlaceholder)"
        stylePacks.save(pack)

        let userText = String(repeating: "a", count: 80)
        let request = try XCTUnwrap(LLMRefiner(settings: settings, stylePacks: stylePacks).makeRequest(text: userText))
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])

        XCTAssertEqual(json["max_tokens"] as? Int, 320)
    }

    func testPromptKeepsConservativeBoundary() {
        let prompt = LLMPromptBuilder.systemPrompt(template: LLMPromptBuilder.conservativeTemplate)

        XCTAssertTrue(prompt.contains("punctuation"))
        XCTAssertTrue(prompt.contains("light formatting"))
        XCTAssertTrue(prompt.contains("Do not expand"))
        XCTAssertTrue(prompt.contains("summarize"))
        XCTAssertTrue(prompt.contains("translate"))
        XCTAssertTrue(prompt.contains("answer questions"))
        XCTAssertTrue(prompt.contains("change meaning"))
        XCTAssertTrue(prompt.contains("Do not include explanations"))
        XCTAssertTrue(prompt.contains("very short input"))
        XCTAssertFalse(prompt.contains("User dictionary"))
        XCTAssertFalse(prompt.contains(LLMPromptBuilder.hotwordPlaceholder))
    }

    func testProgrammerStylePackIsDefaultInRequest() throws {
        let settings = makeSettings()
        let stylePacks = try makeStylePackStore()
        settings.apiKey = "test-key"
        defer { settings.apiKey = "" }

        let request = try XCTUnwrap(LLMRefiner(settings: settings, stylePacks: stylePacks).makeRequest(text: "我是外部三程序员"))
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let systemPrompt = try XCTUnwrap(messages.first?["content"] as? String)

        XCTAssertTrue(systemPrompt.contains("developer dictation"))
        XCTAssertTrue(systemPrompt.contains("Web3"))
        XCTAssertTrue(systemPrompt.contains("TypeScript"))
        XCTAssertTrue(systemPrompt.contains("SQL"))
        XCTAssertTrue(systemPrompt.contains("PostgreSQL"))
        XCTAssertTrue(systemPrompt.contains("我是一个 Web3 程序员"))
        XCTAssertTrue(systemPrompt.contains("我同事还会写 SQL"))
    }

    func testActiveStylePackPromptIsUsedInRequest() throws {
        let settings = makeSettings()
        let stylePacks = try makeStylePackStore()
        settings.apiKey = "test-key"
        defer { settings.apiKey = "" }

        var pack = StylePackStore.builtinPacks[1]
        pack.active = true
        pack.systemPrompt = "Custom prompt.\n\n\(LLMPromptBuilder.hotwordPlaceholder)"
        stylePacks.save(pack)

        let request = try XCTUnwrap(LLMRefiner(settings: settings, stylePacks: stylePacks).makeRequest(text: "配森"))
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let systemPrompt = try XCTUnwrap(messages.first?["content"] as? String)

        XCTAssertTrue(systemPrompt.contains("Custom prompt."))
        XCTAssertFalse(systemPrompt.contains("Python"))
        XCTAssertFalse(systemPrompt.contains("developer dictation"))
        XCTAssertFalse(systemPrompt.contains(LLMPromptBuilder.hotwordPlaceholder))
    }

    func testPromptDoesNotAppendDictionaryBlockWhenPlaceholderIsMissing() {
        let prompt = LLMPromptBuilder.systemPrompt(template: "Custom prompt only.")

        XCTAssertEqual(prompt, "Custom prompt only.")
        XCTAssertFalse(prompt.contains("User dictionary"))
    }

    func testPromptStaticContextCacheKeyIsStableForSameStyle() {
        let pack = StylePackStore.builtinPacks[0]

        let first = PromptStaticContextCache.cacheKey(stylePack: pack)
        let second = PromptStaticContextCache.cacheKey(stylePack: pack)

        XCTAssertEqual(first, second)
    }

    func testPromptStaticContextCacheKeyChangesWhenStyleChanges() {
        var pack = StylePackStore.builtinPacks[0]
        let first = PromptStaticContextCache.cacheKey(stylePack: pack)
        pack.systemPrompt += "\nExtra rule."

        let second = PromptStaticContextCache.cacheKey(stylePack: pack)

        XCTAssertNotEqual(first, second)
    }

    func testPromptStaticContextKeepsTranscriptDynamicAndLast() {
        let transcript = "我想用配森解析杰森"
        let context = PromptStaticContextCache.context(stylePack: StylePackStore.builtinPacks[0])
        let messages = context.messages(transcript: transcript)

        XCTAssertFalse(context.systemPrompt.contains(transcript))
        XCTAssertFalse(context.systemPrompt.contains("User dictionary"))
        XCTAssertEqual(messages.last?.role, "user")
        XCTAssertEqual(messages.last?.content, transcript)
    }

    private func makeSettings() -> SettingsStore {
        let suiteName = "com.aetherallan.ElegantWhisper.llm.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return SettingsStore(defaults: defaults, keychain: KeychainStore(service: suiteName))
    }

    private func makeStylePackStore() throws -> StylePackStore {
        StylePackStore(fileURL: try temporaryFile(named: "style-packs.json"))
    }

    private func makeCapabilityCache() -> ProviderCapabilityCache {
        let suiteName = "com.aetherallan.ElegantWhisper.capability.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return ProviderCapabilityCache(defaults: defaults)
    }

    private func providerContext(model: String) -> LLMProviderRequestContext {
        LLMProviderRequestContext(
            provider: .openRouterFree,
            baseURL: URL(string: "https://openrouter.ai/api/v1")!,
            apiKey: "test-key",
            model: model,
            timeout: 25,
            maxOutputTokens: 192,
            promptContext: PromptStaticContextCache.context(stylePack: StylePackStore.builtinPacks[0]),
            transcript: "我想用配森解析杰森"
        )
    }

    private func chatResponseData(content: String, finishReason: String = "stop") throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "model": "test-model",
            "provider": "test-provider",
            "choices": [
                [
                    "message": [
                        "role": "assistant",
                        "content": content
                    ],
                    "finish_reason": finishReason
                ]
            ]
        ])
    }

    private func temporaryFile(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ElegantWhisperTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name)
    }
}

private final class TestConnectionURLProtocol: URLProtocol {
    private static let state = TestConnectionURLProtocolState()

    static func reset(responses: [(Int, String)]) {
        state.lock.lock()
        state.queuedResponses = responses.map { ($0.0, Data($0.1.utf8)) }
        state.bodies = []
        state.lock.unlock()
    }

    static func requestBodies() -> [String] {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.bodies
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let body = Self.bodyString(from: request)
        Self.state.lock.lock()
        Self.state.bodies.append(body)
        let next = Self.state.queuedResponses.isEmpty
            ? (500, Data(#"{"error":{"message":"missing mock response"}}"#.utf8))
            : Self.state.queuedResponses.removeFirst()
        Self.state.lock.unlock()

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: next.0,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: next.1)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyString(from request: URLRequest) -> String {
        if let body = request.httpBody {
            return String(data: body, encoding: .utf8) ?? ""
        }
        guard let stream = request.httpBodyStream else {
            return ""
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else {
                break
            }
            data.append(buffer, count: count)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

private final class TestConnectionURLProtocolState: @unchecked Sendable {
    let lock = NSLock()
    var queuedResponses: [(Int, Data)] = []
    var bodies: [String] = []
}
