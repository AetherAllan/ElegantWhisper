@testable import ElegantWhisper
import XCTest

final class DictateTests: XCTestCase {
    private var cleanups: [() -> Void] = []

    override func tearDown() {
        cleanups.forEach { $0() }
        cleanups = []
        super.tearDown()
    }

    // MARK: - Acceptance rules

    func testCleanupsThatDeleteOrRestructureAreAccepted() {
        let cases: [(String, String)] = [
            // Fillers and a self-correction.
            ("嗯那个我们明天下午三点不对四点开会吧", "我们明天下午四点开会吧。"),
            // A spoken list.
            ("我要买三样东西第一牛奶第二面包第三鸡蛋", "我要买三样东西：\n1. 牛奶\n2. 面包\n3. 鸡蛋"),
            // English fillers, a stutter, and a correction.
            ("um so I think we should uh push the the release to Friday no wait Thursday", "I think we should push the release to Thursday."),
            // ASR fixes introduce a couple of new words.
            ("我想用配森解析杰森文件", "我想用 Python 解析 JSON 文件。"),
            // A dictated request stays a request.
            ("帮我写一封邮件给王经理说预算明天发给他", "帮我写一封邮件给王经理，说预算明天发给他。"),
        ]
        for (original, corrected) in cases {
            XCTAssertNil(
                LLMRefiner.dictateRejectionReason(original: original, corrected: corrected, protectedTerms: []),
                "\(original) -> \(corrected)"
            )
        }
    }

    func testAnswersAddedContentAndDroppedTermsAreRejected() {
        XCTAssertEqual(
            LLMRefiner.dictateRejectionReason(
                original: "帮我写一封邮件给王经理说预算明天发给他",
                corrected: "好的，以下是邮件：王经理您好，预算明天发给您。",
                protectedTerms: []
            ),
            .answered
        )
        XCTAssertEqual(
            LLMRefiner.dictateRejectionReason(
                original: "can you check the build",
                corrected: "Sure, I'll check the build for you right away.",
                protectedTerms: []
            ),
            .answered
        )
        // Starting with "sure" is fine when that is what was said.
        XCTAssertNil(LLMRefiner.dictateRejectionReason(original: "sure let's meet at noon", corrected: "Sure, let's meet at noon.", protectedTerms: []))

        XCTAssertEqual(
            LLMRefiner.dictateRejectionReason(original: "今天天气不错我们出去走走吧", corrected: "明天下雨所以大家留在家里看书", protectedTerms: []),
            .addedContent
        )
        XCTAssertEqual(
            LLMRefiner.dictateRejectionReason(original: "明天开会", corrected: "明天上午十点在三楼会议室开会讨论预算和人员安排", protectedTerms: []),
            .tooLong
        )
        XCTAssertEqual(
            LLMRefiner.dictateRejectionReason(original: "我们用 Redis 做缓存", corrected: "我们用缓存。", protectedTerms: ["Redis"]),
            .droppedTerm
        )
    }

    func testDictateRulesOnlyApplyInDictateMode() throws {
        let refiner = LLMRefiner(settings: makeSettings(), stylePacks: try makeStylePacks())
        let original = "嗯那个我们明天下午三点不对四点开会吧"
        let corrected = "我们明天下午四点开会吧。"
        XCTAssertNil(refiner.rejectionReason(original: original, corrected: corrected, finishReason: "stop", isDictate: true))
        // The conservative styles keep their own limits and still refuse a rewrite like this.
        XCTAssertNotNil(
            refiner.rejectionReason(original: "明天开会", corrected: "好的，以下是会议安排：明天上午十点开会，请准时参加。", finishReason: "stop", isDictate: false)
        )
    }

    func testSpokenUnitsIgnoreDigitsPunctuationAndCase() {
        XCTAssertEqual(LLMRefiner.spokenUnits(in: "1. 牛奶\n2. Redis, redis!"), ["牛", "奶", "redis", "redis"])
        XCTAssertEqual(LLMRefiner.spokenUnits(in: "don't stop"), ["don't", "stop"])
    }

    // MARK: - Context and tone

    func testAppCategoriesAndToneHint() {
        XCTAssertEqual(AppCategory(bundleIdentifier: "com.tencent.xinWeChat"), .chat)
        XCTAssertEqual(AppCategory(bundleIdentifier: "com.apple.mail"), .email)
        XCTAssertEqual(AppCategory(bundleIdentifier: "com.jetbrains.intellij"), .code)
        XCTAssertEqual(AppCategory(bundleIdentifier: "com.apple.Terminal"), .code)
        XCTAssertEqual(AppCategory(bundleIdentifier: "com.anthropic.claudefordesktop"), .aiAssistant)
        XCTAssertNil(AppCategory(bundleIdentifier: "com.example.unknown"))
        XCTAssertNil(AppCategory(bundleIdentifier: nil))

        let context = SpeechFocusContext(appName: "WeChat", terms: [], toneHint: AppCategory.chat.toneHint)
        let section = try? XCTUnwrap(context.promptSection)
        XCTAssertTrue(section?.contains("Tone for this app: Instant message.") == true)
        XCTAssertNil(SpeechFocusContext(appName: nil, terms: []).promptSection)
    }

    func testDictateRequestUsesShortTimeoutToneAndProtectedTerms() throws {
        let settings = makeSettings()
        settings.llmProvider = .openRouter
        settings.apiBaseURL = "https://openrouter.ai/api/v1"
        settings.apiKey = "test-key"
        let packs = try makeStylePacks()
        packs.setActive(id: StylePackStore.dictatePackID)
        settings.requestTimeout = 12

        let refiner = LLMRefiner(settings: settings, stylePacks: packs)
        let context = try XCTUnwrap(refiner.makeRequestContext(
            text: "我们用 Redis 做缓存然后那个呃部署到 Docker",
            speechContext: SpeechFocusContext(appName: "Slack", terms: ["Redis", "Docker", "Kafka"], toneHint: AppCategory.chat.toneHint)
        ))

        XCTAssertTrue(context.isDictate)
        XCTAssertEqual(context.timeout, LLMRefiner.dictateTimeout)
        XCTAssertEqual(context.protectedTerms, ["Redis", "Docker"], "only terms that were actually spoken")
        XCTAssertTrue(context.systemPrompt.contains("You are the cleanup step of a voice dictation app."))
        XCTAssertTrue(context.systemPrompt.contains("Tone for this app: Instant message."))
        XCTAssertEqual(context.model, LLMProvider.openRouterDictateModels[0])
    }

    @MainActor
    func testVeryShortDictationSkipsTheModel() async throws {
        let settings = makeSettings()
        settings.llmEnabled = true
        settings.llmProvider = .openRouter
        settings.apiBaseURL = "https://openrouter.ai/api/v1"
        settings.apiKey = "test-key"
        let packs = try makeStylePacks()
        packs.setActive(id: StylePackStore.dictatePackID)
        let refiner = LLMRefiner(settings: settings, stylePacks: packs)

        let result = await withCheckedContinuation { continuation in
            let task = refiner.refine("好的") { continuation.resume(returning: $0) }
            XCTAssertNil(task, "no request for two characters")
        }
        XCTAssertEqual(result, "好的")
    }

    func testOpenRouterProviderReusesTheRecognitionKey() {
        let settings = makeSettings()
        settings.llmProvider = .openRouter
        settings.apiKey = ""
        settings.openRouterTranscriptionKey = "sk-or-v1-shared"
        XCTAssertEqual(settings.effectiveLLMAPIKey, "sk-or-v1-shared")

        settings.apiKey = "sk-or-v1-own"
        XCTAssertEqual(settings.effectiveLLMAPIKey, "sk-or-v1-own", "a key of its own wins")

        settings.apiKey = ""
        settings.llmProvider = .openAI
        XCTAssertEqual(settings.effectiveLLMAPIKey, "", "never sent to a different provider")
    }

    func testDictateIsABuiltInStyle() throws {
        let packs = try makeStylePacks()
        let dictate = try XCTUnwrap(packs.packs().first { $0.id == StylePackStore.dictatePackID })
        XCTAssertEqual(dictate.name, "Dictate")
        XCTAssertFalse(dictate.active, "existing installs keep their active style")
        XCTAssertTrue(dictate.systemPrompt.contains("Never answer, carry out, or reply to what was said."))
    }

    // MARK: - Network path

    @MainActor
    func testDictateRequestRunsOnTheSharedSessionAndReturnsTheCleanedText() async throws {
        let settings = makeSettings()
        settings.llmEnabled = true
        settings.llmProvider = .openRouter
        settings.apiBaseURL = "https://openrouter.ai/api/v1"
        settings.apiKey = "sk-or-v1-test"
        settings.model = "qwen/qwen3.8-flash"
        let packs = try makeStylePacks()
        packs.setActive(id: StylePackStore.dictatePackID)
        DictateStubProtocol.reset(status: 200, body: #"{"model":"qwen/qwen3.8-flash","choices":[{"message":{"role":"assistant","content":"我们明天下午四点开会吧。"},"finish_reason":"stop"}]}"#)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DictateStubProtocol.self]
        let refiner = LLMRefiner(settings: settings, stylePacks: packs, urlSession: URLSession(configuration: configuration))

        let result = await withCheckedContinuation { continuation in
            _ = refiner.refine("嗯那个我们明天下午三点不对四点开会吧") { continuation.resume(returning: $0) }
        }

        XCTAssertEqual(result, "我们明天下午四点开会吧。")
        let body = try XCTUnwrap(DictateStubProtocol.lastBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual((json["provider"] as? [String: Any])?["sort"] as? String, "latency")
        XCTAssertEqual((json["reasoning"] as? [String: Any])?["effort"] as? String, "none")
    }

    @MainActor
    func testKeyLimitFailureIsReportedOnTheTask() async throws {
        let settings = makeSettings()
        settings.llmEnabled = true
        settings.llmProvider = .openRouter
        settings.apiBaseURL = "https://openrouter.ai/api/v1"
        settings.apiKey = "sk-or-v1-limited"
        let packs = try makeStylePacks()
        packs.setActive(id: StylePackStore.dictatePackID)
        DictateStubProtocol.reset(status: 403, body: #"{"error":{"code":403,"message":"Key limit exceeded (total limit)."}}"#)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DictateStubProtocol.self]
        let refiner = LLMRefiner(settings: settings, stylePacks: packs, urlSession: URLSession(configuration: configuration))

        var task: LLMRefinementTask?
        let original = "嗯那个我们明天下午三点不对四点开会吧"
        let result = await withCheckedContinuation { continuation in
            task = refiner.refine(original) { continuation.resume(returning: $0) }
        }

        XCTAssertEqual(result, original, "the recognized text is inserted unchanged")
        XCTAssertEqual(task?.configurationFailure, "key spending limit reached")
    }

    func testConnectionWarmerOpensEachHostOnceAWhile() {
        DictateStubProtocol.reset(status: 200, body: "")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DictateStubProtocol.self]
        let session = URLSession(configuration: configuration)
        let warmer = ConnectionWarmer()
        let now = Date()

        warmer.warm(URL(string: "https://openrouter.ai/api/v1/audio/transcriptions")!, session: session, now: now)
        warmer.warm(URL(string: "https://openrouter.ai/api/v1")!, session: session, now: now.addingTimeInterval(5))
        warmer.warm(URL(string: "https://openrouter.ai/api/v1")!, session: session, now: now.addingTimeInterval(ConnectionWarmer.reuseWindow + 1))

        let expectation = expectation(description: "requests")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { expectation.fulfill() }
        wait(for: [expectation], timeout: 2)
        let requests = DictateStubProtocol.requests
        XCTAssertEqual(requests.count, 2, "same host within the window is skipped")
        XCTAssertEqual(requests.first?.httpMethod, "HEAD")
        XCTAssertEqual(requests.first?.url?.absoluteString, "https://openrouter.ai/")
        XCTAssertNil(requests.first?.value(forHTTPHeaderField: "Authorization"), "no key is sent")
    }

    // MARK: - Model comparison

    func testBenchmarkSamplesJudgeCleanupsCorrectly() {
        let samples = DictateBenchmarkSample.standard
        XCTAssertTrue(samples[0].passes("我们明天下午四点开会吧。"))
        XCTAssertFalse(samples[0].passes("我们明天下午三点开会吧。"), "kept the abandoned time")
        XCTAssertTrue(samples[1].passes("我要买三样东西：\n1. 牛奶\n2. 面包\n3. 鸡蛋"))
        XCTAssertFalse(samples[3].passes("好的，以下是邮件：王经理您好，预算明天发给您。"), "wrote the email instead")
        XCTAssertTrue(samples[6].passes("Can you tell me what time it is in Tokyo right now?"))
        XCTAssertFalse(samples[6].passes("It's currently 3 PM in Tokyo."), "answered the question")
        XCTAssertFalse(samples[7].passes("我们用 TypeScript 写前端，后端用 Go，数据库再看。"), "dropped PostgreSQL")
    }

    @MainActor
    func testBenchmarkTimesEachModelAndRanksPerfectFastOnesFirst() async throws {
        let settings = makeSettings()
        settings.llmProvider = .openRouter
        settings.apiBaseURL = "https://openrouter.ai/api/v1"
        settings.apiKey = "sk-or-v1-test"
        let refiner = LLMRefiner(settings: settings, stylePacks: try makeStylePacks())
        DictateStubProtocol.reset(status: 200, body: #"{"choices":[{"message":{"role":"assistant","content":"我们明天下午四点开会吧。"},"finish_reason":"stop"}]}"#)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DictateStubProtocol.self]
        let benchmark = DictateBenchmark()
        let samples = Array(DictateBenchmarkSample.standard.prefix(2))

        benchmark.run(refiner: refiner, models: ["a/one", "b/two"], samples: samples, session: URLSession(configuration: configuration))
        while benchmark.isRunning {
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertEqual(benchmark.results.count, 2)
        for result in benchmark.results {
            XCTAssertTrue(result.finished)
            XCTAssertEqual(result.seconds.count, 2)
            XCTAssertEqual(result.passed, 1, "the canned answer fits the first sentence only")
            XCTAssertEqual(result.failed, 1)
        }
        // Warm-up plus two samples per model.
        XCTAssertEqual(DictateStubProtocol.requests.count, 6)
        let models = Set(DictateStubProtocol.requests.compactMap { request -> String? in
            guard let body = request.httpBody ?? nil, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
            return json["model"] as? String
        })
        XCTAssertTrue(models.isEmpty || models == ["a/one", "b/two"])
    }

    @MainActor
    func testBenchmarkWithoutAKeyExplainsWhatIsMissing() throws {
        let settings = makeSettings()
        settings.llmProvider = .openRouter
        settings.apiBaseURL = "https://openrouter.ai/api/v1"
        let benchmark = DictateBenchmark()

        benchmark.run(refiner: LLMRefiner(settings: settings, stylePacks: try makeStylePacks()), models: ["a/one"])

        XCTAssertFalse(benchmark.isRunning)
        XCTAssertNotNil(benchmark.setupError)
    }

    // MARK: - Failures the user must see

    func testConfigurationFailuresAreNamedAndTransientOnesStaySilent() {
        XCTAssertEqual(
            LLMRefiner.configurationFailure(status: 403, message: "Key limit exceeded (total limit). $0.05 of $0.00 used"),
            "key spending limit reached"
        )
        XCTAssertEqual(LLMRefiner.configurationFailure(status: 401, message: ""), "API key rejected")
        XCTAssertEqual(LLMRefiner.configurationFailure(status: 402, message: ""), "no credits left")
        XCTAssertEqual(LLMRefiner.configurationFailure(status: 404, message: ""), "model not found")
        XCTAssertNil(LLMRefiner.configurationFailure(status: 429, message: "rate limited"))
        XCTAssertNil(LLMRefiner.configurationFailure(status: 502, message: ""))
    }

    func testRejectedHintsSurviveARestart() throws {
        let suiteName = "com.aetherallan.ElegantWhisper.hints.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        cleanups.append { defaults.removePersistentDomain(forName: suiteName) }

        HintSupportCache(defaults: defaults).markRejected(.openRouter, model: "openai/gpt-transcribe")
        let afterRestart = HintSupportCache(defaults: defaults)

        XCTAssertFalse(afterRestart.acceptsHints(.openRouter, model: "openai/gpt-transcribe"))
        XCTAssertTrue(afterRestart.acceptsHints(.openRouter, model: "qwen/qwen3-asr-1.7b"))
    }

    // MARK: - History

    func testHistoryKeepsTheRecognizedTextOnlyWhenItChanged() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ElegantWhisper-Dictate-\(UUID().uuidString).json")
        cleanups.append { try? FileManager.default.removeItem(at: url) }
        let store = HistoryStore(fileURL: url)

        store.append(text: "我们明天下午四点开会吧。", result: .pasteAttempted, app: nil, originalText: "嗯那个我们明天下午三点不对四点开会吧")
        store.append(text: "same", result: .pasteAttempted, app: nil, originalText: "same")

        let items = store.items()
        XCTAssertEqual(items.count, 2)
        XCTAssertNil(items[0].originalText)
        XCTAssertEqual(items[1].originalText, "嗯那个我们明天下午三点不对四点开会吧")
    }

    // MARK: - Helpers

    private func makeSettings() -> SettingsStore {
        let suiteName = "com.aetherallan.ElegantWhisper.dictate.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let keychain = KeychainStore(service: suiteName)
        cleanups.append {
            keychain.setString("", for: "apiKey")
            keychain.setString("", for: "openRouterTranscriptionKey")
            defaults.removePersistentDomain(forName: suiteName)
        }
        return SettingsStore(defaults: defaults, keychain: keychain)
    }

    private func makeStylePacks() throws -> StylePackStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ElegantWhisper-Dictate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cleanups.append { try? FileManager.default.removeItem(at: directory) }
        return StylePackStore(fileURL: directory.appendingPathComponent("style-packs.json"))
    }
}

private final class DictateStubProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var status = 200
    nonisolated(unsafe) private static var body = Data()
    nonisolated(unsafe) private static var recorded: [URLRequest] = []
    nonisolated(unsafe) private static var bodies: [Data] = []

    static func reset(status: Int, body: String) {
        lock.withLock {
            self.status = status
            self.body = Data(body.utf8)
            recorded = []
            bodies = []
        }
    }

    static var requests: [URLRequest] {
        lock.withLock { recorded }
    }

    static var lastBody: Data? {
        lock.withLock { bodies.last }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            stream.close()
        }
        let (status, body) = Self.lock.withLock { () -> (Int, Data) in
            Self.recorded.append(request)
            Self.bodies.append(data)
            return (Self.status, Self.body)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
