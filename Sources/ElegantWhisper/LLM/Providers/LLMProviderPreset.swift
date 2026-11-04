import Foundation

enum LLMProvider: String, CaseIterable, Codable, Sendable {
    case openAI = "openai"
    case openRouter = "openrouter"
    case openRouterFree = "openrouterFree"
    case inferenceNet = "inferenceNet"
    case custom = "custom"

    var title: String {
        switch self {
        case .openAI: "OpenAI"
        case .openRouter: "OpenRouter"
        case .openRouterFree: "OpenRouter Free"
        case .inferenceNet: "Inference.net"
        case .custom: "Custom"
        }
    }

    var defaultBaseURL: String? {
        switch self {
        case .openAI: "https://api.openai.com/v1"
        case .openRouter, .openRouterFree: "https://openrouter.ai/api/v1"
        case .inferenceNet: "https://api.inference.net/v1"
        case .custom: nil
        }
    }

    var defaultModel: String? {
        switch self {
        case .openAI: "gpt-4o-mini"
        case .openRouter: Self.openRouterDictateModels[0]
        case .openRouterFree: "nvidia/nemotron-3-super-120b-a12b:free"
        case .inferenceNet: "nvidia/nemotron3-super"
        case .custom: nil
        }
    }

    var modelPresets: [String] {
        switch self {
        case .openAI:
            ["gpt-4o-mini"]
        case .openRouter:
            Self.openRouterDictateModels
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

    var note: String? {
        switch self {
        case .openAI:
            "Stable OpenAI-compatible polishing."
        case .openRouter:
            "Fast paid models suited to Dictate (about $0.0001 per sentence). Leave the key empty to use your OpenRouter key from Recognition."
        case .openRouterFree:
            nil
        case .inferenceNet:
            "OpenAI-compatible Inference.net API. Default uses Nemotron 3 Super for ASR polishing."
        case .custom:
            "Use any OpenAI-compatible endpoint."
        }
    }

    /// Small, cheap models picked for Dictate's latency budget (OpenRouter, November 2026), plus
    /// a few served by fast-inference providers. Thinking is turned off in OpenRouterCodec and
    /// requests are routed to the lowest-latency provider. Settings → Dictate → Compare Models
    /// times them with the user's key.
    static let openRouterDictateModels = [
        "qwen/qwen3.8-flash",
        "anthropic/claude-haiku-5.5",
        "z-ai/glm-5.3-flash",
        "deepseek/deepseek-v4.1-flash",
        "google/gemini-3.5-flash-lite",
        "qwen/qwen3.7-flash",
        "xiaomi/mimo-v2.6-flash",
        "openai/gpt-5.4-nano",
        "openai/gpt-oss-120b",
        "meta-llama/llama-3.3-70b-instruct",
        "mistralai/mistral-small-3.2-24b-instruct"
    ]

    var isOpenRouter: Bool {
        self == .openRouter || self == .openRouterFree
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
