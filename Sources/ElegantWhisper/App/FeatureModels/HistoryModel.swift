import AppKit
import Observation

@MainActor
@Observable
final class HistoryModel {
    private let store: HistoryStore
    private(set) var items: [HistoryItem] = []

    init(store: HistoryStore) {
        self.store = store
        reload()
    }

    func reload() {
        let latest = store.items()
        // Items are immutable, so matching ids mean nothing changed. Skipping the assignment keeps
        // Home and History from re-rendering on every dictation state change.
        guard latest.map(\.id) != items.map(\.id) else {
            return
        }
        items = latest
    }

    func clear() {
        store.clear()
        // HistoryStore intentionally writes on its private queue. Refresh after that queued write
        // instead of pretending clear() is synchronous and briefly republishing stale rows.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            self?.reload()
        }
    }

    func copy(_ item: HistoryItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.text, forType: .string)
    }
}
