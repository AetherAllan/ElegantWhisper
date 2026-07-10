import Observation

struct StyleDraft: Equatable {
    var id: String
    var prompt: String

    init(pack: StylePack) {
        id = pack.id
        prompt = pack.systemPrompt
    }
}

@MainActor
@Observable
final class StylesModel {
    private let store: StylePackStore
    private(set) var packs: [StylePack]
    var draft: StyleDraft
    private(set) var savedDraft: StyleDraft

    init(store: StylePackStore) {
        self.store = store
        packs = store.packs()
        let draft = StyleDraft(pack: store.activePack())
        self.draft = draft
        savedDraft = draft
    }

    var isDirty: Bool {
        draft != savedDraft
    }

    var activePack: StylePack? {
        packs.first(where: \.active)
    }

    var effectivePrompt: String {
        LLMPromptBuilder.systemPrompt(template: draft.prompt)
    }

    func select(id: String) {
        store.setActive(id: id)
        reloadPacks()
        loadActiveDraft()
    }

    @discardableResult
    func save() -> Bool {
        guard var pack = packs.first(where: { $0.id == draft.id }) else { return false }
        pack.systemPrompt = draft.prompt
        pack.active = true
        store.save(pack)
        reloadPacks()
        loadActiveDraft()
        return true
    }

    @discardableResult
    func reset() -> Bool {
        guard store.resetBuiltin(id: draft.id) else { return false }
        reloadPacks()
        loadActiveDraft()
        return true
    }

    func reloadPacks() {
        // Runtime refreshes update the list but never replace the prompt being edited.
        packs = store.packs()
    }

    private func loadActiveDraft() {
        guard let pack = activePack else { return }
        let draft = StyleDraft(pack: pack)
        self.draft = draft
        savedDraft = draft
    }
}
