import Foundation

enum RecognitionLanguage: String, CaseIterable {
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

final class SettingsStore {
    static let shared = SettingsStore()

    private let defaults = UserDefaults(suiteName: AppConstants.userDefaultsSuiteName) ?? .standard
    private let keychain = KeychainStore()

    private enum Key {
        static let language = "language"
        static let llmEnabled = "llmEnabled"
        static let apiBaseURL = "apiBaseURL"
        static let model = "model"
        static let requestTimeout = "requestTimeout"
        static let keepClipboardWithoutTarget = "keepClipboardWithoutTarget"
    }

    var language: RecognitionLanguage {
        get {
            RecognitionLanguage(rawValue: defaults.string(forKey: Key.language) ?? "") ?? .simplifiedChinese
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.language)
        }
    }

    var llmEnabled: Bool {
        get {
            defaults.object(forKey: Key.llmEnabled) as? Bool ?? false
        }
        set {
            defaults.set(newValue, forKey: Key.llmEnabled)
        }
    }

    var apiBaseURL: String {
        get {
            defaults.string(forKey: Key.apiBaseURL) ?? "https://api.openai.com/v1"
        }
        set {
            defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.apiBaseURL)
        }
    }

    var apiKey: String {
        get {
            keychain.string(for: "apiKey")
        }
        set {
            keychain.setString(newValue, for: "apiKey")
        }
    }

    var model: String {
        get {
            defaults.string(forKey: Key.model) ?? "gpt-4o-mini"
        }
        set {
            defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.model)
        }
    }

    var requestTimeout: TimeInterval {
        get {
            let value = defaults.double(forKey: Key.requestTimeout)
            return value > 0 ? value : 12
        }
        set {
            defaults.set(max(1, newValue), forKey: Key.requestTimeout)
        }
    }

    var keepClipboardWithoutTarget: Bool {
        get {
            defaults.object(forKey: Key.keepClipboardWithoutTarget) as? Bool ?? true
        }
        set {
            defaults.set(newValue, forKey: Key.keepClipboardWithoutTarget)
        }
    }
}
