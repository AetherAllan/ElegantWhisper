import Charts
import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let insights = HistoryInsights(items: model.history.items)

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if !model.permissionStatus.missingTitles.isEmpty {
                    PermissionSetupBanner(missing: model.permissionStatus.missingTitles) {
                        model.openPermissionSettings()
                    }
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 14)], spacing: 14) {
                    StatTile(
                        symbol: "text.word.spacing",
                        tint: .blue,
                        value: model.usage.words.formatted(),
                        title: "Words dictated",
                        detail: "\(model.usage.dictations.formatted()) dictations"
                    )
                    StatTile(
                        symbol: "hourglass",
                        tint: .green,
                        value: DurationText.minutes(model.usage.minutesSaved),
                        title: "Time saved",
                        detail: "vs. typing at \(Int(UsageStats.typingWordsPerMinute)) wpm"
                    )
                    StatTile(
                        symbol: "speedometer",
                        tint: .orange,
                        value: model.usage.wordsPerMinute.map(String.init) ?? "—",
                        unit: model.usage.wordsPerMinute == nil ? nil : "wpm",
                        title: "Speaking pace",
                        detail: model.usage.wordsPerMinute == nil ? "Measured as you dictate" : "Average across dictations"
                    )
                    StatTile(
                        symbol: "flame",
                        tint: .pink,
                        value: "\(insights.streakDays)",
                        unit: insights.streakDays == 1 ? "day" : "days",
                        title: "Streak",
                        detail: "\(insights.dictationsThisWeek) dictations this week"
                    )
                }

                ActivityCard(days: insights.dailyWords)

                RecentDictationsCard(items: Array(model.history.items.prefix(5))) {
                    model.route = .history
                } copy: { item in
                    model.copyHistory(item)
                }
            }
            .padding(28)
            .frame(maxWidth: 940, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Home")
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 8) {
                Text(Self.greeting())
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                HStack(spacing: 6) {
                    Text("Tap")
                    Keycap("Right ⌥")
                    Text("to dictate into any app,")
                    Keycap("esc")
                    Text("to cancel.")
                }
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            DictationStatusBadge(mode: model.mode)
        }
    }

    private static func greeting(now: Date = Date()) -> String {
        switch Calendar.current.component(.hour, from: now) {
        case 5..<12: "Good morning"
        case 12..<18: "Good afternoon"
        default: "Good evening"
        }
    }
}

/// Derived numbers for Home that come from saved history (dates), not lifetime totals.
struct HistoryInsights {
    struct Day: Identifiable {
        let date: Date
        let words: Int
        var id: Date { date }
    }

    let dailyWords: [Day]
    let streakDays: Int
    let dictationsThisWeek: Int

    init(items: [HistoryItem], now: Date = Date(), calendar: Calendar = .current, days: Int = 14) {
        let today = calendar.startOfDay(for: now)
        var wordsByDay: [Date: Int] = [:]
        var activeDays = Set<Date>()
        var thisWeek = 0
        let weekStart = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        for item in items where item.result != .failed {
            let day = calendar.startOfDay(for: item.createdAt)
            wordsByDay[day, default: 0] += UsageStats.wordCount(item.text)
            activeDays.insert(day)
            if day >= weekStart {
                thisWeek += 1
            }
        }

        dailyWords = (0..<days).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today).map { Day(date: $0, words: wordsByDay[$0] ?? 0) }
        }

        // A streak survives until the end of today, so count back from yesterday if today is empty.
        var cursor = activeDays.contains(today) ? today : calendar.date(byAdding: .day, value: -1, to: today) ?? today
        var streak = 0
        while activeDays.contains(cursor) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        streakDays = streak
        dictationsThisWeek = thisWeek
    }
}

private struct PermissionSetupBanner: View {
    let missing: [String]
    let open: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("Finish setup to dictate in every app").font(.headline)
                Text("Still needed: \(missing.joined(separator: ", "))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Review Permissions", action: open)
                .buttonStyle(.borderedProminent)
                .tint(.orange)
        }
        .padding(16)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 0.5)
        )
    }
}

private struct ActivityCard: View {
    let days: [HistoryInsights.Day]

    private var isEmpty: Bool {
        days.allSatisfy { $0.words == 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Activity").font(.headline)
                Text("Words per day, last \(days.count) days")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Chart(days) { day in
                BarMark(
                    x: .value("Day", day.date, unit: .day),
                    y: .value("Words", day.words)
                )
                .foregroundStyle(Color.accentColor.gradient)
                .cornerRadius(4)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 2)) {
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day(), centered: true)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) {
                    AxisGridLine()
                    AxisValueLabel()
                }
            }
            .frame(height: 150)
            .overlay {
                if isEmpty {
                    Text("Your dictations will show up here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(18)
        .cardBackground()
    }
}

private struct RecentDictationsCard: View {
    let items: [HistoryItem]
    let viewAll: () -> Void
    let copy: (HistoryItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Recent").font(.headline)
                Spacer()
                if !items.isEmpty {
                    Button("View All", action: viewAll)
                        .buttonStyle(.link)
                }
            }
            .padding(.bottom, 4)

            if items.isEmpty {
                ContentUnavailableView(
                    "No dictations yet",
                    systemImage: "waveform",
                    description: Text("Put the cursor in any text field and tap Right Option.")
                )
                .frame(maxWidth: .infinity, minHeight: 140)
            } else {
                ForEach(items) { item in
                    HistoryEntryRow(item: item, lineLimit: 2, copy: { copy(item) })
                    if item.id != items.last?.id {
                        Divider().padding(.leading, 40)
                    }
                }
            }
        }
        .padding(18)
        .cardBackground()
    }
}
