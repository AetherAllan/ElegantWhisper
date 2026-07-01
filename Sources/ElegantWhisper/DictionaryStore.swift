import Foundation

struct DictionaryEntry: Codable, Identifiable, Equatable {
    let id: UUID
    var term: String
    var aliases: [String]
    var language: RecognitionLanguage

    init(
        id: UUID = UUID(),
        term: String,
        aliases: [String],
        language: RecognitionLanguage
    ) {
        self.id = id
        self.term = term
        self.aliases = aliases
        self.language = language
    }
}

final class DictionaryStore {
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
                entry.term.lowercased().contains(needle) ||
                    entry.aliases.contains { $0.lowercased().contains(needle) }
            }
        }
    }

    func entries(for language: RecognitionLanguage) -> [DictionaryEntry] {
        queue.sync {
            loadIfNeeded()
            return cachedEntries.filter { $0.language == language }
        }
    }

    func contextualStrings(for language: RecognitionLanguage, limit: Int = 80) -> [String] {
        queue.sync {
            loadIfNeeded()
            // Apple Speech contextualStrings are recognition hints, so feed the desired spelling
            // only. Aliases are common wrong outputs such as "配森"; biasing the recognizer toward
            // those aliases would make the exact mistake more likely instead of less likely.
            return cachedEntries
                .filter { $0.language == language }
                .prefix(limit)
                .map(\.term)
        }
    }

    @discardableResult
    func add(term rawTerm: String, aliases rawAliases: [String], language: RecognitionLanguage) -> Bool {
        let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else {
            return false
        }
        let aliases = normalizedAliases(rawAliases, excluding: term)
        return queue.sync {
            loadIfNeeded()
            if let index = cachedEntries.firstIndex(where: { $0.language == language && $0.term.caseInsensitiveCompare(term) == .orderedSame }) {
                cachedEntries[index].aliases = Array(Set(cachedEntries[index].aliases + aliases)).sorted()
            } else {
                cachedEntries.insert(DictionaryEntry(term: term, aliases: aliases, language: language), at: 0)
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
        if let entries = try? decoder.decode([DictionaryEntry].self, from: data) {
            cachedEntries = entries
            return
        }
        if let legacy = try? decoder.decode(LegacyDictionaryFile.self, from: data) {
            cachedEntries = legacy.entries
            return
        }
        loadFailed = true
        cachedEntries = []
        DebugLog.event("dictionaryLoadFailed")
    }

    private func save() {
        do {
            try AppConstants.ensureApplicationDirectories()
            if loadFailed {
                try quarantineUnreadableDictionary()
                loadFailed = false
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(cachedEntries)
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
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

    private func normalizedAliases(_ aliases: [String], excluding term: String) -> [String] {
        let trimmed = aliases
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.caseInsensitiveCompare(term) != .orderedSame }
        return Array(Set(trimmed)).sorted()
    }
}

private struct LegacyDictionaryFile: Codable {
    let version: Int
    let entries: [DictionaryEntry]
}
