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

        XCTAssertTrue(refiner.acceptsCorrection(original: "我在写配森和杰森", corrected: "我在写 Python 和 JSON"))
    }

    func testRejectsEmptyCorrection() {
        let refiner = LLMRefiner(settings: .shared)

        XCTAssertFalse(refiner.acceptsCorrection(original: "hello world", corrected: ""))
    }

    func testRejectsLargeRewrite() {
        let refiner = LLMRefiner(settings: .shared)

        XCTAssertFalse(refiner.acceptsCorrection(
            original: "打开设置",
            corrected: "下面是一个完整的操作指南，第一步打开系统设置，第二步找到隐私权限，第三步逐项检查。"
        ))
    }

    func testRejectsTruncatedLLMChoice() {
        let refiner = LLMRefiner(settings: .shared)
        let choice = ChatResponse.Choice(
            message: ChatMessage(role: "assistant", content: "这是被截断的前半段"),
            finishReason: "length"
        )

        XCTAssertFalse(refiner.acceptsChoice(original: "这是一个比较长的原始转写，不能因为模型截断就丢掉后半段。", choice: choice))
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

        XCTAssertFalse(LLMRefiner(settings: .shared).acceptsChoice(original: "我想用配森解析杰森", choice: response.choices[0]))
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

        XCTAssertEqual(LLMRefiner(settings: .shared).providerErrorReason(from: data), "free-models-per-day")
    }

    func testAcceptsWrappedModelCorrection() {
        let refiner = LLMRefiner(settings: .shared)
        let choice = ChatResponse.Choice(
            message: ChatMessage(role: "assistant", content: "Corrected text: “我在写 Python 和 JSON”"),
            finishReason: "stop"
        )

        XCTAssertEqual(
            refiner.acceptedCorrection(original: "我在写配森和杰森", choice: choice),
            "我在写 Python 和 JSON"
        )
    }

    func testProviderInfersOpenRouterFromExistingBaseURL() {
        let settings = makeSettings()
        settings.apiBaseURL = "https://openrouter.ai/api/v1"

        XCTAssertEqual(settings.llmProvider, .openRouterFree)
    }

    func testOpenRouterRequestAddsAttributionHeaderAndHotwords() throws {
        let settings = makeSettings()
        let stylePacks = try makeStylePackStore()
        settings.llmProvider = .openRouterFree
        settings.apiBaseURL = "https://openrouter.ai/api/v1"
        settings.model = "openrouter/free"
        settings.apiKey = "test-key"
        defer { settings.apiKey = "" }

        let request = try XCTUnwrap(LLMRefiner(settings: settings, stylePacks: stylePacks).makeRequest(
            text: "我想用配森解析杰森",
            hotwords: ["Python", "JSON"]
        ))

        XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
        XCTAssertEqual(request.timeoutInterval, 25)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-OpenRouter-Title"), AppConstants.productName)

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "nvidia/nemotron-3-nano-30b-a3b:free")
        XCTAssertEqual(json["max_tokens"] as? Int, 96)
        let reasoning = try XCTUnwrap(json["reasoning"] as? [String: Any])
        XCTAssertEqual(reasoning["effort"] as? String, "none")
        XCTAssertEqual(reasoning["exclude"] as? Bool, true)

        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let systemPrompt = try XCTUnwrap(messages.first?["content"] as? String)
        XCTAssertTrue(systemPrompt.contains("Python"))
        XCTAssertTrue(systemPrompt.contains("JSON"))
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

    func testPromptKeepsConservativeBoundary() {
        let prompt = LLMPromptBuilder.systemPrompt(template: LLMPromptBuilder.conservativeTemplate, hotwords: ["MCP"])

        XCTAssertTrue(prompt.contains("Do not polish"))
        XCTAssertTrue(prompt.contains("MCP"))
        XCTAssertFalse(prompt.contains("Common ASR hints"))
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

        let request = try XCTUnwrap(LLMRefiner(settings: settings, stylePacks: stylePacks).makeRequest(
            text: "配森",
            hotwords: ["Python"]
        ))
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let systemPrompt = try XCTUnwrap(messages.first?["content"] as? String)

        XCTAssertTrue(systemPrompt.contains("Custom prompt."))
        XCTAssertTrue(systemPrompt.contains("Python"))
        XCTAssertFalse(systemPrompt.contains(LLMPromptBuilder.hotwordPlaceholder))
    }

    func testPromptAppendsHotwordsWhenPlaceholderIsMissing() {
        let prompt = LLMPromptBuilder.systemPrompt(template: "Custom prompt only.", hotwords: ["JSON"])

        XCTAssertTrue(prompt.contains("Custom prompt only."))
        XCTAssertTrue(prompt.contains("JSON"))
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

    private func temporaryFile(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ElegantWhisperTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name)
    }
}
