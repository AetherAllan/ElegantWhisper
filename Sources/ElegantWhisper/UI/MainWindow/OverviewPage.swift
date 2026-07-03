import AppKit

@MainActor
extension MainWindowController {
    func overviewPage() -> NSStackView {
        let metrics = DashboardMetrics(history: history, dictionary: dictionary)
        let permissions = PermissionSummary(status: controller.permissionStatus())

        let metricRow = MainWindowUI.horizontalRow([
            MainWindowUI.metricCard("State", value: controller.state.mode.title, detail: "Current dictation state"),
            MainWindowUI.metricCard("History", value: "\(metrics.historyCount)", detail: "\(metrics.characterCount) saved chars"),
            MainWindowUI.metricCard("Dictionary", value: "\(metrics.dictionaryCount)", detail: settings.language.menuTitle),
            MainWindowUI.metricCard("Polishing", value: settings.llmEnabled ? "On" : "Off", detail: settings.llmProvider.title)
        ])

        let permissionRow = MainWindowUI.horizontalRow([
            MainWindowUI.metricCard("Microphone", value: permissions.status.microphoneDetail, detail: "Audio capture"),
            MainWindowUI.metricCard("Speech", value: permissions.status.speechDetail, detail: "Apple Speech"),
            MainWindowUI.metricCard("Accessibility", value: permissions.status.accessibilityDetail, detail: "Focus and paste"),
            MainWindowUI.metricCard("Input", value: permissions.status.inputMonitoringDetail, detail: "Global hotkeys")
        ])

        let recentViews: [NSView]
        if metrics.recentItems.isEmpty {
            recentViews = [MainWindowUI.empty("No completed dictations yet.")]
        } else {
            recentViews = metrics.recentItems.map { compactHistoryRow($0, includeActions: false) }
        }

        return MainWindowUI.page(
            title: "Natural speech, elegant text - anywhere",
            subtitle: "ElegantWhisper turns dictation into corrected text and inserts it into the current app.",
            views: [
                metricRow,
                MainWindowUI.card([
                    MainWindowUI.sectionHeader("Permissions", permissions.allGranted ? "Ready" : "Missing \(permissions.status.missingTitles.joined(separator: ", "))"),
                    permissionRow
                ]),
                MainWindowUI.card([
                    MainWindowUI.sectionHeader("Recent Dictations", "Only completed results are shown")
                ] + recentViews)
            ]
        )
    }
}
