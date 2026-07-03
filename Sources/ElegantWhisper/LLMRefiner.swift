import Foundation

final class LLMRefiner: Sendable {
    private let settings: SettingsStore
    private let stylePacks: StylePackStore

    init(settings: SettingsStore, stylePacks: StylePackStore = .shared) {
        self.settings = settings
        self.stylePacks = stylePacks
    }

    @discardableResult
    func refine(
        _ text: String,
        hotwords: [String] = [],
        completion: @escaping @MainActor @Sendable (String) -> Void
    ) -> URLSessionDataTask? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard settings.llmEnabled,
              !trimmed.isEmpty,
              !settings.apiKey.isEmpty,
              let request = makeRequest(text: trimmed, hotwords: hotwords)
        else {
            Task { @MainActor in
                completion(text)
            }
            return nil
        }

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            guard error == nil,
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let data,
                  data.count < 512_000,
                  let response = try? JSONDecoder().decode(ChatResponse.self, from: data),
                  let choice = response.choices.first,
                  self.acceptsChoice(original: trimmed, choice: choice)
            else {
                Task { @MainActor in
                    completion(text)
                }
                return
            }
            Task { @MainActor in
                completion(choice.message.content.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        task.resume()
        return task
    }

    func testConnection(completion: @escaping @MainActor @Sendable (Bool, String) -> Void) {
        guard let request = makeRequest(text: "我想用配森解析杰森文件。", hotwords: ["Python", "JSON"]) else {
            Task { @MainActor in
                completion(false, "Missing API settings")
            }
            return
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                Task { @MainActor in
                    completion(false, error.localizedDescription)
                }
                return
            }
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode)
            else {
                Task { @MainActor in
                    completion(false, "HTTP request failed")
                }
                return
            }
            guard let data,
                  data.count < 512_000,
                  let response = try? JSONDecoder().decode(ChatResponse.self, from: data),
                  response.choices.first?.message.content.isEmpty == false
            else {
                Task { @MainActor in
                    completion(false, "Empty or invalid response")
                }
                return
            }
            Task { @MainActor in
                completion(true, "Connection OK (\(response.model ?? self.settings.model))")
            }
        }.resume()
    }

    func makeRequest(text: String, hotwords: [String] = []) -> URLRequest? {
        guard let base = URL(string: settings.apiBaseURL),
              isAllowedBaseURL(base),
              !settings.apiKey.isEmpty
        else {
            return nil
        }

        let url = completionsURL(from: base)
        let provider = settings.llmProvider
        let stylePack = stylePacks.activePack()
        var request = URLRequest(url: url, timeoutInterval: settings.requestTimeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        provider.applyHeaders(to: &request)

        let body = ChatRequest(
            model: settings.model,
            messages: [
                ChatMessage(role: "system", content: LLMPromptBuilder.systemPrompt(stylePack: stylePack, hotwords: hotwords)),
                ChatMessage(role: "user", content: text)
            ],
            temperature: 0,
            maxTokens: maxTokens(for: text)
        )

        request.httpBody = try? JSONEncoder().encode(body)
        return request
    }

    func acceptsChoice(original: String, choice: ChatResponse.Choice) -> Bool {
        // OpenAI-compatible APIs report `finish_reason=length` when max_tokens cuts the response.
        // A truncated correction is worse than no correction because it can silently drop the end
        // of a dictation before paste. Fall back to the original transcript instead.
        guard choice.finishReason != "length" else {
            return false
        }
        return acceptsCorrection(original: original, corrected: choice.message.content)
    }

    func acceptsCorrection(original: String, corrected: String) -> Bool {
        let corrected = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !corrected.isEmpty else {
            return false
        }

        let originalCount = original.count
        let correctedCount = corrected.count
        guard correctedCount <= max(32, Int(Double(originalCount) * 1.8)) else {
            return false
        }
        if originalCount > 10, correctedCount < Int(Double(originalCount) * 0.5) {
            return false
        }

        // ponytail: exact edit-ratio check only for normal dictation snippets; very long text
        // falls back to length bounds so correction never becomes an O(n^2) surprise.
        guard max(originalCount, correctedCount) <= 300 else {
            return true
        }
        return editDistanceRatio(original, corrected) <= 0.8
    }

    func maxTokens(for text: String) -> Int {
        // Keep short requests cheap, but do not cap long dictations at 256 tokens. The output
        // should usually be close to input length, so a character-based ceiling is enough here and
        // avoids building a tokenizer just for a safety budget.
        min(4096, max(256, text.count * 2))
    }

    private func completionsURL(from base: URL) -> URL {
        if base.path.trimmingCharacters(in: .init(charactersIn: "/")).hasSuffix("chat/completions") {
            return base
        }
        return base.appendingPathComponent("chat/completions")
    }

    private func isAllowedBaseURL(_ url: URL) -> Bool {
        if url.scheme == "https" {
            return true
        }
        let host = url.host?.lowercased()
        return url.scheme == "http" && (host == "localhost" || host == "127.0.0.1" || host == "::1")
    }

    private func editDistanceRatio(_ lhs: String, _ rhs: String) -> Double {
        let a = Array(lhs)
        let b = Array(rhs)
        guard !a.isEmpty || !b.isEmpty else {
            return 0
        }
        var previous = Array(0...b.count)
        var current = previous
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return Double(previous[b.count]) / Double(max(a.count, b.count))
    }
}

private struct ChatRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double
    let maxTokens: Int

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case maxTokens = "max_tokens"
    }
}

struct ChatMessage: Codable {
    let role: String
    let content: String
}

struct ChatResponse: Decodable {
    let model: String?
    let choices: [Choice]

    struct Choice: Decodable {
        let message: ChatMessage
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }
}
