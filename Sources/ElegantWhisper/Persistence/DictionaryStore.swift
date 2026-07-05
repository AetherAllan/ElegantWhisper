import Foundation

struct DictionaryEntry: Codable, Identifiable, Equatable {
    let id: UUID
    var term: String
    var language: RecognitionLanguage

    init(
        id: UUID = UUID(),
        term: String,
        language: RecognitionLanguage
    ) {
        self.id = id
        self.term = term
        self.language = language
    }
}

// Public methods serialize all mutable state through `queue`. Keeping this as a
// synchronous store avoids forcing every settings/history UI call into async code
// just for Swift's shared-singleton check.
final class DictionaryStore: @unchecked Sendable {
    static let shared = DictionaryStore()

    private let queue = DispatchQueue(label: "com.aetherallan.ElegantWhisper.dictionary")
    private let fileURL: URL
    private var cachedEntries: [DictionaryEntry] = []
    private var loaded = false
    private var loadFailed = false

    init(fileURL: URL = AppConstants.applicationSupportDirectory.appendingPathComponent("dictionary.json")) {
        self.fileURL = fileURL
    }

    func entries(matching query: String = "") -> [DictionaryEntry] {
        queue.sync {
            loadIfNeeded()
            let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !needle.isEmpty else {
                return cachedEntries
            }
            return cachedEntries.filter { entry in
                entry.term.lowercased().contains(needle)
            }
        }
    }

    func entries(for language: RecognitionLanguage) -> [DictionaryEntry] {
        queue.sync {
            loadIfNeeded()
            return cachedEntries.filter { $0.language == language }
        }
    }

    func terms(for language: RecognitionLanguage, limit: Int = 80) -> [String] {
        queue.sync {
            loadIfNeeded()
            return cachedEntries
                .filter { $0.language == language }
                .prefix(limit)
                .map(\.term)
        }
    }

    @discardableResult
    func add(term rawTerm: String, language: RecognitionLanguage) -> Bool {
        let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else {
            return false
        }
        return queue.sync {
            loadIfNeeded()
            if let index = cachedEntries.firstIndex(where: { $0.language == language && $0.term.caseInsensitiveCompare(term) == .orderedSame }) {
                cachedEntries[index].term = term
            } else {
                cachedEntries.insert(DictionaryEntry(term: term, language: language), at: 0)
            }
            cachedEntries = Array(cachedEntries.prefix(500))
            save()
            return true
        }
    }

    func delete(id: UUID) {
        queue.sync {
            loadIfNeeded()
            cachedEntries.removeAll { $0.id == id }
            save()
        }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL) else {
            cachedEntries = []
            return
        }
        let decoder = JSONDecoder()
        if let legacyEntries = try? decoder.decode([LegacyDictionaryEntry].self, from: data) {
            cachedEntries = legacyEntries.map(\.entry)
            if legacyEntries.contains(where: { !($0.aliases ?? []).isEmpty }) {
                save()
            }
            return
        }
        if let entries = try? decoder.decode([DictionaryEntry].self, from: data) {
            cachedEntries = entries
            return
        }
        if let legacy = try? decoder.decode(LegacyDictionaryFile.self, from: data) {
            cachedEntries = legacy.entries.map(\.entry)
            save()
            return
        }
        loadFailed = true
        cachedEntries = []
        DebugLog.event("dictionaryLoadFailed")
    }

    private func save() {
        do {
            if loadFailed {
                try quarantineUnreadableDictionary()
                loadFailed = false
            }
            try AppConstants.writePrivateJSON(cachedEntries, to: fileURL)
        } catch {
            DebugLog.event("dictionarySaveFailed")
        }
    }

    private func quarantineUnreadableDictionary() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }
        let formatter = ISO8601DateFormatter()
        let quarantine = AppConstants.applicationSupportDirectory
            .appendingPathComponent("dictionary.corrupt.\(formatter.string(from: Date())).json")
        try FileManager.default.moveItem(at: fileURL, to: quarantine)
    }
}

private struct LegacyDictionaryEntry: Codable {
    let id: UUID
    var term: String
    var aliases: [String]?
    var language: RecognitionLanguage

    var entry: DictionaryEntry {
        DictionaryEntry(id: id, term: term, language: language)
    }
}

private struct LegacyDictionaryFile: Codable {
    let version: Int
    let entries: [LegacyDictionaryEntry]
}
