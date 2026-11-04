import Foundation

enum RecognitionLanguage: String, CaseIterable, Codable {
    case englishUS = "en-US"
    case simplifiedChinese = "zh-CN"
    case traditionalChinese = "zh-TW"
    case japanese = "ja-JP"
    case korean = "ko-KR"

    var menuTitle: String {
        switch self {
        case .englishUS: "English"
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁體中文"
        case .japanese: "日本語"
        case .korean: "한국어"
        }
    }
}

/// Apple on-device model, run through SpeechAnalyzer. With an online provider it still runs during
/// recording for the live preview and as the fallback when the request fails.
enum SpeechRecognitionModel: String, CaseIterable, Codable {
    /// Apple's newer general-purpose model (`SpeechTranscriber`, macOS 26+).
    case speech
    /// The classic dictation model (`DictationTranscriber`) the app used before.
    case dictation

    var title: String {
        switch self {
        case .speech: "Apple Speech (newer)"
        case .dictation: "Apple Dictation (classic)"
        }
    }
}

/// Who turns the recording into text.
enum TranscriptionProvider: String, CaseIterable, Codable, Identifiable {
    case apple
    case openAI
    case openRouter

    var id: Self { self }

    var title: String {
        switch self {
        case .apple: "This Mac"
        case .openAI: "OpenAI"
        case .openRouter: "OpenRouter"
        }
    }

    /// nil for on-device recognition.
    var service: TranscriptionService? {
        switch self {
        case .apple: nil
        case .openAI: .openAI
        case .openRouter: .openRouter
        }
    }
}

/// A speech-to-text model offered in the OpenRouter picker. Any other model ID can be typed in.
struct TranscriptionModelOption: Identifiable, Equatable {
    let id: String
    let name: String
    /// US dollars per minute of audio, as listed by OpenRouter.
    let pricePerMinute: Double
    let note: String

    /// Two significant digits, so $0.0045 and $0.00048 both read exactly.
    var priceText: String {
        let style = FloatingPointFormatStyle<Double>.number
            .precision(.significantDigits(1...2))
            .locale(Locale(identifier: "en_US"))
        return "$\(pricePerMinute.formatted(style))/min"
    }

    static let openAIModel = TranscriptionModelOption(
        id: "gpt-transcribe",
        name: "GPT Transcribe",
        pricePerMinute: 0.0045,
        note: "OpenAI's current speech-to-text model; takes word hints and several languages."
    )

    /// Picked for mixed Chinese and English push-to-talk dictation. Prices and notes come from
    /// OpenRouter's model listing (November 2026); they are not our own benchmarks.
    static let openRouterPresets: [TranscriptionModelOption] = [
        TranscriptionModelOption(id: "openai/gpt-transcribe", name: "OpenAI GPT Transcribe", pricePerMinute: 0.0045, note: "Accurate. Word hints are not accepted through OpenRouter."),
        TranscriptionModelOption(id: "qwen/qwen3-asr-1.7b", name: "Qwen3 ASR 1.7B", pricePerMinute: 0.00048, note: "Chinese specialist: 30 languages and 22 Chinese dialects."),
        TranscriptionModelOption(id: "microsoft/mai-transcribe-2", name: "Microsoft MAI-Transcribe 2", pricePerMinute: 0.0017, note: "Multilingual with code-switching; top of the FLEURS benchmark."),
        TranscriptionModelOption(id: "meta/muse-voice-transcribe-1.0", name: "Meta Muse Voice Transcribe", pricePerMinute: 0.003, note: "Built for push-to-talk, with keyword and language biasing."),
        TranscriptionModelOption(id: "mistralai/voxtral-small-transcribe-3-0", name: "Mistral Voxtral Small Transcribe 3", pricePerMinute: 0.004, note: "Context biasing for domain vocabulary."),
        TranscriptionModelOption(id: "openai/whisper-large-v3-turbo", name: "Whisper Large v3 Turbo", pricePerMinute: 0.0002, note: "Fastest and cheapest; less accurate for Chinese."),
    ]

    static let defaultOpenRouterModel = openRouterPresets[0].id
}
