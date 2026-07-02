import AppKit

final class PermissionOnboardingWindowController: NSWindowController {
    var onComplete: (() -> Void)?

    private let permissions = PermissionManager()
    private var timer: Timer?

    private let microphoneStatus = NSTextField(labelWithString: "")
    private let speechStatus = NSTextField(labelWithString: "")
    private let accessibilityStatus = NSTextField(labelWithString: "")
    private let inputMonitoringStatus = NSTextField(labelWithString: "")
    private let continueButton = NSButton(title: "Continue", target: nil, action: nil)
    private var completed = false

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 390),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(AppConstants.productName) Permissions"
        window.setContentSize(NSSize(width: 620, height: 480))
        super.init(window: window)
        buildUI()
        refresh()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        startPolling()
    }

    override func close() {
        stopPolling()
        super.close()
    }

    func refresh() {
        let status = permissions.status()
        update(microphoneStatus, granted: status.microphoneGranted, detail: status.microphoneDetail)
        update(speechStatus, granted: status.speechGranted, detail: status.speechDetail)
        update(accessibilityStatus, granted: status.accessibilityGranted, detail: status.accessibilityDetail)
        update(inputMonitoringStatus, granted: status.inputMonitoringGranted, detail: status.inputMonitoringGranted ? "OK" : status.inputMonitoringDiagnostics)
        continueButton.isEnabled = status.missingTitles.isEmpty
        if window?.isVisible == true, status.missingTitles.isEmpty {
            complete()
        }
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let title = NSTextField(labelWithString: "Set up \(AppConstants.productName)")
        title.font = .systemFont(ofSize: 26, weight: .bold)

        let subtitle = NSTextField(labelWithString: "Grant these permissions one by one. Background Command/Option hotkeys require Input Monitoring.")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor

        let rows = NSStackView(views: [
            row(title: "Microphone", reason: "Record your voice for dictation.", status: microphoneStatus, actionTitle: "Allow", action: #selector(requestMicrophone)),
            row(title: "Speech Recognition", reason: "Run local Apple SpeechAnalyzer transcription.", status: speechStatus, actionTitle: "Allow", action: #selector(requestSpeech)),
            row(title: "Accessibility", reason: "Find the focused field and paste text safely.", status: accessibilityStatus, actionTitle: "Open Settings", action: #selector(requestAccessibility)),
            row(title: "Input Monitoring", reason: "Listen for Command/Option while ElegantWhisper is in the background.", status: inputMonitoringStatus, actionTitle: "Allow", action: #selector(requestInputMonitoring))
        ])
        rows.orientation = .vertical
        rows.spacing = 12

        continueButton.target = self
        continueButton.action = #selector(continueToApp)
        continueButton.keyEquivalent = "\r"

        let stack = NSStackView(views: [title, subtitle, rows, continueButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 34),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -34),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 34)
        ])
    }

    private func row(title: String, reason: String, status: NSTextField, actionTitle: String, action: Selector) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)

        let reasonLabel = NSTextField(labelWithString: reason)
        reasonLabel.font = .systemFont(ofSize: 12)
        reasonLabel.textColor = .secondaryLabelColor

        status.font = .systemFont(ofSize: 12, weight: .semibold)

        let labels = NSStackView(views: [titleLabel, reasonLabel, status])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 4

        let button = NSButton(title: actionTitle, target: self, action: action)

        let row = NSStackView(views: [labels, button])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 18
        row.distribution = .gravityAreas

        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 10
        box.fillColor = .textBackgroundColor
        box.borderColor = .separatorColor
        box.translatesAutoresizingMaskIntoConstraints = false
        row.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(row)

        NSLayoutConstraint.activate([
            box.heightAnchor.constraint(equalToConstant: 78),
            box.widthAnchor.constraint(equalToConstant: 552),
            row.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 18),
            row.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -18),
            row.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 120)
        ])
        return box
    }

    private func update(_ label: NSTextField, granted: Bool, detail: String) {
        label.stringValue = granted ? "OK" : detail
        label.textColor = granted ? .systemGreen : .systemOrange
    }

    private func startPolling() {
        stopPolling()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    @objc private func requestMicrophone() {
        let status = permissions.status()
        if status.microphoneDetail == "Not requested" {
            permissions.requestMicrophone { [weak self] _ in self?.refresh() }
        } else {
            permissions.openMicrophoneSettings()
        }
    }

    @objc private func requestSpeech() {
        let status = permissions.status()
        if status.speechDetail == "Not requested" {
            permissions.requestSpeech { [weak self] _ in self?.refresh() }
        } else {
            permissions.openSpeechSettings()
        }
    }

    @objc private func requestAccessibility() {
        permissions.requestAccessibilityPrompt()
        permissions.openAccessibilitySettings()
        refresh()
    }

    @objc private func requestInputMonitoring() {
        permissions.requestInputMonitoring()
        permissions.openInputMonitoringSettings()
        refresh()
    }

    @objc private func continueToApp() {
        refresh()
        guard permissions.status().missingTitles.isEmpty else {
            return
        }
        complete()
    }

    private func complete() {
        guard !completed else {
            return
        }
        completed = true
        stopPolling()
        close()
        onComplete?()
    }
}
