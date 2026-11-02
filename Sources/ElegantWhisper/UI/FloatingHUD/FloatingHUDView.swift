import Observation
import SwiftUI

enum FloatingHUDPhase: Equatable {
    case listening
    case working
    case success
    case failure
}

@MainActor
@Observable
final class FloatingHUDModel {
    static let previewLimit = 48
    static let waveformHistoryCount = 4

    var text = "Listening..."
    var phase: FloatingHUDPhase = .listening
    private(set) var listeningSince: Date?
    // Newest level first. The waveform mirrors this history outward from the center bar so the
    // bars ripple with speech instead of all scaling in unison.
    private(set) var levels = [CGFloat](repeating: 0, count: waveformHistoryCount)

    var showsWaveform: Bool {
        phase == .listening
    }

    func showRecording(text: String) {
        phase = .listening
        listeningSince = Date()
        resetLevels()
        self.text = text.isEmpty ? "Listening..." : Self.shortPreview(text)
    }

    func updatePartial(_ text: String) {
        self.text = text.isEmpty ? "Listening..." : Self.shortPreview(text)
    }

    func updateLevel(_ level: CGFloat) {
        levels.removeLast()
        levels.insert(level, at: 0)
    }

    /// Keep the last partial visible while finalization runs.
    func stopListening() {
        phase = .working
        listeningSince = nil
        resetLevels()
    }

    func showStatus(_ text: String, phase: FloatingHUDPhase = .working) {
        self.phase = phase
        listeningSince = nil
        resetLevels()
        self.text = text
    }

    static func shortPreview(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > previewLimit else { return trimmed }
        return String(trimmed.suffix(previewLimit))
    }

    private func resetLevels() {
        levels = [CGFloat](repeating: 0, count: Self.waveformHistoryCount)
    }
}

struct FloatingHUDView: View {
    @Bindable var model: FloatingHUDModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            FloatingHUDGlyph(phase: model.phase, levels: model.levels)
                .frame(width: 30, height: 22)
            Text(model.text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(model.phase == .working ? .secondary : .primary)
                .lineLimit(1)
                // Live partials grow at the end, so drop the oldest words first.
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
            if model.phase == .listening, let since = model.listeningSince {
                // Text(timerInterval:) ticks on its own; no timer or model updates needed.
                Text(timerInterval: since...since.addingTimeInterval(3_600), countsDown: false)
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .transition(.opacity)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
        // Animate phase changes only. Partials stream several times per second and fading each
        // one makes the preview flicker.
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: model.phase)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.text)
    }
}

private struct FloatingHUDGlyph: View {
    let phase: FloatingHUDPhase
    let levels: [CGFloat]

    var body: some View {
        ZStack {
            switch phase {
            case .listening:
                WaveformCanvas(levels: levels)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            case .working:
                ProgressView()
                    .controlSize(.small)
                    .transition(.opacity)
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.green)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            case .failure:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.orange)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .accessibilityHidden(true)
    }
}

private struct WaveformCanvas: View {
    let levels: [CGFloat]

    var body: some View {
        Canvas { context, size in
            // Mirror history around the center: [h3, h2, h1, h0, h1, h2, h3].
            let history = levels.isEmpty ? [0] : levels
            let bars = Array(history.reversed()) + history.dropFirst()
            let barWidth: CGFloat = 2.5
            let gap: CGFloat = 2
            let totalWidth = CGFloat(bars.count) * barWidth + CGFloat(bars.count - 1) * gap
            let startX = (size.width - totalWidth) / 2
            let center = CGFloat(bars.count - 1) / 2

            for (index, level) in bars.enumerated() {
                // Outer bars taper slightly so the shape reads as a voice pulse.
                let taper = 1 - abs(CGFloat(index) - center) / (center + 1) * 0.45
                let normalized = max(0.12, min(1, level * taper))
                let height = 4 + normalized * (size.height - 4)
                let rect = CGRect(
                    x: startX + CGFloat(index) * (barWidth + gap),
                    y: (size.height - height) / 2,
                    width: barWidth,
                    height: height
                )
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .foreground)
            }
        }
        .foregroundStyle(.tint)
    }
}
