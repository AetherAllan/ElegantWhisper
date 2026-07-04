import Foundation

struct PromptStaticContext: Sendable {
    let systemPrompt: String

    func messages(transcript: String) -> [ChatMessage] {
        [
            ChatMessage(role: "system", content: systemPrompt),
            ChatMessage(role: "user", content: transcript)
        ]
    }
}

enum PromptStaticContextCache {
    private static let storage = PromptStaticContextStorage()

    static func context(stylePack: StylePack, hotwords: [String]) -> PromptStaticContext {
        let key = cacheKey(stylePack: stylePack, hotwords: hotwords)
        if let prompt = storage.prompt(for: key) {
            return PromptStaticContext(systemPrompt: prompt)
        }

        let prompt = LLMPromptBuilder.systemPrompt(template: stylePack.systemPrompt, hotwords: hotwords)
        storage.setPrompt(prompt, for: key)
        return PromptStaticContext(systemPrompt: prompt)
    }

    static func cacheKey(stylePack: StylePack, hotwords: [String]) -> String {
        [
            stylePack.id,
            stylePack.systemPrompt,
            hotwords
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\u{1f}")
        ].joined(separator: "\u{1e}")
    }

}

private final class PromptStaticContextStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var cachedPrompts: [String: String] = [:]

    func prompt(for key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return cachedPrompts[key]
    }

    func setPrompt(_ prompt: String, for key: String) {
        lock.lock()
        cachedPrompts[key] = prompt
        lock.unlock()
    }

}
