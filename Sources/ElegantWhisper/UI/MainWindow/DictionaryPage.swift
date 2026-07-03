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
}
