import Foundation

struct LearningCandidate: Codable, Identifiable, Equatable {
    let id: UUID
    let key: String
    var original: String
    var replacement: String
    var language: RecognitionLanguage
    var bundleIdentifier: String?
    var occurrenceCount: Int
    var createdAt: Date
    var lastObservedAt: Date

    init(
        id: UUID = UUID(),
        original: String,
        replacement: String,
        language: RecognitionLanguage,
        bundleIdentifier: String?,
        occurrenceCount: Int = 1,
        createdAt: Date = Date(),
        lastObservedAt: Date = Date()
    ) {
        self.id = id
        self.key = Self.makeKey(
            original: original,
            replacement: replacement,
            language: language,
            bundleIdentifier: bundleIdentifier
        )
        self.original = original
        self.replacement = replacement
        self.language = language
        self.bundleIdentifier = bundleIdentifier
        self.occurrenceCount = occurrenceCount
        self.createdAt = createdAt
        self.lastObservedAt = lastObservedAt
    }

    static func makeKey(
        original: String,
        replacement: String,
        language: RecognitionLanguage,
        bundleIdentifier: String?
    ) -> String {
        [
            language.rawValue,
            bundleIdentifier ?? "",
            original.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            replacement.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        ].joined(separator: "|")
    }
}

final class LearningCandidateStore: @unchecked Sendable {
    static let shared = LearningCandidateStore()

    private let queue = DispatchQueue(label: "com.aetherallan.ElegantWhisper.learning-candidates")
    private let fileURL: URL
    private var cachedItems: [LearningCandidate] = []
    private var loaded = false
    private var loadFailed = false

    init(fileURL: URL = AppConstants.applicationSupportDirectory.appendingPathComponent("learning-candidates.json")) {
        self.fileURL = fileURL
    }

    func items() -> [LearningCandidate] {
        queue.sync {
            loadIfNeeded()
            return cachedItems
        }
    }

    @discardableResult
    func record(
        original rawOriginal: String,
        replacement rawReplacement: String,
        language: RecognitionLanguage,
        bundleIdentifier: String?
    ) -> LearningCandidate? {
        let original = rawOriginal.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = rawReplacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty, !replacement.isEmpty else {
            return nil
        }

        return queue.sync {
            loadIfNeeded()
            let key = LearningCandidate.makeKey(
                original: original,
                replacement: replacement,
                language: language,
                bundleIdentifier: bundleIdentifier
            )
            let now = Date()
            if let index = cachedItems.firstIndex(where: { $0.key == key }) {
                cachedItems[index].occurrenceCount += 1
                cachedItems[index].lastObservedAt = now
                save()
                return cachedItems[index]
            }

            let item = LearningCandidate(
                original: original,
                replacement: replacement,
                language: language,
                bundleIdentifier: bundleIdentifier,
                createdAt: now,
                lastObservedAt: now
            )
            cachedItems.insert(item, at: 0)
            cachedItems = Array(cachedItems.prefix(200))
            save()
            return item
        }
    }

    func remove(id: UUID) {
        queue.sync {
            loadIfNeeded()
            cachedItems.removeAll { $0.id == id }
            save()
        }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL) else {
            cachedItems = []
            return
        }
        if let file = try? JSONDecoder().decode(LearningCandidateFile.self, from: data) {
            cachedItems = file.items
            return
        }
        loadFailed = true
        cachedItems = []
        DebugLog.event("learningCandidateLoadFailed")
    }

    private func save() {
        do {
            if loadFailed {
                try quarantineUnreadableFile()
                loadFailed = false
            }
            try AppConstants.writePrivateJSON(LearningCandidateFile(version: 1, items: cachedItems), to: fileURL)
        } catch {
            DebugLog.event("learningCandidateSaveFailed")
        }
    }

    private func quarantineUnreadableFile() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }
        let formatter = ISO8601DateFormatter()
        let quarantine = AppConstants.applicationSupportDirectory
            .appendingPathComponent("learning-candidates.corrupt.\(formatter.string(from: Date())).json")
        try FileManager.default.moveItem(at: fileURL, to: quarantine)
    }
}

private struct LearningCandidateFile: Codable {
    let version: Int
    let items: [LearningCandidate]
}
