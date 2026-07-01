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

final class HistoryStore {
    static let shared = HistoryStore()

    private let queue = DispatchQueue(label: "com.aetherallan.ElegantWhisper.history")
    private var cachedItems: [HistoryItem] = []
    private var loaded = false
    private var loadFailed = false

    private var fileURL: URL {
        AppConstants.applicationSupportDirectory.appendingPathComponent("history.json")
    }

    private var backupURL: URL {
        AppConstants.applicationSupportDirectory.appendingPathComponent("history.json.bak")
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
            try AppConstants.ensureApplicationDirectories()
            if loadFailed {
                try quarantineUnreadableHistory()
                loadFailed = false
            } else if FileManager.default.fileExists(atPath: fileURL.path) {
                try? FileManager.default.removeItem(at: backupURL)
                try FileManager.default.copyItem(at: fileURL, to: backupURL)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(HistoryFile(version: 1, items: cachedItems))
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
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
