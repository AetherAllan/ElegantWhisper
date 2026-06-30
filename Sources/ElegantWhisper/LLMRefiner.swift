import Foundation

final class LLMRefiner {
    private let settings: SettingsStore

    init(settings: SettingsStore) {
        self.settings = settings
    }

    func refine(_ text: String, completion: @escaping (String) -> Void) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard settings.llmEnabled,
              !trimmed.isEmpty,
              !settings.apiKey.isEmpty,
              let request = makeRequest(text: trimmed)
        else {
            completion(text)
            return
        }

        URLSession.shared.dataTask(with: request) { data, _, error in
            guard error == nil,
                  let data,
                  let response = try? JSONDecoder().decode(ChatResponse.self, from: data),
                  let corrected = response.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines),
                  !corrected.isEmpty
            else {
                DispatchQueue.main.async { completion(text) }
                return
            }
            DispatchQueue.main.async { completion(corrected) }
        }.resume()
    }

    func testConnection(completion: @escaping (Bool, String) -> Void) {
        guard let request = makeRequest(text: "测试 Python 和 JSON。") else {
            completion(false, "Missing API settings")
            return
        }

        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error {
                DispatchQueue.main.async { completion(false, error.localizedDescription) }
                return
            }
            guard let data,
                  let response = try? JSONDecoder().decode(ChatResponse.self, from: data),
                  response.choices.first?.message.content.isEmpty == false
            else {
                DispatchQueue.main.async { completion(false, "Empty or invalid response") }
                return
            }
            DispatchQueue.main.async { completion(true, "Connection OK") }
        }.resume()
    }

    private func makeRequest(text: String) -> URLRequest? {
        guard let base = URL(string: settings.apiBaseURL),
              !settings.apiKey.isEmpty
        else {
            return nil
        }

        let url = base.appendingPathComponent("chat/completions")
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
