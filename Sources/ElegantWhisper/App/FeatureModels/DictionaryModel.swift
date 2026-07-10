import Foundation
import Observation

@MainActor
@Observable
final class DictionaryModel {
    private let dictionary: DictionaryStore
    private let candidatesStore: LearningCandidateStore
    private let styles: StylePackStore

    private(set) var entries: [DictionaryEntry] = []
    private(set) var candidates: [LearningCandidate] = []
    var term = ""
    var search = ""
    var language: RecognitionLanguage

    init(
        dictionary: DictionaryStore,
        candidates: LearningCandidateStore,
        styles: StylePackStore,
        language: RecognitionLanguage
    ) {
        self.dictionary = dictionary
        candidatesStore = candidates
        self.styles = styles
        self.language = language
        reload()
    }

    var filteredEntries: [DictionaryEntry] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return entries }
        return entries.filter { $0.term.localizedCaseInsensitiveContains(needle) }
    }

    var activeStyleName: String {
        styles.activePack().name
    }

    var filteredSeedTerms: [String] {
        let terms = StylePackStore.seedTerms(for: styles.activePack().id)
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return terms }
        return terms.filter { $0.localizedCaseInsensitiveContains(needle) }
    }

    @discardableResult
    func addTerm() -> Bool {
        guard dictionary.add(term: term, language: language) else { return false }
        term = ""
        reload()
        return true
    }

    func deleteTerm(id: UUID) {
        dictionary.delete(id: id)
        reload()
    }

    func accept(_ candidate: LearningCandidate) {
        _ = dictionary.add(term: candidate.replacement, language: candidate.language)
        candidatesStore.remove(id: candidate.id)
        reload()
    }

    func dismiss(_ candidate: LearningCandidate) {
        candidatesStore.remove(id: candidate.id)
        reload()
    }

    func prepareTerm(_ value: String) {
        term = value
    }

    func reload() {
        entries = dictionary.entries()
        // One-off edits are usually typing cleanup, not durable vocabulary. Keep them persisted so
        // a repeated correction can merge into the same item, but do not interrupt the user yet.
        candidates = candidatesStore.items().filter { $0.occurrenceCount >= 2 }
    }
}
