import Foundation

struct PromptStaticContext: Sendable {
    let systemPrompt: String

    func messages(transcript: String, speechContext: SpeechFocusContext? = nil) -> [ChatMessage] {
        let prompt = speechContext?.promptSection.map { "\(systemPrompt)\n\n\($0)" } ?? systemPrompt
        return [
            ChatMessage(role: "system", content: prompt),
            ChatMessage(role: "user", content: transcript)
        ]
    }
}

enum PromptStaticContextCache {
    private static let storage = PromptStaticContextStorage()

    static func context(stylePack: StylePack) -> PromptStaticContext {
        let key = cacheKey(stylePack: stylePack)
        if let prompt = storage.prompt(for: key) {
            return PromptStaticContext(systemPrompt: prompt)
        }

        let prompt = LLMPromptBuilder.systemPrompt(template: stylePack.systemPrompt)
        storage.setPrompt(prompt, for: key)
        return PromptStaticContext(systemPrompt: prompt)
    }

    static func cacheKey(stylePack: StylePack) -> String {
        [
            stylePack.id,
            stylePack.systemPrompt
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
