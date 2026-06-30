import AppKit

final class SettingsWindowController: NSWindowController {
    private let settings: SettingsStore
    private let refiner: LLMRefiner
    private let permissions = PermissionManager()
    private let history = HistoryStore.shared

    private let baseURLField = NSTextField()
    private let apiKeyField = NSSecureTextField()
    private let modelField = NSTextField()
    private let timeoutField = NSTextField()
    private let clipboardCheckbox = NSButton(checkboxWithTitle: "Keep text on clipboard when no editable field is available", target: nil, action: nil)
    private let historyCheckbox = NSButton(checkboxWithTitle: "Save transcription history", target: nil, action: nil)
    private let historyList = NSStackView()
    private let statusLabel = NSTextField(labelWithString: "")

    init(settings: SettingsStore, refiner: LLMRefiner) {
        self.settings = settings
        self.refiner = refiner
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = AppConstants.productName
        super.init(window: window)
        buildUI()
        loadValues()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func showWindow(_ sender: Any?) {
        loadValues()
        reloadHistory()
        super.showWindow(sender)
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildUI() {
        guard let content = window?.contentView else {
            return
        }
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let grid = NSGridView(views: [
            [label("API Base URL"), baseURLField],
            [label("API Key"), apiKeyField],
            [label("Model"), modelField],
            [label("Timeout Seconds"), timeoutField],
            [NSView(), clipboardCheckbox],
            [NSView(), historyCheckbox]
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 12
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 340

        let testButton = NSButton(title: "Test Connection", target: self, action: #selector(testConnection))
        let saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.keyEquivalent = "\r"

        let buttons = NSStackView(views: [testButton, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let sidebar = makeSidebar()
        let hero = NSTextField(labelWithString: "Natural speech, elegant text - anywhere")
        hero.font = .systemFont(ofSize: 26, weight: .bold)
        hero.textColor = .labelColor

        let shortcut = NSTextField(labelWithString: "Tap Command or Option to start and stop dictation. Press Esc to cancel.")
        shortcut.font = .systemFont(ofSize: 14)
        shortcut.textColor = .secondaryLabelColor

        let permissionCards = makePermissionCards()
        let settingsTitle = NSTextField(labelWithString: "Settings")
        settingsTitle.font = .systemFont(ofSize: 17, weight: .semibold)
        let historyTitle = NSTextField(labelWithString: "History")
        historyTitle.font = .systemFont(ofSize: 17, weight: .semibold)

        historyList.orientation = .vertical
        historyList.alignment = .leading
        historyList.spacing = 8
        historyList.translatesAutoresizingMaskIntoConstraints = false

        let historyScroll = NSScrollView()
        historyScroll.documentView = historyList
        historyScroll.hasVerticalScroller = true
        historyScroll.borderType = .lineBorder
        historyScroll.translatesAutoresizingMaskIntoConstraints = false

        let clearButton = NSButton(title: "Clear History", target: self, action: #selector(clearHistory))

        let main = NSStackView(views: [hero, shortcut, permissionCards, settingsTitle, grid, buttons, statusLabel, historyTitle, historyScroll, clearButton])
        main.orientation = .vertical
        main.alignment = .leading
        main.spacing = 14
        main.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(sidebar)
        content.addSubview(main)

        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: content.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 176),
            main.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 34),
            main.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -34),
            main.topAnchor.constraint(equalTo: content.topAnchor, constant: 38),
            grid.widthAnchor.constraint(equalToConstant: 560),
            buttons.trailingAnchor.constraint(equalTo: grid.trailingAnchor),
            statusLabel.widthAnchor.constraint(equalToConstant: 400),
            historyScroll.widthAnchor.constraint(equalToConstant: 620),
            historyScroll.heightAnchor.constraint(equalToConstant: 150)
        ])
    }

    private func loadValues() {
        baseURLField.stringValue = settings.apiBaseURL
        apiKeyField.stringValue = settings.apiKey
        modelField.stringValue = settings.model
        timeoutField.stringValue = String(Int(settings.requestTimeout))
        clipboardCheckbox.state = settings.keepClipboardWithoutTarget ? .on : .off
        historyCheckbox.state = settings.saveHistory ? .on : .off
        statusLabel.stringValue = ""
    }

    @objc private func save() {
        settings.apiBaseURL = baseURLField.stringValue
        settings.apiKey = apiKeyField.stringValue
        settings.model = modelField.stringValue
        settings.requestTimeout = TimeInterval(timeoutField.doubleValue)
        settings.keepClipboardWithoutTarget = clipboardCheckbox.state == .on
        settings.saveHistory = historyCheckbox.state == .on
        statusLabel.stringValue = "Saved"
    }

    @objc private func testConnection() {
        save()
        statusLabel.stringValue = "Testing..."
        refiner.testConnection { [weak self] ok, message in
            self?.statusLabel.stringValue = ok ? "Connection OK" : message
        }
    }

    private func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.alignment = .right
        return label
    }

    private func makeSidebar() -> NSView {
        let sidebar = NSView()
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.wantsLayer = true
        sidebar.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        let title = NSTextField(labelWithString: AppConstants.productName)
        title.font = .systemFont(ofSize: 17, weight: .bold)

        let plan = NSTextField(labelWithString: "Local")
        plan.font = .systemFont(ofSize: 11, weight: .semibold)
        plan.textColor = .secondaryLabelColor

        let home = sideLabel("Home")
        let settings = sideLabel("Settings")
        let permissions = sideLabel("Permissions")
        let history = sideLabel("History")

        let stack = NSStackView(views: [title, plan, home, settings, permissions, history])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 22),
            stack.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 32)
        ])
        return sidebar
    }

    private func sideLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func makePermissionCards() -> NSView {
        let status = permissions.status()
        let cards = NSStackView(views: [
            card("Microphone", status.microphoneGranted),
            card("Speech", status.speechGranted),
            card("Accessibility", status.accessibilityGranted)
        ])
        cards.orientation = .horizontal
        cards.spacing = 12
        cards.translatesAutoresizingMaskIntoConstraints = false
        return cards
    }

    private func card(_ title: String, _ ok: Bool) -> NSView {
        let label = NSTextField(labelWithString: "\(ok ? "OK" : "Missing")  \(title)")
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = ok ? .systemGreen : .systemOrange
        label.alignment = .center

        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 8
        box.fillColor = .textBackgroundColor
        box.borderColor = .separatorColor
        box.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)

        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: 150),
            box.heightAnchor.constraint(equalToConstant: 54),
            label.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: box.centerYAnchor)
        ])
        return box
    }

    private func reloadHistory() {
        historyList.arrangedSubviews.forEach { view in
            historyList.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let items = history.items()
        if items.isEmpty {
            let empty = NSTextField(labelWithString: "No completed dictations yet.")
            empty.textColor = .secondaryLabelColor
            historyList.addArrangedSubview(empty)
            return
        }

        for item in items.prefix(20) {
            historyList.addArrangedSubview(historyRow(item))
        }
    }

    private func historyRow(_ item: HistoryItem) -> NSView {
        let date = item.createdAt.formatted(date: .abbreviated, time: .shortened)
        let app = item.appName ?? "Unknown app"
        let text = item.text.replacingOccurrences(of: "\n", with: " ")
        let label = NSTextField(labelWithString: "\(date)  \(app)  \(item.result.rawValue): \(text)")
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.widthAnchor.constraint(equalToConstant: 500).isActive = true

        let copy = HistoryCopyButton(title: "Copy", target: self, action: #selector(copyHistory(_:)))
        copy.historyText = item.text

        let row = NSStackView(views: [label, copy])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    @objc private func copyHistory(_ sender: HistoryCopyButton) {
        let text = sender.historyText
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusLabel.stringValue = "Copied history item"
    }

    @objc private func clearHistory() {
        history.clear()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.reloadHistory()
        }
    }
}

private final class HistoryCopyButton: NSButton {
    var historyText = ""
}
