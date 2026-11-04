import AVFoundation
import Foundation

// Optional online recognition through OpenAI (`gpt-transcribe`) or OpenRouter (any of its
// speech-to-text models), chosen in Settings → Recognition.
//
// On-device recognition keeps running during the recording for the live HUD preview and as the
// fallback. Meanwhile AudioClipCollector keeps a 16 kHz mono copy of the microphone audio. When
// the user stops, the clip is compressed and uploaded once to /v1/audio/transcriptions; if that
// request fails or times out, the on-device text is inserted instead.

/// Collects one dictation's microphone audio as 16 kHz mono samples for upload. Fed from the
/// recorder tap next to on-device recognition; does nothing unless a session is active.
final class AudioClipCollector: @unchecked Sendable {
    static let sampleRate: Double = 16_000
    /// Far longer than any dictation and well under the 25 MB upload limit once compressed.
    static let maxSeconds: Double = 12 * 60

    private let lock = NSLock()
    private var active = false
    private var samples: [Float] = []
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: AudioClipCollector.sampleRate,
        channels: 1,
        interleaved: false
    )!

    func begin() {
        lock.withLock {
            active = true
            samples = []
            samples.reserveCapacity(Int(Self.sampleRate * 30))
            converter = nil
            converterInputFormat = nil
        }
    }

    func cancel() {
        lock.withLock {
            active = false
            samples = []
        }
    }

    /// Ends the session and hands over the audio collected so far.
    func finish() -> [Float] {
        lock.withLock {
            active = false
            let collected = samples
            samples = []
            return collected
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard active,
              Double(samples.count) < Self.sampleRate * Self.maxSeconds,
              let converted = convert(buffer),
              let channel = converted.floatChannelData?[0]
        else {
            return
        }
        samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if converter == nil || converterInputFormat.map({ !Self.formatsMatch($0, buffer.format) }) == true {
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
            // Multi-channel interfaces: mix down instead of keeping only the first channel.
            converter?.downmix = true
            converterInputFormat = buffer.format
        }
        guard let converter else {
            return nil
        }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(max(1, ceil(Double(buffer.frameLength) * ratio))) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return nil
        }
        let input = ClipConverterInput(buffer: buffer)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if input.consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            input.consumed = true
            outStatus.pointee = .haveData
            return input.buffer
        }
        guard status != .error, output.frameLength > 0 else {
            return nil
        }
        return output
    }

    private static func formatsMatch(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        lhs.sampleRate == rhs.sampleRate
            && lhs.channelCount == rhs.channelCount
            && lhs.commonFormat == rhs.commonFormat
            && lhs.isInterleaved == rhs.isInterleaved
    }
}

private final class ClipConverterInput: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var consumed = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

struct EncodedAudio: Equatable {
    let data: Data
    let filename: String
    let mimeType: String
}

enum AudioClipEncoder {
    /// AAC in M4A is about 4 KB per second of speech plus a ~22 KB header, against 32 KB per second
    /// for 16-bit WAV (36 KB vs 320 KB for 10 s), so uploads stay short on slow connections. WAV is
    /// the fallback if the system AAC encoder is unavailable.
    static func encode(
        samples: [Float],
        sampleRate: Double = AudioClipCollector.sampleRate,
        compressed: Bool = true
    ) -> EncodedAudio {
        if compressed, let m4a = try? m4aData(samples: samples, sampleRate: sampleRate), !m4a.isEmpty {
            return EncodedAudio(data: m4a, filename: "dictation.m4a", mimeType: "audio/mp4")
        }
        if compressed {
            DebugLog.event("onlineTranscriptionWavFallback")
        }
        return EncodedAudio(data: wavData(samples: samples, sampleRate: sampleRate), filename: "dictation.wav", mimeType: "audio/wav")
    }

    static func m4aData(samples: [Float], sampleRate: Double) throws -> Data {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ElegantWhisper-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 48_000
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunkSize = Int(sampleRate)
        var offset = 0
        while offset < samples.count {
            let count = min(chunkSize, samples.count - offset)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count)),
                  let channel = buffer.floatChannelData?[0]
            else {
                throw OnlineTranscriptionError.encodingFailed
            }
            buffer.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { source in
                channel.update(from: source.baseAddress! + offset, count: count)
            }
            try file.write(from: buffer)
            offset += count
        }
        file.close()
        return try Data(contentsOf: url)
    }

    static func wavData(samples: [Float], sampleRate: Double) -> Data {
        var pcm = Data(capacity: samples.count * 2)
        for sample in samples {
            var value = Int16(max(-1, min(1, sample)) * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }
        var header = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { header.append(contentsOf: $0) }
        }
        let rate = UInt32(sampleRate)
        header.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + pcm.count))
        header.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(rate)
        append(rate * 2)
        append(UInt16(2))
        append(UInt16(16))
        header.append(contentsOf: Array("data".utf8))
        append(UInt32(pcm.count))
        return header + pcm
    }
}

enum OnlineTranscriptionError: LocalizedError, Equatable {
    case missingKey
    case tooShort
    case encodingFailed
    case timedOut
    case network(String)
    case invalidResponse
    case unknownModel(String)
    case http(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .missingKey: "No API key"
        case .tooShort: "Recording too short"
        case .encodingFailed: "Could not encode audio"
        case .timedOut: "Timed out"
        case .network(let message): "Network error: \(message)"
        case .invalidResponse: "Invalid response"
        case .unknownModel(let model): "OpenRouter has no model “\(model)”"
        case .http(401, _): "Invalid API key"
        case .http(402, _): "Not enough credits on this key"
        case .http(let status, let message): message.isEmpty ? "HTTP \(status)" : "HTTP \(status): \(message)"
        }
    }

    /// Short and free of text content, for the debug log.
    var logName: String {
        switch self {
        case .missingKey: "missingKey"
        case .tooShort: "tooShort"
        case .encodingFailed: "encodingFailed"
        case .timedOut: "timedOut"
        case .network: "network"
        case .invalidResponse: "invalidResponse"
        case .unknownModel: "unknownModel"
        case .http(let status, _): "http\(status)"
        }
    }
}

/// The online API a recording is sent to, set by the provider chosen in Settings.
enum TranscriptionService: String, Equatable {
    case openAI
    case openRouter

    /// OpenRouter keys start with `sk-or-`. Used to point out a key pasted under the wrong provider.
    static func looksLikeOpenRouterKey(_ key: String) -> Bool {
        key.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("sk-or-")
    }

    var displayName: String {
        switch self {
        case .openAI: "OpenAI"
        case .openRouter: "OpenRouter"
        }
    }

    var endpoint: URL {
        switch self {
        case .openAI: URL(string: "https://api.openai.com/v1/audio/transcriptions")!
        case .openRouter: URL(string: "https://openrouter.ai/api/v1/audio/transcriptions")!
        }
    }

    /// A free, authenticated GET that proves the key works: the model at OpenAI, the key's own
    /// record at OpenRouter.
    var keyCheckEndpoint: URL {
        switch self {
        case .openAI: URL(string: "https://api.openai.com/v1/models/gpt-transcribe")!
        case .openRouter: URL(string: "https://openrouter.ai/api/v1/key")!
        }
    }

    /// Public lookup that answers 404 for a model ID OpenRouter does not have.
    static func openRouterModelURL(_ model: String) -> URL? {
        URL(string: "https://openrouter.ai/api/v1/models/\(model)/endpoints")
    }

    /// OpenRouter documents WAV for base64 audio; OpenAI takes a smaller M4A upload.
    var acceptsCompressedAudio: Bool {
        self == .openAI
    }
}

/// One upload. The two services take the same audio and hints in different shapes:
/// - OpenAI: multipart form with `languages[]` (several), `keywords[]`, and `prompt`.
/// - OpenRouter: JSON with base64 `input_audio`, one `language`, and `keyterms`; no prompt.
struct OnlineTranscriptionRequest: Equatable {
    /// Hints, not required output; OpenAI warns too many can make unspoken terms appear.
    static let maxKeywords = 50

    var service: TranscriptionService = .openAI
    var model = TranscriptionModelOption.openAIModel.id
    var audio: EncodedAudio
    var languages: [String]
    var keywords: [String]
    var prompt: String?

    var endpoint: URL {
        service.endpoint
    }

    /// The selected language plus English, since dictation often mixes in English terms.
    static func languages(for language: RecognitionLanguage) -> [String] {
        switch language {
        case .englishUS: ["en"]
        case .simplifiedChinese: ["zh-cn", "en"]
        case .traditionalChinese: ["zh-tw", "en"]
        case .japanese: ["ja", "en"]
        case .korean: ["ko", "en"]
        }
    }

    /// OpenRouter takes a single ISO-639-1 code.
    static func openRouterLanguage(for language: RecognitionLanguage) -> String {
        switch language {
        case .englishUS: "en"
        case .simplifiedChinese, .traditionalChinese: "zh"
        case .japanese: "ja"
        case .korean: "ko"
        }
    }

    /// The API rejects keywords containing `<`, `>`, or line breaks; drop those and duplicates.
    static func sanitizedKeywords(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        var keywords: [String] = []
        for raw in terms {
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty,
                  term.count <= 64,
                  !term.contains(where: { $0 == "<" || $0 == ">" || $0.isNewline }),
                  seen.insert(term.lowercased()).inserted
            else {
                continue
            }
            keywords.append(term)
            if keywords.count == maxKeywords {
                break
            }
        }
        return keywords
    }

    func urlRequest(apiKey: String, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        switch service {
        case .openAI:
            let boundary = "ElegantWhisper-\(UUID().uuidString)"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.httpBody = body(boundary: boundary)
        case .openRouter:
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            // Lets OpenRouter attribute requests to the app in its dashboard.
            request.setValue(AppConstants.productName, forHTTPHeaderField: "X-Title")
            request.httpBody = openRouterBody()
        }
        return request
    }

    /// OpenAI multipart form.
    func body(boundary: String) -> Data {
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", model)
        field("response_format", "json")
        for language in languages {
            field("languages[]", language)
        }
        for keyword in keywords {
            field("keywords[]", keyword)
        }
        if let prompt, !prompt.isEmpty {
            field("prompt", prompt)
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(audio.filename)\"\r\nContent-Type: \(audio.mimeType)\r\n\r\n".utf8))
        body.append(audio.data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    /// OpenRouter JSON body. `languages` holds the single OpenRouter code here.
    func openRouterBody() -> Data {
        struct InputAudio: Encodable {
            let data: String
            let format: String
        }
        struct Body: Encodable {
            let model: String
            let inputAudio: InputAudio
            let language: String?
            let keyterms: [String]?

            enum CodingKeys: String, CodingKey {
                case model
                case inputAudio = "input_audio"
                case language
                case keyterms
            }
        }
        let format = (audio.filename as NSString).pathExtension.lowercased()
        let body = Body(
            model: model,
            inputAudio: InputAudio(data: audio.data.base64EncodedString(), format: format.isEmpty ? "wav" : format),
            language: languages.first,
            keyterms: keywords.isEmpty ? nil : keywords
        )
        return (try? JSONEncoder().encode(body)) ?? Data()
    }

    static func text(from data: Data) throws -> String {
        struct Response: Decodable {
            let text: String
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw OnlineTranscriptionError.invalidResponse
        }
        return response.text
    }

    static func errorMessage(from data: Data) -> String {
        struct Envelope: Decodable {
            struct Body: Decodable {
                let message: String?
            }
            let error: Body?
        }
        let message = (try? JSONDecoder().decode(Envelope.self, from: data))?.error?.message ?? ""
        return String(message.prefix(200))
    }
}

/// Remembers that a service rejected vocabulary hints, so later dictations send one request
/// instead of a rejected one plus a retry. Entries expire so a service that adds support later
/// gets tried again.
final class HintSupportCache: @unchecked Sendable {
    // UserDefaults(suiteName:) returns nil for the app's own bundle identifier when running as the
    // app, so fall back to .standard (the same domain), as SettingsStore does. Without this the
    // rejection was kept in memory only and every launch paid for a rejected request again.
    static let shared = HintSupportCache(defaults: UserDefaults(suiteName: AppConstants.userDefaultsSuiteName) ?? .standard)
    static let retryAfter: TimeInterval = 7 * 24 * 60 * 60

    private let lock = NSLock()
    private let defaults: UserDefaults?
    private var rejectedAt: [String: Date] = [:]
    private static let defaultsKey = "transcriptionHintsRejectedAt"

    /// `defaults` nil keeps the cache in memory only, for tests.
    init(defaults: UserDefaults?) {
        self.defaults = defaults
        let stored = defaults?.dictionary(forKey: Self.defaultsKey) as? [String: Date] ?? [:]
        rejectedAt = stored
    }

    func acceptsHints(_ service: TranscriptionService, model: String, now: Date = Date()) -> Bool {
        lock.withLock {
            guard let date = rejectedAt[key(service, model)] else { return true }
            return now.timeIntervalSince(date) > Self.retryAfter
        }
    }

    func markRejected(_ service: TranscriptionService, model: String, now: Date = Date()) {
        lock.withLock {
            rejectedAt[key(service, model)] = now
            defaults?.set(rejectedAt, forKey: Self.defaultsKey)
        }
    }

    /// Per model: on OpenRouter one model may take keyterms while another refuses them.
    private func key(_ service: TranscriptionService, _ model: String) -> String {
        "\(service.rawValue)/\(model)"
    }
}

/// Opens the TLS connection to an online service while the user is still speaking, so the upload
/// and the Dictate request after it do not pay for a fresh handshake when they are sent.
/// URLSession.shared keeps the connection alive and both requests reuse it.
final class ConnectionWarmer: @unchecked Sendable {
    static let shared = ConnectionWarmer()
    /// A connection opened this recently is assumed to still be alive.
    static let reuseWindow: TimeInterval = 20

    private let lock = NSLock()
    private var warmedAt: [String: Date] = [:]

    func warm(_ url: URL, session: URLSession = .shared, now: Date = Date()) {
        guard let host = url.host, let root = URL(string: "https://\(host)/") else { return }
        let shouldWarm = lock.withLock { () -> Bool in
            if let last = warmedAt[host], now.timeIntervalSince(last) < Self.reuseWindow {
                return false
            }
            warmedAt[host] = now
            return true
        }
        guard shouldWarm else { return }
        // HEAD on the host root: no API key, no body, any status will do.
        var request = URLRequest(url: root, timeoutInterval: 5)
        request.httpMethod = "HEAD"
        session.dataTask(with: request) { _, _, _ in }.resume()
        DebugLog.event("connectionWarm host=\(host)")
    }
}

enum OnlineTranscriber {
    static let timeout: TimeInterval = 15
    /// Below this, a tap was probably accidental; on-device text (likely empty) is enough.
    static let minimumSeconds: Double = 0.3

    /// Encodes and uploads one dictation, retrying once without hints if the API rejects them.
    static func transcribe(
        samples: [Float],
        language: RecognitionLanguage,
        terms: [String],
        appName: String?,
        service: TranscriptionService,
        model: String,
        apiKey: String,
        session: URLSession = .shared,
        hintCache: HintSupportCache = .shared
    ) async throws -> String {
        guard !apiKey.isEmpty else {
            throw OnlineTranscriptionError.missingKey
        }
        let seconds = Double(samples.count) / AudioClipCollector.sampleRate
        guard seconds >= minimumSeconds else {
            throw OnlineTranscriptionError.tooShort
        }
        let sendHints = hintCache.acceptsHints(service, model: model)
        var request = OnlineTranscriptionRequest(
            service: service,
            model: model,
            audio: AudioClipEncoder.encode(samples: samples, compressed: service.acceptsCompressedAudio),
            languages: service == .openRouter
                ? [OnlineTranscriptionRequest.openRouterLanguage(for: language)]
                : OnlineTranscriptionRequest.languages(for: language),
            keywords: sendHints ? OnlineTranscriptionRequest.sanitizedKeywords(terms) : [],
            // OpenRouter has no prompt field.
            prompt: service == .openRouter || !sendHints ? nil : appName.map { "Voice dictation typed into \($0)." }
        )
        DebugLog.event("onlineTranscriptionStart service=\(service.rawValue) model=\(model) audioSec=\(String(format: "%.1f", seconds)) bytes=\(request.audio.data.count) keywords=\(request.keywords.count)")
        do {
            return try await timedSend(request, apiKey: apiKey, session: session)
        } catch OnlineTranscriptionError.http(status: 400, _) where !request.keywords.isEmpty || request.prompt != nil {
            // A hint the API refuses (OpenRouter rejects keyterms for gpt-transcribe) should not
            // cost the user their dictation.
            DebugLog.event("onlineTranscriptionRetryWithoutHints")
            request.keywords = []
            request.prompt = nil
            let text = try await timedSend(request, apiKey: apiKey, session: session)
            // The plain request worked, so the hints were the problem: skip them from now on
            // instead of paying for a rejected request on every dictation.
            hintCache.markRejected(service, model: model)
            DebugLog.event("onlineTranscriptionHintsDisabled service=\(service.rawValue) model=\(model)")
            return text
        }
    }

    /// `send` plus a log line with the round-trip time and outcome; no text content.
    private static func timedSend(_ request: OnlineTranscriptionRequest, apiKey: String, session: URLSession) async throws -> String {
        let started = ContinuousClock.now
        func elapsed() -> Int64 {
            let components = started.duration(to: .now).components
            return components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000
        }
        do {
            let text = try await send(request, apiKey: apiKey, session: session)
            DebugLog.event("onlineTranscriptionAttempt ok ms=\(elapsed()) hints=\(!request.keywords.isEmpty)")
            return text
        } catch {
            let name = (error as? OnlineTranscriptionError)?.logName ?? "cancelled"
            DebugLog.event("onlineTranscriptionAttempt \(name) ms=\(elapsed()) hints=\(!request.keywords.isEmpty)")
            throw error
        }
    }

    static func send(_ request: OnlineTranscriptionRequest, apiKey: String, session: URLSession) async throws -> String {
        let urlRequest = request.urlRequest(apiKey: apiKey, timeout: timeout)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch let error as URLError {
            switch error.code {
            case .timedOut: throw OnlineTranscriptionError.timedOut
            // Cancellation is the caller's deadline or the user pressing Esc; let it through.
            case .cancelled: throw CancellationError()
            default: throw OnlineTranscriptionError.network(error.localizedDescription)
            }
        }
        guard let http = response as? HTTPURLResponse else {
            throw OnlineTranscriptionError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OnlineTranscriptionError.http(status: http.statusCode, message: OnlineTranscriptionRequest.errorMessage(from: data))
        }
        return try OnlineTranscriptionRequest.text(from: data)
    }

    /// Checks the key, and for OpenRouter that the chosen model exists, without sending audio;
    /// all lookups are free.
    static func checkKey(
        _ apiKey: String,
        service: TranscriptionService,
        model: String,
        session: URLSession = .shared
    ) async -> Result<Void, OnlineTranscriptionError> {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            return .failure(.missingKey)
        }
        var keyRequest = URLRequest(url: service.keyCheckEndpoint, timeoutInterval: 10)
        keyRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if case .failure(let error) = await get(keyRequest, session: session) {
            return .failure(error)
        }
        guard service == .openRouter else {
            return .success(())
        }
        guard let url = TranscriptionService.openRouterModelURL(model) else {
            return .failure(.unknownModel(model))
        }
        switch await get(URLRequest(url: url, timeoutInterval: 10), session: session) {
        case .success:
            return .success(())
        case .failure(.http(status: 404, _)):
            return .failure(.unknownModel(model))
        case .failure(let error):
            return .failure(error)
        }
    }

    private static func get(_ request: URLRequest, session: URLSession) async -> Result<Void, OnlineTranscriptionError> {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.invalidResponse)
            }
            guard (200..<300).contains(http.statusCode) else {
                return .failure(.http(status: http.statusCode, message: OnlineTranscriptionRequest.errorMessage(from: data)))
            }
            return .success(())
        } catch let error as URLError where error.code == .timedOut {
            return .failure(.timedOut)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }
}
