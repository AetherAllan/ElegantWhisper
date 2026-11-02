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
    /// Recording length. Optional so history written before this field still decodes.
    var duration: TimeInterval? = nil
}

/// Lifetime totals for the Home dashboard. Unlike history this keeps no text, so it is kept even
/// when history saving is off, and it is not capped at the last 200 dictations.
struct UsageStats: Codable, Equatable {
    /// Typing baseline for "time saved". A typical typing speed, not a measured one.
    static let typingWordsPerMinute: Double = 40

    var dictations = 0
    var words = 0
    var speakingSeconds: TimeInterval = 0

    var wordsPerMinute: Int? {
        guard speakingSeconds >= 5, words > 0 else { return nil }
        return Int((Double(words) / (speakingSeconds / 60)).rounded())
    }

    var minutesSaved: Double {
        max(0, Double(words) / Self.typingWordsPerMinute - speakingSeconds / 60)
    }

    mutating func record(text: String, duration: TimeInterval?) {
        dictations += 1
        words += Self.wordCount(text)
        speakingSeconds += duration ?? 0
    }

    /// Counts each CJK character as a word and each run of letters or digits as one word, so the
    /// numbers stay comparable between English and Chinese, Japanese, or Korean dictation.
    static func wordCount(_ text: String) -> Int {
        var count = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            if isCJK(scalar) {
                count += 1
                inWord = false
            } else if CharacterSet.alphanumerics.contains(scalar) {
                if !inWord {
                    count += 1
                    inWord = true
                }
            } else if inWord, scalar == "'" || scalar == "\u{2019}" {
                continue
            } else {
                inWord = false
            }
        }
        return count
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF:
            true
        default:
            false
        }
    }
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

    func append(text: String, result: HistoryResult, app: NSRunningApplication?, duration: TimeInterval? = nil) {
        let item = HistoryItem(
            id: UUID(),
            createdAt: Date(),
            appName: app?.localizedName,
            bundleIdentifier: app?.bundleIdentifier,
            text: text,
            result: result,
            duration: duration
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
