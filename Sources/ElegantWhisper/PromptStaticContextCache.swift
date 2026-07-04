import Foundation

struct PromptStaticContext: Equatable, Sendable {
    let cacheKey: String
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

    static func context(stylePack: StylePack, hotwords: [String], profile: String? = nil) -> PromptStaticContext {
        let key = cacheKey(stylePack: stylePack, hotwords: hotwords, profile: profile)
        if let prompt = storage.prompt(for: key) {
            return PromptStaticContext(cacheKey: key, systemPrompt: prompt)
        }

        var prompt = LLMPromptBuilder.systemPrompt(stylePack: stylePack, hotwords: hotwords)
        let profileText = profile?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !profileText.isEmpty {
            prompt += "\n\nUser profile:\n\(profileText)"
        }

        storage.setPrompt(prompt, for: key)
        return PromptStaticContext(cacheKey: key, systemPrompt: prompt)
    }

    static func cacheKey(stylePack: StylePack, hotwords: [String], profile: String? = nil) -> String {
        [
            stylePack.id,
            stylePack.systemPrompt,
            hotwords
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\u{1f}"),
            profile?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        ].joined(separator: "\u{1e}")
    }

    static func clear() {
        storage.clear()
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

    func clear() {
        lock.lock()
        cachedPrompts.removeAll()
        lock.unlock()
    }
}
