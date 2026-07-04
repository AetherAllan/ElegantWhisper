import AppKit

@MainActor
extension MainWindowController {
    func overviewPage() -> NSStackView {
        // Overview must stay truthful on fresh installs: derive it from the same local stores the
        // rest of the app uses, not from placeholder/demo state.
        let historyItems = history.items()
        let characterCount = historyItems.reduce(0) { $0 + $1.text.count }
        let dictionaryCount = dictionary.entries().count
        let recentItems = Array(historyItems.prefix(4))
        let permissionStatus = controller.permissionStatus()

        let metricRow = MainWindowUI.horizontalRow([
            MainWindowUI.metricCard("State", value: controller.state.mode.title, detail: "Current dictation state"),
            MainWindowUI.metricCard("History", value: "\(historyItems.count)", detail: "\(characterCount) saved chars"),
            MainWindowUI.metricCard("Dictionary", value: "\(dictionaryCount)", detail: settings.language.menuTitle),
            MainWindowUI.metricCard("Polishing", value: settings.llmEnabled ? "On" : "Off", detail: settings.llmProvider.title)
        ])

        let permissionRow = MainWindowUI.horizontalRow([
            MainWindowUI.metricCard("Microphone", value: permissionStatus.microphoneDetail, detail: "Audio capture"),
            MainWindowUI.metricCard("Speech", value: permissionStatus.speechDetail, detail: "Apple Speech"),
            MainWindowUI.metricCard("Accessibility", value: permissionStatus.accessibilityDetail, detail: "Focus and paste"),
            MainWindowUI.metricCard("Input", value: permissionStatus.inputMonitoringDetail, detail: "Global hotkeys")
        ])

        let recentViews: [NSView]
        if recentItems.isEmpty {
            recentViews = [MainWindowUI.empty("No completed dictations yet.")]
        } else {
            recentViews = recentItems.map { compactHistoryRow($0, includeActions: false) }
        }

        return MainWindowUI.page(
            title: "Natural speech, elegant text - anywhere",
            subtitle: "ElegantWhisper turns dictation into corrected text and inserts it into the current app.",
            views: [
                metricRow,
                MainWindowUI.card([
                    MainWindowUI.sectionHeader("Permissions", permissionStatus.missingTitles.isEmpty ? "Ready" : "Missing \(permissionStatus.missingTitles.joined(separator: ", "))"),
                    permissionRow
                ]),
                MainWindowUI.card([
                    MainWindowUI.sectionHeader("Recent Dictations", "Only completed results are shown")
                ] + recentViews)
            ]
        )
    }
}
