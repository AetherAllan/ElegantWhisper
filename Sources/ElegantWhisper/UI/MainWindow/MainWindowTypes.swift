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
