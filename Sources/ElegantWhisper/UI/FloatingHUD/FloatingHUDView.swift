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
    /// One level per distance from the center dot: the 11-dot waveform mirrors these outward.
    static let waveformHistoryCount = 6
    /// The center dot follows the voice every display frame; older samples step outward every
    /// few frames (20 steps a second at 60 fps) so the ripple stays readable.
    static let rippleInterval = 3
    /// About half a second of audio. Bounds latency if frames stall, e.g. while the screen sleeps.
    static let maxQueuedLevels = 30
    static let barCount = 2 * waveformHistoryCount - 1
    /// Display frames between new per-bar wobble targets (about 0.1 s at 60 fps).
    static let wobbleInterval = 6

    var text = "Listening..."
    var phase: FloatingHUDPhase = .listening
    // Newest level first. The waveform mirrors this history outward from the center bar so the
    // bars ripple with speech instead of all scaling in unison. `levels` is what is drawn; it
    // eases toward `targets` every frame so bars glide between audio buffers.
    private(set) var levels = [CGFloat](repeating: 0, count: waveformHistoryCount)
    private var targets = [CGFloat](repeating: 0, count: waveformHistoryCount)
    private var queuedLevels: [CGFloat] = []
    private var frame = 0
    /// What the waveform draws, one value per dot. Level history by distance from the center,
    /// shaped by a soft bell and a per-bar wobble so the outline changes with speech instead of
    /// staying one symmetric bump. All zero (dots) in silence.
    private(set) var bars = [CGFloat](repeating: 0, count: barCount)
    private var wobble = [CGFloat](repeating: 1, count: barCount)
    private var wobbleTargets = [CGFloat](repeating: 1, count: barCount)
    private var randomState: UInt64 = 0x9E37_79B9_7F4A_7C15

    var showsWaveform: Bool {
        phase == .listening
    }

    func showRecording(text: String) {
        phase = .listening
        resetLevels()
        self.text = text.isEmpty ? "Listening..." : Self.shortPreview(text)
    }

    func updatePartial(_ text: String) {
        self.text = text.isEmpty ? "Listening..." : Self.shortPreview(text)
    }

    func enqueueLevels(_ values: [CGFloat]) {
        queuedLevels.append(contentsOf: values)
        if queuedLevels.count > Self.maxQueuedLevels {
            queuedLevels.removeFirst(queuedLevels.count - Self.maxQueuedLevels)
        }
    }

    /// One display frame: take the next audio level (decay when the queue runs dry) and ease
    /// each bar toward its target.
    func advanceFrame() {
        let live = queuedLevels.isEmpty ? targets[0] * 0.9 : queuedLevels.removeFirst()
        frame += 1
        if frame % Self.rippleInterval == 0 {
            targets.removeLast()
            targets.insert(live, at: 0)
        } else {
            targets[0] = live
        }
        // Build the new arrays first so observers see one change per frame, not one per bar.
        var next = levels
        for index in next.indices {
            let easing: CGFloat = index == 0 ? 0.75 : 0.5
            next[index] += (targets[index] - next[index]) * easing
        }
        levels = next

        if frame % Self.wobbleInterval == 0 {
            for index in wobbleTargets.indices {
                wobbleTargets[index] = 0.5 + 0.5 * nextRandom()
            }
        }
        let center = Self.barCount / 2
        var nextBars = bars
        for index in nextBars.indices {
            wobble[index] += (wobbleTargets[index] - wobble[index]) * 0.3
            let distance = abs(index - center)
            let envelope = exp(-pow(CGFloat(distance) / 4.5, 2))
            nextBars[index] = min(1, levels[distance] * envelope * wobble[index] * 1.3)
        }
        bars = nextBars
    }

    /// xorshift64: cheap and deterministic, which keeps tests repeatable.
    private func nextRandom() -> CGFloat {
        randomState ^= randomState << 13
        randomState ^= randomState >> 7
        randomState ^= randomState << 17
        return CGFloat(randomState % 10_000) / 10_000
    }

    /// Keep the last partial visible while finalization runs.
    func stopListening() {
        phase = .working
        resetLevels()
    }

    func showStatus(_ text: String, phase: FloatingHUDPhase = .working) {
        self.phase = phase
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
        targets = levels
        queuedLevels = []
        frame = 0
        bars = [CGFloat](repeating: 0, count: Self.barCount)
        wobble = [CGFloat](repeating: 1, count: Self.barCount)
        wobbleTargets = wobble
    }
}

/// A compact black capsule: cancel on the left, a dot waveform in the middle, finish on the
/// right. The live transcript is not shown here (text goes straight into the field); the capsule
/// only widens to show a short message such as "Copied to clipboard" or an error.
struct FloatingHUDView: View {
    @Bindable var model: FloatingHUDModel
    var onCancel: () -> Void = {}
    var onConfirm: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let height: CGFloat = 34
    static let buttonSize: CGFloat = 24
    static let inset: CGFloat = 5
    static let waveformWidth: CGFloat = 46
    static let waveformSpacing: CGFloat = 9
    static let compactWidth = inset * 2 + buttonSize * 2 + waveformSpacing * 2 + waveformWidth

    var body: some View {
        ZStack {
            switch model.phase {
            case .listening, .working:
                HStack(spacing: Self.waveformSpacing) {
                    CircleButton(kind: .cancel, action: onCancel)
                    Group {
                        if model.phase == .listening {
                            DotWaveform(bars: model.bars)
                        } else {
                            WorkingDots(animated: !reduceMotion)
                        }
                    }
                    .frame(width: Self.waveformWidth, height: 20)
                    CircleButton(kind: .confirm, action: onConfirm)
                        // Finishing is only meaningful while recording.
                        .disabled(model.phase != .listening)
                        .opacity(model.phase == .listening ? 1 : 0.35)
                }
                .padding(.horizontal, Self.inset)
                .transition(.opacity)
            case .success, .failure:
                HStack(spacing: 8) {
                    Image(systemName: model.phase == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(model.phase == .success ? Color.green : Color.orange)
                    Text(model.text)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.horizontal, 14)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The 1 pt rim is a filled capsule behind an inset one: strokeBorder left a stray
        // vertical hairline at each end of the capsule.
        .background(
            Capsule()
                .fill(Color(white: 0.62).opacity(0.55))
                .overlay(Capsule().fill(Color(white: 0.04)).padding(1))
        )
        // Always dark, like the capsule itself, whatever the system appearance.
        .environment(\.colorScheme, .dark)
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: model.phase)
    }
}

private struct CircleButton: View {
    enum Kind {
        case cancel
        case confirm
    }

    let kind: Kind
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: kind == .cancel ? "xmark" : "checkmark")
                .font(.system(size: kind == .cancel ? 11 : 12, weight: .bold))
                .foregroundStyle(kind == .cancel ? Color.white : Color.black)
                .frame(width: FloatingHUDView.buttonSize, height: FloatingHUDView.buttonSize)
                .background(
                    Circle().fill(kind == .cancel
                        ? Color(white: hovering ? 0.38 : 0.28)
                        : Color(white: hovering ? 0.86 : 1))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(kind == .cancel ? "Cancel dictation" : "Finish dictation")
        .help(kind == .cancel ? "Cancel (esc)" : "Finish and insert (Right ⌥)")
    }
}

/// Dots that rise into bars with the voice. Shaping happens in FloatingHUDModel.bars.
private struct DotWaveform: View {
    let bars: [CGFloat]
    static let dotCount = FloatingHUDModel.barCount

    var body: some View {
        Canvas { context, size in
            let dot: CGFloat = 2.2
            let gap = (size.width - CGFloat(Self.dotCount) * dot) / CGFloat(Self.dotCount - 1)
            for index in 0..<Self.dotCount {
                let level = index < bars.count ? bars[index] : 0
                let height = dot + (size.height - dot) * level
                let rect = CGRect(
                    x: CGFloat(index) * (dot + gap),
                    y: (size.height - height) / 2,
                    width: dot,
                    height: height
                )
                context.fill(Path(roundedRect: rect, cornerRadius: dot / 2), with: .color(.white))
            }
        }
        .accessibilityLabel("Listening")
    }
}

/// While the transcript is finalized: a soft wave travels across the dots.
private struct WorkingDots: View {
    let animated: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !animated)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let count = DotWaveform.dotCount
                let dot: CGFloat = 2.2
                let gap = (size.width - CGFloat(count) * dot) / CGFloat(count - 1)
                for index in 0..<count {
                    let wave = animated ? max(0, sin(time * 5 - Double(index) * 0.55)) : 0
                    let height = dot + 4 * CGFloat(wave)
                    let rect = CGRect(
                        x: CGFloat(index) * (dot + gap),
                        y: (size.height - height) / 2,
                        width: dot,
                        height: height
                    )
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: dot / 2),
                        with: .color(.white.opacity(0.45 + 0.55 * wave))
                    )
                }
            }
        }
        .accessibilityLabel("Transcribing")
    }
}
