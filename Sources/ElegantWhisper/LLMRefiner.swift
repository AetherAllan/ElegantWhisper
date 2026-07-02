import Foundation

final class LLMRefiner: Sendable {
    private let settings: SettingsStore

    init(settings: SettingsStore) {
        self.settings = settings
    }

    @discardableResult
    func refine(_ text: String, completion: @escaping @MainActor @Sendable (String) -> Void) -> URLSessionDataTask? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard settings.llmEnabled,
              !trimmed.isEmpty,
              !settings.apiKey.isEmpty,
              let request = makeRequest(text: trimmed)
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
                  let corrected = response.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines),
                  self.acceptsCorrection(original: trimmed, corrected: corrected)
            else {
                Task { @MainActor in
                    completion(text)
                }
                return
            }
            Task { @MainActor in
                completion(corrected)
            }
        }
        task.resume()
        return task
    }

    func testConnection(completion: @escaping @MainActor @Sendable (Bool, String) -> Void) {
        guard let request = makeRequest(text: "测试 Python 和 JSON。") else {
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
                completion(true, "Connection OK")
            }
        }.resume()
    }

    private func makeRequest(text: String) -> URLRequest? {
        guard let base = URL(string: settings.apiBaseURL),
              isAllowedBaseURL(base),
              !settings.apiKey.isEmpty
        else {
            return nil
        }

        let url = completionsURL(from: base)
        var request = URLRequest(url: url, timeoutInterval: settings.requestTimeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ChatRequest(
            model: settings.model,
            messages: [
                ChatMessage(role: "system", content: """
                You correct conservative speech recognition errors only. Fix obvious Chinese homophones and spoken technical terms such as 配森 -> Python and 杰森 -> JSON. Do not polish, expand, summarize, translate, delete, or change meaning. If the text is already correct, return it unchanged. Return only the corrected text.
                """),
                ChatMessage(role: "user", content: text)
            ],
            temperature: 0
        )

        request.httpBody = try? JSONEncoder().encode(body)
        return request
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
}

private struct ChatMessage: Codable {
    let role: String
    let content: String
}

private struct ChatResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: ChatMessage
    }
}
