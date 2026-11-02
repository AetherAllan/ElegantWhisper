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

/// Apple on-device model used for dictation. Both run through SpeechAnalyzer.
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
