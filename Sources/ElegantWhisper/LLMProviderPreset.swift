import Foundation

enum LLMProvider: String, CaseIterable, Codable {
    case openAI = "openai"
    case openRouterFree = "openrouterFree"
    case custom = "custom"

    var title: String {
        switch self {
        case .openAI: "OpenAI"
        case .openRouterFree: "OpenRouter Free"
        case .custom: "Custom"
        }
    }

    var defaultBaseURL: String? {
        switch self {
        case .openAI: "https://api.openai.com/v1"
        case .openRouterFree: "https://openrouter.ai/api/v1"
        case .custom: nil
        }
    }

    var defaultModel: String? {
        switch self {
        case .openAI: "gpt-4o-mini"
        case .openRouterFree: "openrouter/free"
        case .custom: nil
        }
    }

    var note: String {
        switch self {
        case .openAI:
            "Stable OpenAI-compatible polishing."
        case .openRouterFree:
            "Routes to random free OpenRouter models. Good for testing, not guaranteed stable."
        case .custom:
            "Use any OpenAI-compatible endpoint."
        }
    }

    static func inferred(from baseURL: String) -> LLMProvider {
        guard let host = URL(string: baseURL)?.host?.lowercased() else {
            return .custom
        }
        if host.contains("openrouter") {
            return .openRouterFree
        }
        if host.contains("openai") {
            return .openAI
        }
        return .custom
    }

    func applyHeaders(to request: inout URLRequest) {
        switch self {
        case .openRouterFree:
            // OpenRouter's app attribution headers are optional. Send only the title so the app is
            // identifiable without forcing users to provide a public website/HTTP-Referer.
            request.setValue(AppConstants.productName, forHTTPHeaderField: "X-OpenRouter-Title")
        case .openAI, .custom:
            break
        }
    }
}
