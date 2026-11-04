import SwiftUI

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingClear = false
    @State private var query = ""

    private var filteredItems: [HistoryItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return model.history.items }
        return model.history.items.filter {
            $0.text.localizedCaseInsensitiveContains(needle)
                || ($0.appName?.localizedCaseInsensitiveContains(needle) ?? false)
        }
    }

    var body: some View {
        let sections = HistoryDaySection.group(filteredItems)

        Group {
            if model.history.items.isEmpty {
                ContentUnavailableView(
                    "No dictations yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Completed dictations appear here. Canceled recordings are not saved.")
                )
            } else if sections.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.items) { item in
                                HistoryEntryRow(
                                    item: item,
                                    copy: { model.copyHistory(item) },
                                    copyOriginal: { model.copyHistoryOriginal(item) },
                                    useAsTerm: { model.useHistoryAsDictionaryTerm(item) }
                                )
                            }
                        } header: {
                            Text(section.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("History")
        .searchable(text: $query, placement: .toolbar, prompt: "Search dictations")
        .toolbar {
            Button("Clear History", systemImage: "trash") { confirmingClear = true }
                .disabled(model.history.items.isEmpty)
        }
        .confirmationDialog("Clear all transcription history?", isPresented: $confirmingClear) {
            Button("Clear History", role: .destructive) { model.clearHistory() }
        } message: {
            Text("Lifetime stats on Home are kept.")
        }
    }
}

struct HistoryDaySection: Identifiable {
    let day: Date
    let items: [HistoryItem]
    var id: Date { day }

    var title: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        let sameYear = calendar.isDate(day, equalTo: Date(), toGranularity: .year)
        return day.formatted(sameYear ? .dateTime.weekday(.wide).month(.wide).day() : .dateTime.year().month(.wide).day())
    }

    /// Items arrive newest first; keep that order within and across days.
    static func group(_ items: [HistoryItem], calendar: Calendar = .current) -> [HistoryDaySection] {
        var sections: [HistoryDaySection] = []
        var currentDay: Date?
        var bucket: [HistoryItem] = []
        for item in items {
            let day = calendar.startOfDay(for: item.createdAt)
            if day != currentDay, let currentDay {
                sections.append(HistoryDaySection(day: currentDay, items: bucket))
                bucket = []
            }
            currentDay = day
            bucket.append(item)
        }
        if let currentDay {
            sections.append(HistoryDaySection(day: currentDay, items: bucket))
        }
        return sections
    }
}

struct HistoryEntryRow: View {
    let item: HistoryItem
    var lineLimit = 3
    var copy: (() -> Void)?
    var copyOriginal: (() -> Void)?
    var useAsTerm: (() -> Void)?
    @State private var hovering = false
    @State private var showingOriginal = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AppIconView(bundleIdentifier: item.bundleIdentifier)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.appName ?? "Unknown app").fontWeight(.semibold)
                    Text(item.createdAt, format: .dateTime.hour().minute())
                    if item.originalText != nil {
                        // Rewritten by Dictate or a Style Pack; the recognized text is one click away.
                        Button(showingOriginal ? "Hide original" : "Cleaned up") { showingOriginal.toggle() }
                            .buttonStyle(.plain)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.purple)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.purple.opacity(0.12), in: Capsule())
                            .help("Show the text as it was recognized")
                    }
                    if let badge = item.result.badge {
                        Text(badge.title)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(badge.tint)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(badge.tint.opacity(0.12), in: Capsule())
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Text(item.text)
                    .lineLimit(lineLimit)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if showingOriginal, let original = item.originalText {
                    Text(original)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(.leading, 8)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(Color.secondary.opacity(0.3)).frame(width: 2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            // Keep the actions in the layout so rows do not shift when the pointer enters.
            HStack(spacing: 2) {
                if let copy {
                    Button("Copy", systemImage: "doc.on.doc", action: copy)
                }
                if let useAsTerm {
                    Button("Add to Dictionary", systemImage: "text.book.closed", action: useAsTerm)
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .opacity(hovering ? 1 : 0)
            .animation(.easeOut(duration: 0.12), value: hovering)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            if let copy {
                Button("Copy", systemImage: "doc.on.doc", action: copy)
            }
            if item.originalText != nil, let copyOriginal {
                Button("Copy as Recognized", systemImage: "waveform", action: copyOriginal)
            }
            if let useAsTerm {
                Button("Add to Dictionary…", systemImage: "text.book.closed", action: useAsTerm)
            }
        }
    }
}

private extension HistoryResult {
    /// Inserted text is the normal case and gets no badge; only the exceptions are called out.
    var badge: (title: String, tint: Color)? {
        switch self {
        case .pasted, .pasteAttempted: nil
        case .copied: ("Copied", .blue)
        case .failed: ("Not inserted", .orange)
        }
    }
}
