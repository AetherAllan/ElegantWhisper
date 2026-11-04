import AVFoundation
@testable import ElegantWhisper
import XCTest

final class OnlineTranscriptionTests: XCTestCase {
    override func tearDown() {
        OpenAIStubProtocol.reset(responses: [])
        super.tearDown()
    }

    func testLanguagesAddEnglishForCodeSwitching() {
        XCTAssertEqual(OnlineTranscriptionRequest.languages(for: .simplifiedChinese), ["zh-cn", "en"])
        XCTAssertEqual(OnlineTranscriptionRequest.languages(for: .traditionalChinese), ["zh-tw", "en"])
        XCTAssertEqual(OnlineTranscriptionRequest.languages(for: .englishUS), ["en"])
    }

    func testKeywordsAreSanitizedDedupedAndCapped() {
        let raw = ["Redis", "redis", "  GitHub ", "<script>", "two\nlines", ""] + (0..<80).map { "Term\($0)" }
        let keywords = OnlineTranscriptionRequest.sanitizedKeywords(raw)

        XCTAssertEqual(Array(keywords.prefix(3)), ["Redis", "GitHub", "Term0"])
        XCTAssertEqual(keywords.count, OnlineTranscriptionRequest.maxKeywords)
        XCTAssertFalse(keywords.contains { $0.contains("<") || $0.contains("\n") })
    }

    func testMultipartBodyCarriesModelHintsAndFile() {
        let request = OnlineTranscriptionRequest(
            audio: EncodedAudio(data: Data("AUDIO".utf8), filename: "dictation.m4a", mimeType: "audio/mp4"),
            languages: ["zh-cn", "en"],
            keywords: ["Redis"],
            prompt: "Voice dictation typed into Notes."
        )
        let body = String(decoding: request.body(boundary: "B"), as: UTF8.self)

        XCTAssertTrue(body.contains("name=\"model\"\r\n\r\ngpt-transcribe\r\n"))
        XCTAssertTrue(body.contains("name=\"languages[]\"\r\n\r\nzh-cn\r\n"))
        XCTAssertTrue(body.contains("name=\"languages[]\"\r\n\r\nen\r\n"))
        XCTAssertTrue(body.contains("name=\"keywords[]\"\r\n\r\nRedis\r\n"))
        XCTAssertTrue(body.contains("name=\"prompt\"\r\n\r\nVoice dictation typed into Notes.\r\n"))
        XCTAssertTrue(body.contains("filename=\"dictation.m4a\"\r\nContent-Type: audio/mp4\r\n\r\nAUDIO\r\n--B--"))
        XCTAssertFalse(body.contains("name=\"language\"\r\n"), "gpt-transcribe takes languages[], not language")
    }

    func testClipCollectorResamplesToSixteenKilohertzMono() throws {
        let collector = AudioClipCollector()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        collector.append(try makeBuffer(format: format, frames: 4_800))
        XCTAssertTrue(collector.finish().isEmpty, "inactive collector ignores audio")

        collector.begin()
        for _ in 0..<10 {
            collector.append(try makeBuffer(format: format, frames: 4_800))
        }
        let samples = collector.finish()

        // One second of 48 kHz stereo becomes about 16,000 mono samples.
        XCTAssertEqual(Double(samples.count), 16_000, accuracy: 400)
        XCTAssertTrue(collector.finish().isEmpty, "finish hands the audio over once")
    }

    func testEncoderProducesM4AAndWavFallback() {
        // Ten seconds, so the fixed M4A header does not dominate.
        let samples = (0..<160_000).map { Float(sin(Double($0) * 2 * .pi * 440 / 16_000)) * 0.3 }

        let encoded = AudioClipEncoder.encode(samples: samples)
        XCTAssertEqual(encoded.filename, "dictation.m4a")
        XCTAssertEqual(String(decoding: encoded.data[4..<8], as: UTF8.self), "ftyp")
        XCTAssertLessThan(encoded.data.count, samples.count * 2 / 4, "AAC is much smaller than 16-bit PCM")

        let wav = AudioClipEncoder.wavData(samples: samples, sampleRate: 16_000)
        XCTAssertEqual(String(decoding: wav[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(wav.count, 44 + samples.count * 2)
    }

    func testTranscribeSendsKeyAndReturnsText() async throws {
        OpenAIStubProtocol.reset(responses: [(200, #"{"text":"我想用 Python 解析 JSON。"}"#)])

        let text = try await OnlineTranscriber.transcribe(
            samples: speech(seconds: 1),
            language: .simplifiedChinese,
            terms: ["Python", "JSON"],
            appName: "Notes",
            apiKey: "sk-test",
            session: OpenAIStubProtocol.session(),
            hintCache: HintSupportCache(defaults: nil)
        )

        XCTAssertEqual(text, "我想用 Python 解析 JSON。")
        let request = try XCTUnwrap(OpenAIStubProtocol.requests().first)
        XCTAssertEqual(request.url, TranscriptionService.openAI.endpoint)
        XCTAssertEqual(request.authorization, "Bearer sk-test")
        XCTAssertTrue(request.body.contains("keywords[]"))
    }

    func testRejectedHintsAreRetriedWithoutThem() async throws {
        OpenAIStubProtocol.reset(responses: [
            (400, #"{"error":{"message":"Invalid keyword"}}"#),
            (200, #"{"text":"ok"}"#)
        ])

        let text = try await OnlineTranscriber.transcribe(
            samples: speech(seconds: 1),
            language: .englishUS,
            terms: ["Redis"],
            appName: nil,
            apiKey: "sk-test",
            session: OpenAIStubProtocol.session(),
            hintCache: HintSupportCache(defaults: nil)
        )

        XCTAssertEqual(text, "ok")
        let bodies = OpenAIStubProtocol.requests().map(\.body)
        XCTAssertEqual(bodies.count, 2)
        XCTAssertTrue(bodies[0].contains("keywords[]"))
        XCTAssertFalse(bodies[1].contains("keywords[]"))
    }

    func testRejectedHintsAreRememberedSoLaterDictationsSendOneRequest() async throws {
        let cache = HintSupportCache(defaults: nil)
        OpenAIStubProtocol.reset(responses: [
            (400, #"{"error":{"message":"keyterms not supported"}}"#),
            (200, #"{"text":"first"}"#),
            (200, #"{"text":"second"}"#)
        ])
        let session = OpenAIStubProtocol.session()

        _ = try await OnlineTranscriber.transcribe(
            samples: speech(seconds: 1), language: .englishUS, terms: ["Redis"], appName: nil,
            apiKey: "sk-or-v1-test", session: session, hintCache: cache
        )
        XCTAssertFalse(cache.acceptsHints(.openRouter))
        XCTAssertTrue(cache.acceptsHints(.openAI), "only the service that refused is affected")

        let second = try await OnlineTranscriber.transcribe(
            samples: speech(seconds: 1), language: .englishUS, terms: ["Redis"], appName: nil,
            apiKey: "sk-or-v1-test", session: session, hintCache: cache
        )
        XCTAssertEqual(second, "second")
        let bodies = OpenAIStubProtocol.requests().map(\.body)
        XCTAssertEqual(bodies.count, 3, "rejected + retry, then a single request")
        XCTAssertFalse(bodies[2].contains("keyterms"))
    }

    func testRememberedRejectionExpires() {
        let cache = HintSupportCache(defaults: nil)
        let rejected = Date(timeIntervalSince1970: 1_000_000)
        cache.markRejected(.openRouter, now: rejected)

        XCTAssertFalse(cache.acceptsHints(.openRouter, now: rejected.addingTimeInterval(60)))
        XCTAssertTrue(cache.acceptsHints(.openRouter, now: rejected.addingTimeInterval(HintSupportCache.retryAfter + 1)))
    }

    func testFailuresSurfaceWithoutRetryingAndShortClipsAreSkipped() async throws {
        OpenAIStubProtocol.reset(responses: [(401, #"{"error":{"message":"Incorrect API key provided"}}"#)])
        do {
            _ = try await OnlineTranscriber.transcribe(
                samples: speech(seconds: 1),
                language: .englishUS,
                terms: ["Redis"],
                appName: nil,
                apiKey: "sk-bad",
                session: OpenAIStubProtocol.session(),
                hintCache: HintSupportCache(defaults: nil)
            )
            XCTFail("expected a 401")
        } catch let error as OnlineTranscriptionError {
            XCTAssertEqual(error.logName, "http401")
            XCTAssertEqual(error.localizedDescription, "Invalid API key")
        }
        XCTAssertEqual(OpenAIStubProtocol.requests().count, 1)

        OpenAIStubProtocol.reset(responses: [])
        do {
            _ = try await OnlineTranscriber.transcribe(
                samples: speech(seconds: 0.1),
                language: .englishUS,
                terms: [],
                appName: nil,
                apiKey: "sk-test",
                session: OpenAIStubProtocol.session(),
                hintCache: HintSupportCache(defaults: nil)
            )
            XCTFail("expected tooShort")
        } catch {
            XCTAssertEqual(error as? OnlineTranscriptionError, .tooShort)
        }
        XCTAssertTrue(OpenAIStubProtocol.requests().isEmpty, "nothing is uploaded for an accidental tap")
    }

    func testKeyCheckLooksUpTheModelWithoutAudio() async {
        OpenAIStubProtocol.reset(responses: [(200, #"{"id":"gpt-transcribe","object":"model"}"#)])
        let result = await OnlineTranscriber.checkKey("sk-test", session: OpenAIStubProtocol.session())

        XCTAssertEqual(try? result.get(), .openAI)
        XCTAssertEqual(OpenAIStubProtocol.requests().first?.url, TranscriptionService.openAI.keyCheckEndpoint)
        XCTAssertEqual(OpenAIStubProtocol.requests().first?.method, "GET")
    }

    func testServiceIsChosenFromTheKey() {
        XCTAssertEqual(TranscriptionService(apiKey: "sk-or-v1-abc"), .openRouter)
        XCTAssertEqual(TranscriptionService(apiKey: "  sk-or-v1-abc\n"), .openRouter)
        XCTAssertEqual(TranscriptionService(apiKey: "sk-proj-abc"), .openAI)
        XCTAssertEqual(TranscriptionService(apiKey: ""), .openAI)
    }

    func testOpenRouterGetsJSONWithBase64WavOneLanguageAndKeyterms() async throws {
        OpenAIStubProtocol.reset(responses: [(200, #"{"text":"写入 Redis 缓存","usage":{"seconds":1.0}}"#)])

        let text = try await OnlineTranscriber.transcribe(
            samples: speech(seconds: 1),
            language: .simplifiedChinese,
            terms: ["Redis", "GitHub"],
            appName: "Notes",
            apiKey: "sk-or-v1-test",
            session: OpenAIStubProtocol.session(),
            hintCache: HintSupportCache(defaults: nil)
        )

        XCTAssertEqual(text, "写入 Redis 缓存")
        let request = try XCTUnwrap(OpenAIStubProtocol.requests().first)
        XCTAssertEqual(request.url, TranscriptionService.openRouter.endpoint)
        XCTAssertEqual(request.authorization, "Bearer sk-or-v1-test")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(request.body.utf8)) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "openai/gpt-transcribe")
        XCTAssertEqual(json["language"] as? String, "zh")
        XCTAssertEqual(json["keyterms"] as? [String], ["Redis", "GitHub"])
        XCTAssertNil(json["prompt"], "OpenRouter has no prompt field")
        let audio = try XCTUnwrap(json["input_audio"] as? [String: Any])
        XCTAssertEqual(audio["format"] as? String, "wav")
        let bytes = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(audio["data"] as? String)))
        XCTAssertEqual(String(decoding: bytes[0..<4], as: UTF8.self), "RIFF")
    }

    func testOpenRouterRejectingKeytermsRetriesWithoutThem() async throws {
        OpenAIStubProtocol.reset(responses: [
            (400, #"{"error":{"code":400,"message":"keyterms not supported for this model"}}"#),
            (200, #"{"text":"ok"}"#)
        ])

        let text = try await OnlineTranscriber.transcribe(
            samples: speech(seconds: 1),
            language: .englishUS,
            terms: ["Redis"],
            appName: nil,
            apiKey: "sk-or-v1-test",
            session: OpenAIStubProtocol.session(),
            hintCache: HintSupportCache(defaults: nil)
        )

        XCTAssertEqual(text, "ok")
        let bodies = OpenAIStubProtocol.requests().map(\.body)
        XCTAssertEqual(bodies.count, 2)
        XCTAssertTrue(bodies[0].contains("keyterms"))
        XCTAssertFalse(bodies[1].contains("keyterms"))
    }

    func testOpenRouterKeyCheckAndCreditErrors() async {
        OpenAIStubProtocol.reset(responses: [(200, #"{"data":{"label":"sk-or-v1-abc...","usage":0}}"#)])
        let result = await OnlineTranscriber.checkKey("sk-or-v1-test", session: OpenAIStubProtocol.session())
        XCTAssertEqual(try? result.get(), .openRouter)
        XCTAssertEqual(OpenAIStubProtocol.requests().first?.url, TranscriptionService.openRouter.keyCheckEndpoint)

        XCTAssertEqual(
            OnlineTranscriptionError.http(status: 402, message: "Insufficient credits").localizedDescription,
            "Not enough credits on this key"
        )
    }

    private func speech(seconds: Double) -> [Float] {
        (0..<Int(seconds * AudioClipCollector.sampleRate)).map { Float(sin(Double($0) / 9)) * 0.2 }
    }

    private func makeBuffer(format: AVAudioFormat, frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<Int(frames) {
                buffer.floatChannelData![channel][frame] = Float(sin(Double(frame) / 20)) * 0.2
            }
        }
        return buffer
    }
}

private struct RecordedRequest {
    let url: URL?
    let method: String?
    let authorization: String?
    let body: String
}

private final class OpenAIStubProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var queued: [(Int, Data)] = []
    nonisolated(unsafe) private static var recorded: [RecordedRequest] = []

    static func reset(responses: [(Int, String)]) {
        lock.withLock {
            queued = responses.map { ($0.0, Data($0.1.utf8)) }
            recorded = []
        }
    }

    static func requests() -> [RecordedRequest] {
        lock.withLock { recorded }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenAIStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        // Audio bytes are not valid UTF-8; Latin-1 keeps the text fields searchable.
        let body = String(data: Self.bodyData(from: request), encoding: .isoLatin1) ?? ""
        let next: (Int, Data) = Self.lock.withLock {
            Self.recorded.append(RecordedRequest(
                url: request.url,
                method: request.httpMethod,
                authorization: request.value(forHTTPHeaderField: "Authorization"),
                body: body
            ))
            return Self.queued.isEmpty ? (500, Data(#"{"error":{"message":"no stub"}}"#.utf8)) : Self.queued.removeFirst()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: next.0, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: next.1)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyData(from request: URLRequest) -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return Data()
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
