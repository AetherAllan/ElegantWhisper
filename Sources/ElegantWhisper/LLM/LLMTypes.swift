import Foundation

enum LLMOutputFormat: Sendable, Equatable {
    case plainText
    case correctedTextJSON
}

struct LLMTextRequest: Sendable {
    let model: String
    let systemPrompt: String
    let userText: String
    let temperature: Double?
    let maxOutputTokens: Int
    let outputFormat: LLMOutputFormat
}

struct LLMTextResponse: Sendable {
    let text: String
    let finishReason: String?
    let model: String?
    let usage: LLMUsage?
}

struct LLMUsage: Sendable, Equatable {
    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?
}

enum LLMProviderError: Equatable {
    case freeDailyLimit
    case rateLimit
    case structuredOutputUnsupported(String)
    case providerMessage(String)
    case requestFailed

    var displayMessage: String {
        switch self {
        case .freeDailyLimit:
            "free-models-per-day"
        case .rateLimit:
            "rate-limit"
        case .structuredOutputUnsupported(let message), .providerMessage(let message):
            message
        case .requestFailed:
            "request failed"
        }
    }

    var isStructuredOutputUnsupported: Bool {
        if case .structuredOutputUnsupported = self {
            return true
        }
        return false
    }
}

struct ChatMessage: Codable, Sendable, Equatable {
    let role: String
    let content: String?
}

final class LLMRefinementTask: @unchecked Sendable {
    private let lock = NSLock()
    private var currentTask: URLSessionDataTask?
    private var cancelled = false
    private var failure: String?

    /// Set when the request failed for a reason the user has to fix (key, credits, model), so the
    /// app can say why the recognized text was inserted unchanged. Nil for timeouts and rejections.
    var configurationFailure: String? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }

    func setConfigurationFailure(_ reason: String) {
        lock.lock()
        failure = reason
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func setCurrentTask(_ task: URLSessionDataTask) {
        lock.lock()
        if cancelled {
            lock.unlock()
            task.cancel()
            return
        }
        currentTask = task
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = currentTask
        currentTask = nil
        lock.unlock()
        task?.cancel()
    }
}

final class LLMSessionCapabilityState: @unchecked Sendable {
    private let lock = NSLock()
    private var structuredUnsupported = Set<String>()

    func supportsStructuredOutput(provider: LLMProvider, model: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !structuredUnsupported.contains(key(provider: provider, model: model))
    }

    func markStructuredOutputUnsupported(provider: LLMProvider, model: String) {
        // Keep this process-local. A provider/model can gain structured-output support later, and
        // a stale UserDefaults flag would silently force plain text for future app launches.
        lock.lock()
        structuredUnsupported.insert(key(provider: provider, model: model))
        lock.unlock()
    }

    private func key(provider: LLMProvider, model: String) -> String {
        "\(provider.rawValue)\u{1e}\(model)"
    }
}
