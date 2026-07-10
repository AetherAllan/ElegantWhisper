import Observation
import SwiftUI

@MainActor
@Observable
final class FloatingHUDModel {
    var text = "Listening..."
    var level: CGFloat = 0
    var showsWaveform = true

    func showRecording(text: String) {
        showsWaveform = true
        level = 0
        self.text = text.isEmpty ? "Listening..." : Self.shortPreview(text)
    }

    func updatePartial(_ text: String) {
        self.text = text.isEmpty ? "Listening..." : Self.shortPreview(text)
    }

    func showStatus(_ text: String) {
        showsWaveform = false
        level = 0
        self.text = text
    }

    static func shortPreview(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 16 else { return trimmed }
        return String(trimmed.suffix(16))
    }
}

struct FloatingHUDView: View {
    @Bindable var model: FloatingHUDModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            if model.showsWaveform {
                WaveformCanvas(level: model.level)
                    .frame(width: 34, height: 22)
                    .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
            }
            Text(model.text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .contentTransition(.opacity)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(.separator.opacity(0.6), lineWidth: 0.5))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: model.showsWaveform)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: model.text)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.text)
    }
}

private struct WaveformCanvas: View {
    let level: CGFloat
    private let weights: [CGFloat] = [0.5, 0.8, 1, 0.75, 0.55]

    var body: some View {
        Canvas { context, size in
            let barWidth: CGFloat = 3
            let gap: CGFloat = 3
            let totalWidth = CGFloat(weights.count) * barWidth + CGFloat(weights.count - 1) * gap
            let startX = (size.width - totalWidth) / 2

            for (index, weight) in weights.enumerated() {
                let normalized = max(0.08, min(1, level * weight))
                let height = 5 + normalized * 17
                let rect = CGRect(
                    x: startX + CGFloat(index) * (barWidth + gap),
                    y: (size.height - height) / 2,
                    width: barWidth,
                    height: height
                )
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .foreground)
            }
        }
        .foregroundStyle(.primary)
        .accessibilityHidden(true)
    }
}
