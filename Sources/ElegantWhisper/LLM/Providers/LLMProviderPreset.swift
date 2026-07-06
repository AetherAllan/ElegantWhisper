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
        case .openRouterFree: "nvidia/nemotron-3-super-120b-a12b:free"
        case .inferenceNet: "nvidia/nemotron3-super"
        case .custom: nil
        }
    }

    var modelPresets: [String] {
        switch self {
        case .openAI:
            ["gpt-4o-mini"]
        case .openRouterFree:
            [
                "nvidia/nemotron-3-super-120b-a12b:free",
                "nvidia/nemotron-3-ultra-550b-a55b:free",
                "google/gemma-4-26b-a4b-it:free",
                "nvidia/nemotron-3-nano-30b-a3b:free",
                "openai/gpt-oss-20b:free",
                "liquid/lfm-2.5-1.2b-instruct:free",
                "meta-llama/llama-3.3-70b-instruct:free",
                "qwen/qwen3-next-80b-a3b-instruct:free",
                "openai/gpt-oss-120b:free"
            ]
        case .inferenceNet:
            [
                "nvidia/nemotron3-super",
                "glm-5.2",
                "inference-net/schematron-v2-turbo",
                "inference-net/schematron-v2-small"
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
            "Fixed :free models only—not openrouter/free. Best options listed first."
        case .inferenceNet:
            "OpenAI-compatible Inference.net API. Default uses Nemotron 3 Super for ASR polishing."
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
