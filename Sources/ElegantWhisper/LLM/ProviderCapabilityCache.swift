import Foundation

struct LLMProviderCapabilities: Codable, Equatable {
    var supportsStructuredOutput: Bool
    var supportsPromptCaching: Bool
    var supportsReasoningControl: Bool
}

final class ProviderCapabilityCache: @unchecked Sendable {
    static let shared = ProviderCapabilityCache()

    private let defaults: UserDefaults
    private let now: @Sendable () -> Date

    init(
        defaults: UserDefaults = UserDefaults(suiteName: AppConstants.userDefaultsSuiteName) ?? .standard,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.now = now
    }

    func capabilities(for provider: LLMProvider, model: String) -> LLMProviderCapabilities {
        var capabilities = defaultCapabilities(for: provider)
        guard let entry = cachedEntry(provider: provider, model: model) else {
            return capabilities
        }
        if let unsupportedUntil = entry.structuredOutputUnsupportedUntil, unsupportedUntil > now() {
            capabilities.supportsStructuredOutput = false
        }
        return capabilities
    }

    func markStructuredOutputUnsupported(provider: LLMProvider, model: String, ttl: TimeInterval = 24 * 60 * 60) {
        let entry = CachedProviderCapabilities(
            structuredOutputUnsupportedUntil: now().addingTimeInterval(ttl)
        )
        defaults.set(try? JSONEncoder().encode(entry), forKey: key(provider: provider, model: model))
    }

    func clear(provider: LLMProvider, model: String) {
        defaults.removeObject(forKey: key(provider: provider, model: model))
    }

    private func defaultCapabilities(for provider: LLMProvider) -> LLMProviderCapabilities {
        switch provider {
        case .openRouterFree:
            LLMProviderCapabilities(
                supportsStructuredOutput: true,
                supportsPromptCaching: false,
                supportsReasoningControl: true
            )
        case .openAI, .custom:
            LLMProviderCapabilities(
                supportsStructuredOutput: false,
                supportsPromptCaching: false,
                supportsReasoningControl: false
            )
        }
    }

    private func cachedEntry(provider: LLMProvider, model: String) -> CachedProviderCapabilities? {
        guard let data = defaults.data(forKey: key(provider: provider, model: model)) else {
            return nil
        }
        return try? JSONDecoder().decode(CachedProviderCapabilities.self, from: data)
    }

    private func key(provider: LLMProvider, model: String) -> String {
        "llm.capabilities.\(provider.rawValue).\(model)"
    }
}

private struct CachedProviderCapabilities: Codable {
    let structuredOutputUnsupportedUntil: Date?
}
