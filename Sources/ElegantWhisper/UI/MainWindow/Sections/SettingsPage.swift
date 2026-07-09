import AppKit

@MainActor
extension MainWindowController {
    func settingsPage() -> NSStackView {
        languagePopup.target = self
        languagePopup.action = #selector(markGeneralDirty)
        clipboardCheckbox.target = self
        clipboardCheckbox.action = #selector(markGeneralDirty)
        historyCheckbox.target = self
        historyCheckbox.action = #selector(markGeneralDirty)
        muteOutputCheckbox.target = self
        muteOutputCheckbox.action = #selector(markGeneralDirty)
        learningCheckbox.target = self
        learningCheckbox.action = #selector(markGeneralDirty)

        let general = MainWindowUI.form([
            ("Language", languagePopup)
        ])
        let save = MainWindowUI.button("Save Settings", target: self, action: #selector(saveGeneralSettings), primary: true)
        let status = controller.permissionStatus()

        return MainWindowUI.page(
            title: "Settings",
            subtitle: "General behavior and macOS permission shortcuts.",
            views: [
                MainWindowUI.card([
                    MainWindowUI.sectionHeader("General", "Runtime behavior"),
                    general,
                    clipboardCheckbox,
                    historyCheckbox,
                    muteOutputCheckbox,
                    learningCheckbox,
                    save
                ]),
                MainWindowUI.card([
                    MainWindowUI.sectionHeader("Permissions", status.missingTitles.isEmpty ? "Ready" : "Missing \(status.missingTitles.joined(separator: ", "))"),
                    permissionActionRow("Microphone", detail: status.microphoneDetail, granted: status.microphoneGranted, action: #selector(openMicrophoneSettings)),
                    permissionActionRow("Speech Recognition", detail: status.speechDetail, granted: status.speechGranted, action: #selector(openSpeechSettings)),
                    permissionActionRow("Accessibility", detail: status.accessibilityDetail, granted: status.accessibilityGranted, action: #selector(openAccessibilitySettings)),
                    permissionActionRow("Input Monitoring", detail: status.inputMonitoringDiagnostics, granted: status.inputMonitoringGranted, action: #selector(openInputMonitoringSettings))
                ])
            ]
        )
    }

    func permissionActionRow(_ title: String, detail: String, granted: Bool, action: Selector) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .labelColor

        let detailLabel = MainWindowUI.body(detail)
        detailLabel.lineBreakMode = .byTruncatingTail

        let text = NSStackView(views: [titleLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let button = MainWindowUI.button(granted ? "Open" : "Grant", target: self, action: action)
        let row = NSStackView(views: [text, button])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        return row
    }
}
