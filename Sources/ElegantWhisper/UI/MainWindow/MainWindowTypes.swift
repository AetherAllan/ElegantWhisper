import AppKit

enum MainPage: CaseIterable {
    case overview
    case history
    case dictionary
    case polishing
    case settings

    var title: String {
        switch self {
        case .overview: "Overview"
        case .history: "History"
        case .dictionary: "Dictionary"
        case .polishing: "Polishing"
        case .settings: "Settings"
        }
    }

    var symbolName: String {
        switch self {
        case .overview: "house"
        case .history: "clock.arrow.circlepath"
        case .dictionary: "text.book.closed"
        case .polishing: "sparkles"
        case .settings: "gearshape"
        }
    }
}

struct DashboardMetrics {
    let historyCount: Int
    let characterCount: Int
    let dictionaryCount: Int
    let recentItems: [HistoryItem]

    init(history: HistoryStore, dictionary: DictionaryStore) {
        // Overview must not show demo placeholders. These values are cheap snapshots from the
        // existing local stores, so the page stays truthful on both fresh and real installs.
        let items = history.items()
        historyCount = items.count
        characterCount = items.reduce(0) { $0 + $1.text.count }
        dictionaryCount = dictionary.entries().count
        recentItems = Array(items.prefix(4))
    }
}

struct PermissionSummary {
    let status: PermissionStatus

    var allGranted: Bool {
        status.missingTitles.isEmpty
    }
}

@MainActor
final class SidebarButton: NSButton {
    let page: MainPage

    init(page: MainPage) {
        self.page = page
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        nil
    }
}

@MainActor
final class HistoryTextButton: NSButton {
    var historyText = ""
}

@MainActor
final class DictionaryActionButton: NSButton {
    var entryID: UUID?
}
