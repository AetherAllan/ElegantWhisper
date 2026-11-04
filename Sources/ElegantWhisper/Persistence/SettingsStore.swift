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
        static let transcriptionProvider = "transcriptionProvider"
        static let openRouterTranscriptionModel = "openRouterTranscriptionModel"
        static let llmEnabled = "llmEnabled"
        static let shareCursorTextWithLLM = "shareCursorTextWithLLM"
        static let readWindowText = "readWindowText"
        static let dictateMatchesAppTone = "dictateMatchesAppTone"
        static let lastStylePackID = "lastStylePackID"
        static let appTheme = "appTheme"
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

    /// The Apple model. An older build stored "openAI" here for online recognition; that reads
    /// as the newer Apple model now, and migrateTranscriptionSettings() moves it to the provider.
    var speechModel: SpeechRecognitionModel {
        get {
            SpeechRecognitionModel(rawValue: defaults.string(forKey: Key.speechModel) ?? "") ?? .speech
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.speechModel)
        }
    }

    var transcriptionProvider: TranscriptionProvider {
        get {
            TranscriptionProvider(rawValue: defaults.string(forKey: Key.transcriptionProvider) ?? "") ?? .apple
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.transcriptionProvider)
        }
    }

    var openRouterTranscriptionModel: String {
        get {
            let stored = defaults.string(forKey: Key.openRouterTranscriptionModel)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return stored.isEmpty ? TranscriptionModelOption.defaultOpenRouterModel : stored
        }
        set {
            defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.openRouterTranscriptionModel)
        }
    }

    /// The model ID sent for an online provider.
    func transcriptionModel(for provider: TranscriptionProvider) -> String {
        switch provider {
        case .apple: speechModel.rawValue
        case .openAI: TranscriptionModelOption.openAIModel.id
        case .openRouter: openRouterTranscriptionModel
        }
    }

    func transcriptionKey(for provider: TranscriptionProvider) -> String {
        switch provider {
        case .apple: ""
        case .openAI: openAITranscriptionKey
        case .openRouter: openRouterTranscriptionKey
        }
    }

    func setTranscriptionKey(_ key: String, for provider: TranscriptionProvider) {
        switch provider {
        case .apple: break
        case .openAI: openAITranscriptionKey = key
        case .openRouter: openRouterTranscriptionKey = key
        }
    }

    /// One-time move from the single-key setup: "openAI" in speechModel meant online recognition,
    /// and an OpenRouter key may sit in the OpenAI slot because the service used to be picked by
    /// key prefix.
    func migrateTranscriptionSettings() {
        if defaults.string(forKey: Key.speechModel) == "openAI" {
            let key = openAITranscriptionKey
            transcriptionProvider = TranscriptionService.looksLikeOpenRouterKey(key) ? .openRouter : .openAI
            speechModel = .speech
        }
        let legacyKey = openAITranscriptionKey
        if TranscriptionService.looksLikeOpenRouterKey(legacyKey), openRouterTranscriptionKey.isEmpty {
            openRouterTranscriptionKey = legacyKey
            openAITranscriptionKey = ""
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

    /// Dictate adapts tone to the kind of app being dictated into (chat, email, code, documents).
    var dictateMatchesAppTone: Bool {
        get {
            defaults.object(forKey: Key.dictateMatchesAppTone) as? Bool ?? true
        }
        set {
            defaults.set(newValue, forKey: Key.dictateMatchesAppTone)
        }
    }

    var appTheme: AppTheme {
        get {
            AppTheme(rawValue: defaults.string(forKey: Key.appTheme) ?? "") ?? .standard
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.appTheme)
        }
    }

    /// The Style Pack to return to when leaving Dictate for "Style pack" mode.
    var lastStylePackID: String {
        get {
            defaults.string(forKey: Key.lastStylePackID) ?? StylePackStore.programmerPackID
        }
        set {
            defaults.set(newValue, forKey: Key.lastStylePackID)
        }
    }

    /// The key polishing and Dictate actually send. With an OpenRouter provider and no key of its
    /// own, reuse the OpenRouter key from Recognition so the same account is not entered twice.
    var effectiveLLMAPIKey: String {
        let key = apiKey
        guard key.isEmpty, llmProvider.isOpenRouter else {
            return key
        }
        return openRouterTranscriptionKey
    }

    /// Read technical words from the front window (locally) to fix their spelling after recognition.
    var readWindowText: Bool {
        get {
            defaults.object(forKey: Key.readWindowText) as? Bool ?? true
        }
        set {
            defaults.set(newValue, forKey: Key.readWindowText)
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

    /// Keys for online recognition, one per provider and separate from the polishing key.
    var openAITranscriptionKey: String {
        get {
            keychain.string(for: "openAITranscriptionKey")
        }
        set {
            keychain.setString(newValue.trimmingCharacters(in: .whitespacesAndNewlines), for: "openAITranscriptionKey")
        }
    }

    var openRouterTranscriptionKey: String {
        get {
            keychain.string(for: "openRouterTranscriptionKey")
        }
        set {
            keychain.setString(newValue.trimmingCharacters(in: .whitespacesAndNewlines), for: "openRouterTranscriptionKey")
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
