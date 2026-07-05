import AppKit

@MainActor
extension MainWindowController {
    func dictionaryPage() -> NSStackView {
        dictionaryTermField.placeholderString = "Python"
        dictionarySearchField.placeholderString = "Search dictionary"
        dictionarySearchField.target = self
        dictionarySearchField.action = #selector(reloadVisiblePage)

        let form = MainWindowUI.form([
            ("Term", dictionaryTermField),
            ("Language", dictionaryLanguagePopup),
            ("Search", dictionarySearchField)
        ])
        let add = MainWindowUI.button("Add Term", target: self, action: #selector(addDictionaryTerm), primary: true)

        let query = dictionarySearchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let activePack = stylePacks.activePack()
        let packTerms = StylePackStore.seedTerms(for: activePack.id)
        let seedTerms = query.isEmpty ? packTerms : packTerms.filter { $0.localizedCaseInsensitiveContains(query) }
        let entries = dictionary.entries(matching: query)
        let suggestions = LearningCandidateStore.shared.items()
        let seedRows: [NSView]
        if seedTerms.isEmpty {
            seedRows = [MainWindowUI.empty("No style pack terms match this search.")]
        } else {
            seedRows = seedTerms.prefix(100).map { seedTermRow($0, packName: activePack.name) }
        }
        let rows: [NSView]
        if entries.isEmpty {
            rows = [MainWindowUI.empty("No personal dictionary terms yet.")]
        } else {
            rows = entries.prefix(100).map(dictionaryRow)
        }

        return MainWindowUI.page(
            title: "Dictionary",
            subtitle: "Terms bias Apple Speech recognition only. Polishing does not receive your dictionary.",
            views: [
                MainWindowUI.card([
                    MainWindowUI.sectionHeader("Add Term", "Save the correct spelling or phrase you want recognized"),
                    form,
                    add
                ]),
                MainWindowUI.card([
                    MainWindowUI.sectionHeader("Suggestions", "\(suggestions.count) pending")
                ] + suggestionRows(suggestions)),
                MainWindowUI.card([
                    MainWindowUI.sectionHeader("Style pack terms", "\(activePack.name) · \(seedTerms.count) active")
                ] + seedRows),
                MainWindowUI.card([
                    MainWindowUI.sectionHeader("Your terms", "\(entries.count) saved")
                ] + rows)
            ]
        )
    }

    func seedTermRow(_ termValue: String, packName: String) -> NSView {
        let term = NSTextField(labelWithString: termValue)
        term.font = .systemFont(ofSize: 14, weight: .semibold)
        term.textColor = .labelColor

        let detail = MainWindowUI.body("From \(packName)")
        detail.lineBreakMode = .byTruncatingTail

        let text = NSStackView(views: [term, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        return text
    }

    func dictionaryRow(_ entry: DictionaryEntry) -> NSView {
        let term = NSTextField(labelWithString: entry.term)
        term.font = .systemFont(ofSize: 14, weight: .semibold)
        term.textColor = .labelColor

        let detail = MainWindowUI.body(entry.language.menuTitle)
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
            let title = NSTextField(labelWithString: "Add “\(candidate.replacement)”")
            title.font = .systemFont(ofSize: 14, weight: .semibold)
            title.textColor = .labelColor

            let app = candidate.bundleIdentifier ?? "all apps"
            let detail = MainWindowUI.body("Edited from “\(candidate.original)” · \(candidate.language.menuTitle) · \(app) · \(candidate.occurrenceCount)x")
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
