import AppKit

@MainActor
extension MainWindowController {
    func dictionaryPage() -> NSStackView {
        dictionaryTermField.placeholderString = "Python"
        dictionaryAliasesField.placeholderString = "配森, 派森"
        dictionarySearchField.placeholderString = "Search dictionary"
        dictionarySearchField.target = self
        dictionarySearchField.action = #selector(reloadVisiblePage)

        let form = MainWindowUI.form([
            ("Term", dictionaryTermField),
            ("Wrong forms", dictionaryAliasesField),
            ("Language", dictionaryLanguagePopup),
            ("Search", dictionarySearchField)
        ])
        let add = MainWindowUI.button("Add Term", target: self, action: #selector(addDictionaryTerm), primary: true)

        let entries = dictionary.entries(matching: dictionarySearchField.stringValue)
        let suggestions = LearningCandidateStore.shared.items()
        let rows: [NSView]
        if entries.isEmpty {
            rows = [MainWindowUI.empty("No dictionary terms yet.")]
        } else {
            rows = entries.prefix(100).map(dictionaryRow)
        }

        return MainWindowUI.page(
            title: "Dictionary",
            subtitle: "Terms are used as Apple Speech hints and as conservative final-text corrections.",
            views: [
                MainWindowUI.card([
                    MainWindowUI.sectionHeader("Add Term", "Use aliases for common wrong recognitions"),
                    form,
                    add
                ]),
                MainWindowUI.card([
                    MainWindowUI.sectionHeader("Suggestions", "\(suggestions.count) pending")
                ] + suggestionRows(suggestions)),
                MainWindowUI.card([
                    MainWindowUI.sectionHeader("Terms", "\(entries.count) saved")
                ] + rows)
            ]
        )
    }

    func dictionaryRow(_ entry: DictionaryEntry) -> NSView {
        let aliases = entry.aliases.isEmpty ? "No wrong forms" : entry.aliases.joined(separator: ", ")
        let term = NSTextField(labelWithString: entry.term)
        term.font = .systemFont(ofSize: 14, weight: .semibold)
        term.textColor = .labelColor

        let detail = MainWindowUI.body("\(aliases) · \(entry.language.menuTitle)")
        detail.lineBreakMode = .byTruncatingTail

        let text = NSStackView(views: [term, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let delete = NSButton(title: "Delete", target: self, action: #selector(deleteDictionaryTerm(_:)))
        delete.identifier = NSUserInterfaceItemIdentifier(entry.id.uuidString)

        let row = NSStackView(views: [text, delete])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        return row
    }

    func suggestionRows(_ suggestions: [LearningCandidate]) -> [NSView] {
        guard !suggestions.isEmpty else {
            return [MainWindowUI.empty("No learning suggestions yet.")]
        }
        return suggestions.prefix(50).map { candidate in
            let title = NSTextField(labelWithString: "\(candidate.original) → \(candidate.replacement)")
            title.font = .systemFont(ofSize: 14, weight: .semibold)
            title.textColor = .labelColor

            let app = candidate.bundleIdentifier ?? "all apps"
            let detail = MainWindowUI.body("\(candidate.language.menuTitle) · \(app) · \(candidate.occurrenceCount)x")
            detail.lineBreakMode = .byTruncatingTail

            let text = NSStackView(views: [title, detail])
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = 3
            text.setContentHuggingPriority(.defaultLow, for: .horizontal)

            let accept = NSButton(title: "Accept", target: self, action: #selector(acceptLearningCandidate(_:)))
            accept.identifier = NSUserInterfaceItemIdentifier(candidate.id.uuidString)
            let dismiss = NSButton(title: "Dismiss", target: self, action: #selector(dismissLearningCandidate(_:)))
            dismiss.identifier = NSUserInterfaceItemIdentifier(candidate.id.uuidString)

            let row = NSStackView(views: [text, accept, dismiss])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 10
            return row
        }
    }
}
