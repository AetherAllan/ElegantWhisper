import Foundation

struct StylePack: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var description: String
    var systemPrompt: String
    var active: Bool
    var updatedAt: Date
}

// Style packs are local prompt templates, not provider settings. Keeping them in one small JSON
// file matches the existing History/Dictionary stores and makes prompt edits easy to inspect.
final class StylePackStore: @unchecked Sendable {
    static let shared = StylePackStore()

    private let queue = DispatchQueue(label: "com.aetherallan.ElegantWhisper.style-packs")
    private let fileURL: URL
    private var cachedPacks: [StylePack] = []
    private var loaded = false

    init(fileURL: URL = AppConstants.applicationSupportDirectory.appendingPathComponent("style-packs.json")) {
        self.fileURL = fileURL
    }

    func packs() -> [StylePack] {
        queue.sync {
            loadIfNeeded()
            return cachedPacks
        }
    }

    func activePack() -> StylePack {
        queue.sync {
            loadIfNeeded()
            return cachedPacks.first { $0.active } ?? Self.builtinPacks[0]
        }
    }

    func setActive(id: String) {
        queue.sync {
            loadIfNeeded()
            guard cachedPacks.contains(where: { $0.id == id }) else {
                return
            }
            for index in cachedPacks.indices {
                cachedPacks[index].active = cachedPacks[index].id == id
            }
            save()
        }
    }

    func save(_ pack: StylePack) {
        queue.sync {
            loadIfNeeded()
            var next = pack
            next.updatedAt = Date()
            if let index = cachedPacks.firstIndex(where: { $0.id == next.id }) {
                cachedPacks[index] = next
            } else {
                cachedPacks.insert(next, at: 0)
            }
            if next.active {
                for index in cachedPacks.indices {
                    cachedPacks[index].active = cachedPacks[index].id == next.id
                }
            }
            ensureOneActivePack()
            save()
        }
    }

    @discardableResult
    func resetBuiltin(id: String) -> Bool {
        queue.sync {
            loadIfNeeded()
            guard var builtin = Self.builtinPacks.first(where: { $0.id == id }) else {
                return false
            }
            let wasActive = cachedPacks.first { $0.id == id }?.active ?? builtin.active
            builtin.active = wasActive
            builtin.updatedAt = Date()
            if let index = cachedPacks.firstIndex(where: { $0.id == id }) {
                cachedPacks[index] = builtin
            } else {
                cachedPacks.append(builtin)
            }
            ensureOneActivePack()
            save()
            return true
        }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: fileURL),
           let file = try? JSONDecoder().decode(StylePackFile.self, from: data)
        {
            cachedPacks = mergeWithBuiltins(file.packs)
        } else {
            cachedPacks = Self.builtinPacks
        }
        ensureOneActivePack()
    }

    private func mergeWithBuiltins(_ saved: [StylePack]) -> [StylePack] {
        var merged = saved
        for builtin in Self.builtinPacks where !merged.contains(where: { $0.id == builtin.id }) {
            merged.append(builtin)
        }
        return merged
    }

    private func ensureOneActivePack() {
        guard !cachedPacks.isEmpty else {
            cachedPacks = Self.builtinPacks
            return
        }
        if cachedPacks.contains(where: { $0.active }) {
            return
        }
        for index in cachedPacks.indices {
            cachedPacks[index].active = index == 0
        }
    }

    private func save() {
        do {
            try AppConstants.writePrivateJSON(StylePackFile(version: 1, packs: cachedPacks), to: fileURL)
        } catch {
            DebugLog.event("stylePackSaveFailed")
        }
    }

    static let builtinPacks: [StylePack] = [
        StylePack(
            id: "builtin.conservative",
            name: "Conservative Correction",
            description: "Fix obvious ASR mistakes without changing meaning.",
            systemPrompt: LLMPromptBuilder.conservativeTemplate,
            active: true,
            updatedAt: Date(timeIntervalSince1970: 0)
        ),
        StylePack(
            id: "builtin.prompt-cleanup",
            name: "Prompt Cleanup",
            description: "Turn spoken prompts into clearer requests while keeping the original intent.",
            systemPrompt: LLMPromptBuilder.promptCleanupTemplate,
            active: false,
            updatedAt: Date(timeIntervalSince1970: 0)
        ),
        StylePack(
            id: "builtin.technical",
            name: "Clear Technical Writing",
            description: "Clean technical dictation while preserving symbols, paths, APIs, and commands.",
            systemPrompt: LLMPromptBuilder.technicalTemplate,
            active: false,
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    ]
}

private struct StylePackFile: Codable {
    let version: Int
    let packs: [StylePack]
}
