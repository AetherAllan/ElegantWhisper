import AppKit

@MainActor
final class MainWindowController: NSWindowController, NSTextViewDelegate, NSTextFieldDelegate {
    let controller: AppController
    let settings: SettingsStore
    let refiner: LLMRefiner
    let history = HistoryStore.shared
    let dictionary = DictionaryStore.shared
    let stylePacks = StylePackStore.shared

    let pageContainer = NSView()
    let noticeLabel = NSTextField(labelWithString: "")
    var sidebarButtons: [MainPage: SidebarButton] = [:]
    var currentPage: MainPage = .overview

    let providerPopup = NSPopUpButton()
    let baseURLField = NSTextField()
    let apiKeyField = NSSecureTextField()
    let modelField = NSTextField()
    let timeoutField = NSTextField()
    let stylePackPopup = NSPopUpButton()
    let stylePromptScroll = NSScrollView()
    let stylePromptView = NSTextView()
    let effectivePromptScroll = NSScrollView()
    let effectivePromptView = NSTextView()
    let llmCheckbox = NSButton(checkboxWithTitle: "Enable LLM Polishing", target: nil, action: nil)
    let clipboardCheckbox = NSButton(checkboxWithTitle: "Keep text on clipboard when no editable field is available", target: nil, action: nil)
    let historyCheckbox = NSButton(checkboxWithTitle: "Save transcription history", target: nil, action: nil)
    let languagePopup = NSPopUpButton()
    let dictionaryLanguagePopup = NSPopUpButton()
    let dictionaryTermField = NSTextField()
    let dictionaryAliasesField = NSTextField()
    let dictionarySearchField = NSSearchField()
    var polishingDirty = false
    var generalDirty = false

    init(settings: SettingsStore, refiner: LLMRefiner, controller: AppController) {
        self.settings = settings
        self.refiner = refiner
        self.controller = controller
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = AppConstants.productName
        window.minSize = NSSize(width: 720, height: 560)
        super.init(window: window)
        configurePromptEditors()
        buildUI()
        loadValues()
        renderCurrentPage()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func showWindow(_ sender: Any?) {
        let wasVisible = window?.isVisible == true
        if !wasVisible {
            loadValues()
            renderCurrentPage()
        }
        super.showWindow(sender)
        if !wasVisible {
            window?.center()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func refresh() {
        // Global hotkeys can change state while the user is editing this window. Do not reload
        // persisted settings here: that would erase unsaved API keys or prompt edits. Explicit
        // Save/Reset/window-open paths are the only places that repopulate editable fields.
        guard window?.isVisible == true else {
            return
        }
        if currentPage == .polishing {
            if !polishingDirty {
                syncPolishingControlsFromSettings()
            }
            updateEffectivePromptPreview()
            return
        }
        if currentPage == .settings, !generalDirty {
            syncGeneralControlsFromSettings()
        }
        renderCurrentPage()
    }

    func showNotice(_ message: String) {
        noticeLabel.stringValue = message
        noticeLabel.isHidden = message.isEmpty
    }

    func buildUI() {
        guard let content = window?.contentView else {
            return
        }
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let sidebar = makeSidebar()
        pageContainer.translatesAutoresizingMaskIntoConstraints = false

        noticeLabel.font = .systemFont(ofSize: 13, weight: .medium)
        noticeLabel.textColor = .secondaryLabelColor
        noticeLabel.isHidden = true
        noticeLabel.translatesAutoresizingMaskIntoConstraints = false

        let right = NSStackView(views: [noticeLabel, pageContainer])
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 10
        right.translatesAutoresizingMaskIntoConstraints = false
        pageContainer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pageContainer.setContentHuggingPriority(.defaultLow, for: .vertical)

        content.addSubview(sidebar)
        content.addSubview(right)

        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: content.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: MainWindowUI.sidebarWidth),

            right.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 28),
            right.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -28),
            right.topAnchor.constraint(equalTo: content.topAnchor, constant: 26),
            right.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -26),
            right.widthAnchor.constraint(lessThanOrEqualToConstant: 620),
            noticeLabel.widthAnchor.constraint(equalTo: right.widthAnchor),
            pageContainer.widthAnchor.constraint(equalTo: right.widthAnchor)
        ])
    }

    func makeSidebar() -> NSView {
        let sidebar = NSView()
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.wantsLayer = true
        sidebar.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        let title = NSTextField(labelWithString: AppConstants.productName)
        title.font = .systemFont(ofSize: 19, weight: .bold)
        title.textColor = .labelColor

        let header = NSStackView(views: [title, MainWindowUI.pill("Apple Speech")])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8

        let buttons = MainPage.allCases.map { page in
            let button = SidebarButton(page: page)
            button.title = page.title
            button.image = NSImage(systemSymbolName: page.symbolName, accessibilityDescription: page.title)
            button.imagePosition = .imageLeading
            button.alignment = .left
            button.isBordered = false
            button.target = self
            button.action = #selector(selectPage(_:))
            button.setAccessibilityLabel(page.title)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.heightAnchor.constraint(equalToConstant: 34).isActive = true
            sidebarButtons[page] = button
            return button
        }

        let hint = MainWindowUI.body("Tap Right Option to dictate. Press Esc to cancel.")
        hint.maximumNumberOfLines = 0
        hint.lineBreakMode = .byWordWrapping

        let spacer = NSView()
        let buttonViews: [NSView] = buttons
        let stack = NSStackView(views: [header] + buttonViews + [spacer, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 30),
            stack.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -24),
            hint.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        updateSidebarSelection()
        return sidebar
    }

    func loadValues() {
        populateProviderPopup()
        populateStylePackPopup()
        syncPolishingControlsFromSettings()
        syncGeneralControlsFromSettings()
        loadSelectedStylePackPrompt()
        polishingDirty = false
        generalDirty = false
    }

    func syncPolishingControlsFromSettings() {
        baseURLField.stringValue = settings.apiBaseURL
        apiKeyField.stringValue = settings.apiKey
        modelField.stringValue = settings.model
        timeoutField.stringValue = String(Int(settings.requestTimeout))
        llmCheckbox.state = settings.llmEnabled ? .on : .off
    }

    func syncGeneralControlsFromSettings() {
        clipboardCheckbox.state = settings.keepClipboardWithoutTarget ? .on : .off
        historyCheckbox.state = settings.saveHistory ? .on : .off
        populateLanguagePopup(languagePopup, selected: settings.language)
        populateLanguagePopup(dictionaryLanguagePopup, selected: settings.language)
    }

    func populateProviderPopup() {
        providerPopup.removeAllItems()
        for provider in LLMProvider.allCases {
            providerPopup.addItem(withTitle: provider.title)
            providerPopup.lastItem?.representedObject = provider.rawValue
        }
        if let index = LLMProvider.allCases.firstIndex(of: settings.llmProvider) {
            providerPopup.selectItem(at: index)
        }
    }

    func populateLanguagePopup(_ popup: NSPopUpButton, selected: RecognitionLanguage) {
        popup.removeAllItems()
        for language in RecognitionLanguage.allCases {
            popup.addItem(withTitle: language.menuTitle)
            popup.lastItem?.representedObject = language.rawValue
        }
        if let index = RecognitionLanguage.allCases.firstIndex(of: selected) {
            popup.selectItem(at: index)
        }
    }

    func populateStylePackPopup() {
        stylePackPopup.removeAllItems()
        let packs = stylePacks.packs()
        for pack in packs {
            stylePackPopup.addItem(withTitle: pack.name)
            stylePackPopup.lastItem?.representedObject = pack.id
        }
        if let index = packs.firstIndex(where: { $0.active }) {
            stylePackPopup.selectItem(at: index)
        }
    }

    func loadSelectedStylePackPrompt() {
        guard let pack = selectedStylePack() else {
            return
        }
        stylePromptView.string = pack.systemPrompt
        updateEffectivePromptPreview()
    }

    @objc func selectPage(_ sender: SidebarButton) {
        currentPage = sender.page
        updateSidebarSelection()
        renderCurrentPage()
    }

    func updateSidebarSelection() {
        for (page, button) in sidebarButtons {
            let selected = page == currentPage
            button.wantsLayer = true
            button.layer?.cornerRadius = 8
            button.layer?.backgroundColor = selected
                ? NSColor.textBackgroundColor.cgColor
                : NSColor.clear.cgColor
            button.contentTintColor = selected ? .labelColor : .secondaryLabelColor
            button.font = .systemFont(ofSize: 14, weight: selected ? .semibold : .medium)
        }
    }

    func renderCurrentPage() {
        pageContainer.subviews.forEach { $0.removeFromSuperview() }
        let content: NSStackView
        switch currentPage {
        case .overview:
            content = overviewPage()
        case .history:
            content = historyPage()
        case .dictionary:
            content = dictionaryPage()
        case .polishing:
            content = polishingPage()
        case .settings:
            content = settingsPage()
        }

        let scroll = MainWindowUI.scrollView(for: content)
        pageContainer.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: pageContainer.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: pageContainer.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: pageContainer.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: pageContainer.bottomAnchor)
        ])
        DispatchQueue.main.async {
            // Each page render creates a new scroll view. Keep navigation predictable by showing
            // the page header first instead of inheriting a previous page's middle/bottom position.
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    func selectedProvider() -> LLMProvider {
        guard let raw = providerPopup.selectedItem?.representedObject as? String,
              let provider = LLMProvider(rawValue: raw)
        else {
            return settings.llmProvider
        }
        return provider
    }

    func selectedLanguage(in popup: NSPopUpButton) -> RecognitionLanguage {
        guard let raw = popup.selectedItem?.representedObject as? String,
              let language = RecognitionLanguage(rawValue: raw)
        else {
            return settings.language
        }
        return language
    }

    func selectedStylePack() -> StylePack? {
        let selectedID = stylePackPopup.selectedItem?.representedObject as? String
        let packs = stylePacks.packs()
        return packs.first { $0.id == selectedID } ?? packs.first { $0.active }
    }

    func updateEffectivePromptPreview() {
        effectivePromptView.string = LLMPromptBuilder.systemPrompt(
            template: stylePromptView.string,
            hotwords: dictionary.contextualStrings(for: settings.language)
        )
    }

    func displayName(for result: HistoryResult) -> String {
        switch result {
        case .pasted, .pasteAttempted:
            "pasted"
        case .copied:
            "copied"
        case .failed:
            "failed"
        }
    }

    private func configurePromptEditors() {
        configurePromptScroll(stylePromptScroll, textView: stylePromptView, editable: true, height: 160)
        configurePromptScroll(effectivePromptScroll, textView: effectivePromptView, editable: false, height: 130)
    }

    private func configurePromptScroll(_ scroll: NSScrollView, textView: NSTextView, editable: Bool, height: CGFloat) {
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true

        textView.isEditable = editable
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.frame = NSRect(x: 0, y: 0, width: 520, height: height)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        if editable {
            textView.delegate = self
        }
        scroll.documentView = textView
    }

    func textDidChange(_ notification: Notification) {
        guard notification.object as AnyObject? === stylePromptView else {
            return
        }
        updateEffectivePromptPreview()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else {
            return
        }
        if field === baseURLField || field === apiKeyField || field === modelField || field === timeoutField {
            polishingDirty = true
        }
    }
}
