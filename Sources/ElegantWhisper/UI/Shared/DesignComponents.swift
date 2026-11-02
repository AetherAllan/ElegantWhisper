import AppKit
import SwiftUI

// Small building blocks shared by Home, History, Settings, and the sidebar so the main window
// reads as one design: rounded cards, keycaps for shortcuts, tinted stat tiles, app icons.

extension View {
    /// Raised rounded surface used for dashboard cards.
    func cardBackground(cornerRadius: CGFloat = 14) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
        )
    }
}

/// A keyboard key, for shortcut hints such as "Right ⌥" or "esc".
struct Keycap: View {
    let label: String

    init(_ label: String) {
        self.label = label
    }

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.18), radius: 0, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
            .accessibilityLabel(label)
    }
}

struct StatTile: View {
    let symbol: String
    let tint: Color
    let value: String
    var unit: String? = nil
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if let unit {
                    Text(unit)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .cardBackground()
        .accessibilityElement(children: .combine)
    }
}

/// Colored dot plus label for the current dictation state.
struct DictationStatusBadge: View {
    let mode: AppMode

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(mode.tint)
                .frame(width: 8, height: 8)
                .shadow(color: mode.tint.opacity(0.6), radius: mode == .recording ? 4 : 0)
            Text(mode.statusTitle)
                .font(.callout.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(mode.tint.opacity(0.12), in: Capsule())
        .animation(.snappy, value: mode)
    }
}

extension AppMode {
    var statusTitle: String {
        switch self {
        case .idle: "Ready"
        case .preparing: "Starting…"
        case .recording: "Listening"
        case .transcribing: "Transcribing"
        case .refining: "Polishing"
        case .injecting: "Inserting"
        }
    }

    var tint: Color {
        switch self {
        case .idle: .green
        case .preparing, .transcribing, .refining, .injecting: .orange
        case .recording: .red
        }
    }
}

struct AppIconView: View {
    let bundleIdentifier: String?

    var body: some View {
        Image(nsImage: AppIconCache.icon(for: bundleIdentifier))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .accessibilityHidden(true)
    }
}

/// Resolving an app icon touches Launch Services and the disk; cache per bundle id because
/// History can show the same app hundreds of times.
@MainActor
enum AppIconCache {
    private static var icons: [String: NSImage] = [:]

    static func icon(for bundleIdentifier: String?) -> NSImage {
        let key = bundleIdentifier ?? ""
        if let cached = icons[key] {
            return cached
        }
        let icon: NSImage
        if let bundleIdentifier,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        {
            icon = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            icon = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
        }
        icons[key] = icon
        return icon
    }
}

enum DurationText {
    /// "45 min", "2 h 5 min"; under a minute reads "<1 min".
    static func minutes(_ minutes: Double) -> String {
        let total = Int(minutes.rounded())
        if minutes > 0, total == 0 {
            return "<1 min"
        }
        if total < 60 {
            return "\(total) min"
        }
        let hours = total / 60
        let rest = total % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }
}
