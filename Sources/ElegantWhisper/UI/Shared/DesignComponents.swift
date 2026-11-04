import AppKit
import SwiftUI

// Small building blocks shared by Home, History, Settings, and the sidebar so the main window
// reads as one design: rounded cards, keycaps for shortcuts, tinted stat tiles, app icons.

/// Optional look for the main window and the floating bar.
enum AppTheme: String, CaseIterable, Codable, Identifiable, Sendable {
    case standard
    /// Black, with white light split into a spectrum by a prism.
    case prism

    var id: Self { self }

    var title: String {
        switch self {
        case .standard: "Standard"
        case .prism: "Prism"
        }
    }

    // The color system has three layers, the same in both themes:
    // page (one color behind every view), surface (cards and grouped rows), and the stroke.
    // Native Forms and Lists have their own backdrops turned off (AppShellView), so nothing paints
    // a fourth gray.

    /// The single color every main-window page sits on, and the toolbar above it.
    var pageBackground: Color {
        switch self {
        case .standard: Color(nsColor: .windowBackgroundColor)
        case .prism: PrismPalette.background
        }
    }

    /// Card and row fill. macOS draws grouped Form rows as the page plus this translucent fill
    /// (about 3% white in dark, 3% black in light), so cards drawn with it match native settings
    /// rows exactly on any page color.
    static let surface = Color(nsColor: .quaternarySystemFill)
}

extension EnvironmentValues {
    @Entry var appTheme: AppTheme = .standard
}

/// Colors for the Prism theme: near-black surfaces and the six spectrum bands, red to violet.
enum PrismPalette {
    static let background = Color(red: 0.02, green: 0.02, blue: 0.03)
    static let spectrum: [Color] = [
        Color(red: 1.00, green: 0.23, blue: 0.24),
        Color(red: 1.00, green: 0.58, blue: 0.10),
        Color(red: 1.00, green: 0.86, blue: 0.16),
        Color(red: 0.26, green: 0.84, blue: 0.40),
        Color(red: 0.16, green: 0.55, blue: 1.00),
        Color(red: 0.60, green: 0.36, blue: 1.00),
    ]
    static let accent = Color(red: 0.62, green: 0.56, blue: 1.00)

    static var gradient: LinearGradient {
        LinearGradient(colors: spectrum, startPoint: .leading, endPoint: .trailing)
    }

    /// Spectrum color at `position` in 0...1, red to violet.
    static func color(at position: Double) -> Color {
        let clamped = min(max(position, 0), 1)
        let index = Int((clamped * Double(spectrum.count - 1)).rounded())
        return spectrum[index]
    }
}

private struct CardBackground: ViewModifier {
    @Environment(\.appTheme) private var theme
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if theme == .prism {
            content
                .background(shape.fill(AppTheme.surface))
                .overlay(
                    // A faint spectrum edge, like light catching the rim of glass.
                    shape.strokeBorder(
                        LinearGradient(
                            colors: PrismPalette.spectrum.map { $0.opacity(0.35) } + [Color.white.opacity(0.06)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.75
                    )
                )
        } else {
            content
                .background(shape.fill(AppTheme.surface))
                .overlay(shape.strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5))
        }
    }
}

extension View {
    /// Raised rounded surface used for dashboard cards.
    func cardBackground(cornerRadius: CGFloat = 14) -> some View {
        modifier(CardBackground(cornerRadius: cornerRadius))
    }
}

/// White light entering a glass prism and leaving as a spectrum, drawn in code for the Prism
/// theme's banner. An original illustration of the physics, not a copy of any artwork.
struct PrismArtwork: View {
    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height

            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(PrismPalette.background))
            // A faint glow behind the glass.
            context.fill(
                Path(ellipseIn: CGRect(x: w * 0.42, y: h * 0.05, width: h * 1.1, height: h * 0.95)),
                with: .radialGradient(
                    Gradient(colors: [Color.white.opacity(0.07), .clear]),
                    center: CGPoint(x: w * 0.42 + h * 0.55, y: h * 0.52),
                    startRadius: 0,
                    endRadius: h * 0.55
                )
            )

            let side = h * 0.82
            let center = CGPoint(x: w * 0.62, y: h * 0.56)
            let top = CGPoint(x: center.x, y: center.y - side * 0.577)
            let left = CGPoint(x: center.x - side / 2, y: center.y + side * 0.289)
            let right = CGPoint(x: center.x + side / 2, y: center.y + side * 0.289)
            func point(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
                CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            }
            let entry = point(left, top, 0.42)
            let exit = point(right, top, 0.5)

            // Spectrum leaving the right face, red bending least (top) and violet most.
            let bands = PrismPalette.spectrum
            let fanTop = h * 0.30
            let fanBottom = h * 0.92
            var glow = context
            glow.addFilter(.blur(radius: 7))
            for (index, color) in bands.enumerated() {
                let t0 = CGFloat(index) / CGFloat(bands.count)
                let t1 = CGFloat(index + 1) / CGFloat(bands.count)
                let spread: CGFloat = 0.07
                var band = Path()
                band.move(to: point(exit, right, t0 * spread))
                band.addLine(to: CGPoint(x: w, y: fanTop + (fanBottom - fanTop) * t0))
                band.addLine(to: CGPoint(x: w, y: fanTop + (fanBottom - fanTop) * t1))
                band.addLine(to: point(exit, right, t1 * spread))
                band.closeSubpath()
                glow.fill(band, with: .color(color.opacity(0.55)))
                context.fill(band, with: .color(color.opacity(0.92)))
            }

            // The beam inside the glass, faintly.
            var inside = Path()
            inside.move(to: entry)
            inside.addLine(to: exit)
            inside.addLine(to: point(exit, right, 0.07))
            inside.closeSubpath()
            context.fill(inside, with: .color(.white.opacity(0.18)))

            // Incoming white light.
            var beam = Path()
            beam.move(to: CGPoint(x: 0, y: h * 0.86))
            beam.addLine(to: entry)
            glow.stroke(beam, with: .color(.white.opacity(0.8)), lineWidth: 5)
            context.stroke(beam, with: .color(.white), lineWidth: 1.6)

            // The prism.
            var prism = Path()
            prism.move(to: top)
            prism.addLine(to: right)
            prism.addLine(to: left)
            prism.closeSubpath()
            context.fill(
                prism,
                with: .linearGradient(
                    Gradient(colors: [Color.white.opacity(0.10), Color.white.opacity(0.02)]),
                    startPoint: top,
                    endPoint: CGPoint(x: center.x, y: left.y)
                )
            )
            context.stroke(prism, with: .color(.white.opacity(0.85)), lineWidth: 1.4)
        }
        .accessibilityHidden(true)
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
            .lineLimit(1)
            .fixedSize()
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
