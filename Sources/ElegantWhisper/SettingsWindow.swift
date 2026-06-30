import AppKit

final class SettingsWindowController: NSWindowController {
    private let settings: SettingsStore
    private let refiner: LLMRefiner

    private let baseURLField = NSTextField()
    private let apiKeyField = NSSecureTextField()
    private let modelField = NSTextField()
    private let timeoutField = NSTextField()
    private let clipboardCheckbox = NSButton(checkboxWithTitle: "Keep text on clipboard when no editable field is available", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")

    init(settings: SettingsStore, refiner: LLMRefiner) {
        self.settings = settings
        self.refiner = refiner
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 280),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(AppConstants.productName) Settings"
        super.init(window: window)
        buildUI()
        loadValues()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func showWindow(_ sender: Any?) {
        loadValues()
        super.showWindow(sender)
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildUI() {
        guard let content = window?.contentView else {
            return
        }

        let grid = NSGridView(views: [
            [label("API Base URL"), baseURLField],
            [label("API Key"), apiKeyField],
            [label("Model"), modelField],
            [label("Timeout Seconds"), timeoutField],
            [NSView(), clipboardCheckbox]
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

        content.addSubview(grid)
        content.addSubview(buttons)
        content.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            buttons.trailingAnchor.constraint(equalTo: grid.trailingAnchor),
            buttons.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 18),
            statusLabel.leadingAnchor.constraint(equalTo: grid.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: buttons.leadingAnchor, constant: -12),
            statusLabel.centerYAnchor.constraint(equalTo: buttons.centerYAnchor)
        ])
    }

    private func loadValues() {
        baseURLField.stringValue = settings.apiBaseURL
        apiKeyField.stringValue = settings.apiKey
        modelField.stringValue = settings.model
        timeoutField.stringValue = String(Int(settings.requestTimeout))
        clipboardCheckbox.state = settings.keepClipboardWithoutTarget ? .on : .off
        statusLabel.stringValue = ""
    }

    @objc private func save() {
        settings.apiBaseURL = baseURLField.stringValue
        settings.apiKey = apiKeyField.stringValue
        settings.model = modelField.stringValue
        settings.requestTimeout = TimeInterval(timeoutField.doubleValue)
        settings.keepClipboardWithoutTarget = clipboardCheckbox.state == .on
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
}
