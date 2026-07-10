import SwiftUI

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingClear = false

    var body: some View {
        VStack(spacing: 0) {
            if model.history.items.isEmpty {
                ContentUnavailableView("No completed dictations yet", systemImage: "clock.arrow.circlepath")
            } else {
                List(model.history.items.prefix(80)) { item in
                    HistoryRow(
                        item: item,
                        showsActions: true,
                        copy: { model.copyHistory(item) },
                        useAsTerm: { model.useHistoryAsDictionaryTerm(item) }
                    )
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("History")
        .toolbar {
            Button("Clear History", systemImage: "trash") { confirmingClear = true }
                .disabled(model.history.items.isEmpty)
        }
        .confirmationDialog("Clear all transcription history?", isPresented: $confirmingClear) {
            Button("Clear History", role: .destructive) { model.clearHistory() }
        }
    }
}

struct HistoryRow: View {
    let item: HistoryItem
    let showsActions: Bool
    let copy: () -> Void
    let useAsTerm: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(item.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(item.appName ?? "Unknown app") · \(item.result.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(item.text.replacingOccurrences(of: "\n", with: " "))
                    .lineLimit(showsActions ? 2 : 1)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showsActions {
                Button("Copy", action: copy)
                Button("Use as Term", action: useAsTerm)
            }
        }
    }
}

private extension HistoryResult {
    var displayName: String {
        switch self {
        case .pasted, .pasteAttempted: "pasted"
        case .copied: "copied"
        case .failed: "failed"
        }
    }
}
