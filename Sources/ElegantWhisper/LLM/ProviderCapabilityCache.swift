import Foundation

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

    func supportsStructuredOutput(for provider: LLMProvider, model: String) -> Bool {
        guard provider == .openRouterFree || provider == .inferenceNet else {
            return false
        }
        guard let unsupportedUntil = defaults.object(forKey: key(provider: provider, model: model)) as? Date else {
            return true
        }
        return unsupportedUntil <= now()
    }

    func markStructuredOutputUnsupported(provider: LLMProvider, model: String, ttl: TimeInterval = 24 * 60 * 60) {
        defaults.set(now().addingTimeInterval(ttl), forKey: key(provider: provider, model: model))
    }

    private func key(provider: LLMProvider, model: String) -> String {
        "llm.capabilities.\(provider.rawValue).\(model)"
    }
}
