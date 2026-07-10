import AppKit
import Foundation

enum HistoryResult: String, Codable {
    case pasted
    case pasteAttempted
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

// History mutations are serialized on `queue`; readers receive value-type
// snapshots. That is enough for the current app and avoids an actor migration
// that would touch every AppKit view for no behavioral gain.
final class HistoryStore: @unchecked Sendable {
    static let shared = HistoryStore()

    private let queue = DispatchQueue(label: "com.aetherallan.ElegantWhisper.history")
    private let fileURL: URL
    private var cachedItems: [HistoryItem] = []
    private var loaded = false
    private var loadFailed = false

    init(fileURL: URL = AppConstants.applicationSupportDirectory.appendingPathComponent("history.json")) {
        self.fileURL = fileURL
    }

    private var backupURL: URL {
        fileURL.deletingPathExtension().appendingPathExtension("json.bak")
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
        guard let data = try? Data(contentsOf: fileURL) else {
            cachedItems = []
            return
        }
        let decoder = JSONDecoder()
        if let file = try? decoder.decode(HistoryFile.self, from: data) {
            cachedItems = file.items
            return
        }
        if let items = try? decoder.decode([HistoryItem].self, from: data) {
            cachedItems = items
            return
        }
        loadFailed = true
        cachedItems = []
        DebugLog.event("historyLoadFailed")
    }

    private func save() {
        do {
            if loadFailed {
                try quarantineUnreadableHistory()
                loadFailed = false
            } else if FileManager.default.fileExists(atPath: fileURL.path) {
                try? FileManager.default.removeItem(at: backupURL)
                try FileManager.default.copyItem(at: fileURL, to: backupURL)
            }
            try AppConstants.writePrivateJSON(HistoryFile(version: 1, items: cachedItems), to: fileURL)
        } catch {
            DebugLog.event("historySaveFailed")
        }
    }

    private func quarantineUnreadableHistory() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }
        let formatter = ISO8601DateFormatter()
        let quarantine = AppConstants.applicationSupportDirectory
            .appendingPathComponent("history.corrupt.\(formatter.string(from: Date())).json")
        try FileManager.default.moveItem(at: fileURL, to: quarantine)
    }
}

private struct HistoryFile: Codable {
    let version: Int
    let items: [HistoryItem]
}
