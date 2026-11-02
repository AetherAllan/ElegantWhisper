import Foundation

// SettingsStore has no app-owned mutable cache: values go through UserDefaults
// and Keychain calls. UserDefaults is thread-safe for these simple get/set uses,
// and KeychainStore performs one Security framework operation per access.
final class SettingsStore: @unchecked Sendable {
    static let shared = SettingsStore()

    private let defaults: UserDefaults
    private let keychain: KeychainStore

    init(
        defaults: UserDefaults = UserDefaults(suiteName: AppConstants.userDefaultsSuiteName) ?? .standard,
        keychain: KeychainStore = KeychainStore()
    ) {
        self.defaults = defaults
        self.keychain = keychain
    }

    private enum Key {
        static let language = "language"
        static let speechModel = "speechModel"
        static let llmEnabled = "llmEnabled"
        static let shareCursorTextWithLLM = "shareCursorTextWithLLM"
        static let llmProvider = "llmProvider"
        static let apiBaseURL = "apiBaseURL"
        static let model = "model"
        static let requestTimeout = "requestTimeout"
        static let keepClipboardWithoutTarget = "keepClipboardWithoutTarget"
        static let saveHistory = "saveHistory"
        static let postEditLearningEnabled = "postEditLearningEnabled"
        static let muteOutputDuringRecording = "muteOutputDuringRecording"
        static let onboardingCompleted = "onboardingCompleted"
        static let usageStats = "usageStats"
    }

    var language: RecognitionLanguage {
        get {
            RecognitionLanguage(rawValue: defaults.string(forKey: Key.language) ?? "") ?? .simplifiedChinese
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.language)
        }
    }

    var speechModel: SpeechRecognitionModel {
        get {
            SpeechRecognitionModel(rawValue: defaults.string(forKey: Key.speechModel) ?? "") ?? .speech
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.speechModel)
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

    /// Opt-in: send a short, redacted window of text around the cursor with each polish request.
    var shareCursorTextWithLLM: Bool {
        get {
            defaults.object(forKey: Key.shareCursorTextWithLLM) as? Bool ?? false
        }
        set {
            defaults.set(newValue, forKey: Key.shareCursorTextWithLLM)
        }
    }

    var llmProvider: LLMProvider {
        get {
            if let raw = defaults.string(forKey: Key.llmProvider),
               let provider = LLMProvider(rawValue: raw)
            {
                return provider
            }
            // Existing installs only have Base URL / Model. Infer from Base URL so old settings
            // keep working without a separate migration file.
            return LLMProvider.inferred(from: apiBaseURL)
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.llmProvider)
        }
    }

    var apiBaseURL: String {
        get {
            defaults.string(forKey: Key.apiBaseURL) ?? LLMProvider.openAI.defaultBaseURL ?? "https://api.openai.com/v1"
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
            let stored = defaults.string(forKey: Key.model)
            if llmProvider == .openRouterFree, stored == "openrouter/free" {
                // openrouter/free is a random router. It made polishing look "successful" in logs
                // while sometimes routing to models that returned empty/reasoning-only or unrelated
                // text. Existing installs using that old preset should move to the stable free
                // model without requiring users to rediscover the setting manually.
                return LLMProvider.openRouterFree.defaultModel!
            }
            if llmProvider == .inferenceNet,
               let stored,
               Self.isStaleInferenceCatalogModel(stored) {
                return LLMProvider.inferenceNet.defaultModel ?? "nvidia/nemotron3-super"
            }
            return stored ?? llmProvider.defaultModel ?? LLMProvider.openAI.defaultModel ?? "gpt-4o-mini"
        }
        set {
            defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.model)
        }
    }

    private static func isStaleInferenceCatalogModel(_ model: String) -> Bool {
        let lower = model.lowercased()
        if lower == "nvidia/nemotron3-super" || lower == "glm-5.2" || lower.hasPrefix("inference-net/") {
            return false
        }
        let stalePrefixes = ["google/", "meta-llama/", "mistralai/", "qwen/", "deepseek/", "openai/gpt-oss", "openai:"]
        return stalePrefixes.contains { lower.hasPrefix($0) } || lower == "gpt-5-mini"
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

    var saveHistory: Bool {
        get {
            defaults.object(forKey: Key.saveHistory) as? Bool ?? true
        }
        set {
            defaults.set(newValue, forKey: Key.saveHistory)
        }
    }

    var postEditLearningEnabled: Bool {
        get {
            defaults.object(forKey: Key.postEditLearningEnabled) as? Bool ?? false
        }
        set {
            defaults.set(newValue, forKey: Key.postEditLearningEnabled)
        }
    }

    var muteOutputDuringRecording: Bool {
        get {
            defaults.object(forKey: Key.muteOutputDuringRecording) as? Bool ?? true
        }
        set {
            defaults.set(newValue, forKey: Key.muteOutputDuringRecording)
        }
    }

    var usageStats: UsageStats {
        get {
            defaults.data(forKey: Key.usageStats).flatMap { try? JSONDecoder().decode(UsageStats.self, from: $0) } ?? UsageStats()
        }
        set {
            defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.usageStats)
        }
    }

    var onboardingCompleted: Bool {
        get {
            defaults.bool(forKey: Key.onboardingCompleted)
        }
        set {
            defaults.set(newValue, forKey: Key.onboardingCompleted)
        }
    }
}
