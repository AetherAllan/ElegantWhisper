import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model

    private var characterCount: Int {
        model.history.items.reduce(0) { $0 + $1.text.count }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Natural speech, elegant text — anywhere").font(.largeTitle.bold())
                    Text("Tap Right Option to dictate. Press Esc to cancel.").foregroundStyle(.secondary)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    MetricCard(title: "State", value: model.mode.title, detail: "Current dictation state")
                    MetricCard(title: "History", value: "\(model.history.items.count)", detail: "\(characterCount) saved chars")
                    MetricCard(title: "Dictionary", value: "\(model.dictionary.entries.count)", detail: model.currentLanguage.menuTitle)
                    MetricCard(title: "Polishing", value: model.llmEnabled ? "On" : "Off", detail: model.llmProvider.title)
                }

                GroupBox("Permissions") {
                    VStack(alignment: .leading, spacing: 10) {
                        PermissionStatusRow(title: "Microphone", detail: model.permissionStatus.microphoneDetail, granted: model.permissionStatus.microphoneGranted)
                        PermissionStatusRow(title: "Speech Recognition", detail: model.permissionStatus.speechDetail, granted: model.permissionStatus.speechGranted)
                        PermissionStatusRow(title: "Accessibility", detail: model.permissionStatus.accessibilityDetail, granted: model.permissionStatus.accessibilityGranted)
                        PermissionStatusRow(title: "Input Monitoring", detail: model.permissionStatus.inputMonitoringDiagnostics, granted: model.permissionStatus.inputMonitoringGranted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                }

                GroupBox("Recent Dictations") {
                    if model.history.items.isEmpty {
                        ContentUnavailableView("No completed dictations yet", systemImage: "waveform")
                            .frame(maxWidth: .infinity, minHeight: 120)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(model.history.items.prefix(4)) { item in
                                HistoryRow(item: item, showsActions: false, copy: {}, useAsTerm: {})
                                if item.id != model.history.items.prefix(4).last?.id {
                                    Divider()
                                }
                            }
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Home")
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.title2.bold())
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
