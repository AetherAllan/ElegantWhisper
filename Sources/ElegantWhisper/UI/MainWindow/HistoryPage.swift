import AppKit

@MainActor
extension MainWindowController {
    func historyPage() -> NSStackView {
        let items = history.items()
        let body: [NSView]
        if items.isEmpty {
            body = [MainWindowUI.empty("No completed dictations yet.")]
        } else {
            body = items.prefix(80).map { compactHistoryRow($0, includeActions: true) }
        }

        let clear = MainWindowUI.button("Clear History", target: self, action: #selector(clearHistory))
        return MainWindowUI.page(
            title: "History",
            subtitle: "Local-only completed dictations. Canceled recordings are not saved.",
            views: [MainWindowUI.card(body + [clear])]
        )
    }

    func compactHistoryRow(_ item: HistoryItem, includeActions: Bool) -> NSView {
        let date = item.createdAt.formatted(date: .abbreviated, time: .shortened)
        let app = item.appName ?? "Unknown app"
        let text = item.text.replacingOccurrences(of: "\n", with: " ")

        let title = NSTextField(labelWithString: "\(date) · \(app) · \(displayName(for: item.result))")
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.textColor = .secondaryLabelColor

        let body = NSTextField(labelWithString: text)
        body.font = .systemFont(ofSize: 14)
        body.textColor = .labelColor
        body.lineBreakMode = .byTruncatingTail
        body.maximumNumberOfLines = includeActions ? 2 : 1

        let textStack = NSStackView(views: [title, body])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

        guard includeActions else {
            return textStack
        }

        let copy = HistoryTextButton(title: "Copy", target: self, action: #selector(copyHistory(_:)))
        copy.historyText = item.text
        let useAsTerm = HistoryTextButton(title: "Use as Term", target: self, action: #selector(useHistoryAsDictionaryTerm(_:)))
        useAsTerm.historyText = item.text

        let row = NSStackView(views: [textStack, copy, useAsTerm])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.distribution = .fill
        return row
    }
}
