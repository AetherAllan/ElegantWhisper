import AppKit
import Foundation

enum HistoryResult: String, Codable {
    case pasted
    case copied
    case failed
}

struct HistoryItem: Codable, Identifiable {
    let id: UUID
    let createdAt: Date
    let appName: String?
    let bundleIdentifier: String?
    let text: String
    let result: HistoryResult
}

final class HistoryStore {
    static let shared = HistoryStore()

    private let queue = DispatchQueue(label: "com.aetherallan.ElegantWhisper.history")
    private var cachedItems: [HistoryItem] = []
    private var loaded = false

    private var fileURL: URL {
        AppConstants.applicationSupportDirectory.appendingPathComponent("history.json")
    }

    func items() -> [HistoryItem] {
        queue.sync {
            loadIfNeeded()
            return cachedItems
        }
    }

    func append(text: String, result: HistoryResult, app: NSRunningApplication?) {
        let item = HistoryItem(
            id: UUID(),
            createdAt: Date(),
            appName: app?.localizedName,
            bundleIdentifier: app?.bundleIdentifier,
            text: text,
            result: result
        )

        queue.async {
            self.loadIfNeeded()
            self.cachedItems.insert(item, at: 0)
            self.cachedItems = Array(self.cachedItems.prefix(200))
            self.save()
        }
    }

    func clear() {
        queue.async {
            self.cachedItems = []
            self.loaded = true
            self.save()
        }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let items = try? JSONDecoder().decode([HistoryItem].self, from: data)
        else {
            cachedItems = []
            return
        }
        cachedItems = items
    }

    private func save() {
        do {
            try AppConstants.ensureApplicationDirectories()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(cachedItems)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            DebugLog.event("historySaveFailed")
        }
    }
}
