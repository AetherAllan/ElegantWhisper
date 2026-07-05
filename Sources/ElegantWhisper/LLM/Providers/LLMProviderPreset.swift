import Foundation

enum LLMProvider: String, CaseIterable, Codable, Sendable {
    case openAI = "openai"
    case openRouterFree = "openrouterFree"
    case inferenceNet = "inferenceNet"
    case custom = "custom"

    var title: String {
        switch self {
        case .openAI: "OpenAI"
        case .openRouterFree: "OpenRouter Free"
        case .inferenceNet: "Inference.net"
        case .custom: "Custom"
        }
    }

    var defaultBaseURL: String? {
        switch self {
        case .openAI: "https://api.openai.com/v1"
        case .openRouterFree: "https://openrouter.ai/api/v1"
        case .inferenceNet: "https://api.inference.net/v1"
        case .custom: nil
        }
    }

    var defaultModel: String? {
        switch self {
        case .openAI: "gpt-4o-mini"
        case .openRouterFree: "nvidia/nemotron-3-nano-30b-a3b:free"
        case .inferenceNet: "inference-net/schematron-v2-turbo"
        case .custom: nil
        }
    }

    var modelPresets: [String] {
        switch self {
        case .openAI:
            ["gpt-4o-mini"]
        case .openRouterFree:
            ["nvidia/nemotron-3-nano-30b-a3b:free"]
        case .inferenceNet:
            [
                "inference-net/schematron-v2-turbo",
                "inference-net/schematron-v2-small",
                "google/gemma-3-27b-instruct/bf-16",
                "nvidia/nemotron3-super"
            ]
        case .custom:
            []
        }
    }

    var note: String {
        switch self {
        case .openAI:
            "Stable OpenAI-compatible polishing."
        case .openRouterFree:
            "Routes to random free OpenRouter models. Good for testing, not guaranteed stable."
        case .inferenceNet:
            "OpenAI-compatible Inference.net API. Default uses their low-cost Schematron structured-output model."
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
        if host.contains("inference.net") {
            return .inferenceNet
        }
        if host.contains("openai") {
            return .openAI
        }
        return .custom
    }
}
