import AppKit
import Foundation

@MainActor
final class FloatingPanel {
    private let panel: NSPanel
    private let rootView = NSView()
    private let container = NSVisualEffectView()
    private let stack = NSStackView()
    private let waveform = WaveformView()
    private let label = NSTextField(labelWithString: "Listening...")
    private var widthConstraint: NSLayoutConstraint?
    private var labelWidthConstraint: NSLayoutConstraint?
    private var presentationID = UUID()
    private var pendingHide: DispatchWorkItem?

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 176, height: 36),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true

        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.clear.cgColor

        container.material = .popover
        container.blendingMode = .withinWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.88).cgColor
        container.layer?.cornerRadius = 18
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        container.translatesAutoresizingMaskIntoConstraints = false

        waveform.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingMiddle
        label.textColor = NSColor.white.withAlphaComponent(0.82)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(waveform)
        stack.addArrangedSubview(label)

        container.addSubview(stack)
        rootView.addSubview(container)
        panel.contentView = rootView

        widthConstraint = panel.contentView?.widthAnchor.constraint(equalToConstant: 176)
        labelWidthConstraint = label.widthAnchor.constraint(equalToConstant: 92)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            container.topAnchor.constraint(equalTo: rootView.topAnchor),
            container.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            container.heightAnchor.constraint(equalToConstant: 36),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            waveform.widthAnchor.constraint(equalToConstant: 34),
            waveform.heightAnchor.constraint(equalToConstant: 22),
            labelWidthConstraint!,
            widthConstraint!
        ])
    }

    func showRecording(text: String) {
        beginPresentation()
        waveform.isHidden = false
        waveform.level = 0
        waveform.needsDisplay = true
        setText(text.isEmpty ? "Listening..." : shortPreview(text), animated: false)
        show()
    }

    func retryShowIfNeeded() {
        let expectedID = presentationID
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.presentationID == expectedID,
                  (!self.panel.isVisible || self.panel.alphaValue < 0.9)
            else {
                return
            }
            // macOS occasionally accepts orderFrontRegardless before the panel has a stable
            // screen/frame during app activation changes. isVisible alone is not enough: an old
            // fade-out can leave the panel visible but transparent. Retry once; repeated retries
            // would hide the real permission/window-level problem instead of fixing it.
            DebugLog.event("panelShowRetry")
            self.show()
        }
    }

    func updatePartial(_ text: String) {
        // Keep recording width bounded. Partial text is only a rolling tail preview; letting the
        // full transcript resize this panel makes the text appear to push outside the capsule.
        setText(text.isEmpty ? "Listening..." : shortPreview(text), animated: false)
    }

    func updateLevel(_ level: Float) {
        waveform.level = CGFloat(level)
    }

    func showStatus(_ text: String) {
        beginPresentation()
        waveform.isHidden = true
        setText(text)
        show()
    }

    func showSuccess(_ text: String = "Inserted") {
        beginPresentation()
        waveform.isHidden = true
        setText(text)
        show()
        scheduleHide(after: 0.55, presentationID: presentationID)
    }

    func showError(_ text: String) {
        beginPresentation()
        waveform.isHidden = true
        setText(text)
        show()
        scheduleHide(after: 1.2, presentationID: presentationID)
    }

    func hide() {
        pendingHide?.cancel()
        pendingHide = nil
        hide(presentationID: presentationID)
    }

    private func beginPresentation() {
        pendingHide?.cancel()
        pendingHide = nil
        presentationID = UUID()
        // A new dictation can start while the previous success/error fade-out is still running.
        // In that window NSPanel may report isVisible == true while the old animation keeps its
        // alpha near 0, so every presentation must reset the visual state before show() decides
        // whether it needs to bring the panel forward again.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            panel.alphaValue = 1
        }
    }

    private func scheduleHide(after delay: TimeInterval, presentationID: UUID) {
        let workItem = DispatchWorkItem { [weak self] in
            self?.hide(presentationID: presentationID)
        }
        pendingHide = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func hide(presentationID expectedID: UUID) {
        guard presentationID == expectedID else {
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.22
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard self?.presentationID == expectedID else {
                    return
                }
                self?.panel.orderOut(nil)
                self?.panel.alphaValue = 1
            }
        }
    }

    private func show() {
        position()
        let wasVisible = panel.isVisible
        if !wasVisible {
            panel.alphaValue = 0
        }
        // Always front and restore alpha, even when AppKit says the panel is already visible.
        // An interrupted hide animation can otherwise leave a visible window fully transparent.
        panel.orderFrontRegardless()
        DebugLog.event("panelShowState:visible=\(wasVisible):alpha=\(panel.alphaValue)")
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || (wasVisible && panel.alphaValue >= 0.99) ? 0 : 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func setText(_ text: String, animated: Bool = true) {
        label.stringValue = text
        updateWidthForCurrentText()
        guard animated else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                panel.contentView?.layoutSubtreeIfNeeded()
            }
            position()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
            panel.contentView?.layoutSubtreeIfNeeded()
            position()
        }
    }

    private func shortPreview(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 8 else {
            return trimmed
        }
        // Show the newest recognition tail, not the first few characters forever. Keeping the
        // preview to eight visible characters prevents long partials from pushing the capsule
        // around while still making the text feel live as speech recognition updates.
        return String(trimmed.suffix(8))
    }

    private func updateWidthForCurrentText() {
        let fittingWidth = ceil(label.intrinsicContentSize.width)
        let labelWidth = min(132, max(72, fittingWidth))
        labelWidthConstraint?.constant = labelWidth

        let horizontalPadding: CGFloat = 26
        let waveformSpace: CGFloat = waveform.isHidden ? 0 : 42
        widthConstraint?.constant = min(220, max(150, horizontalPadding + waveformSpace + labelWidth))
    }

    private func position() {
        guard let screen = NSScreen.main else {
            return
        }
        let frame = panel.frame
        let visible = screen.visibleFrame
        let x = visible.midX - frame.width / 2
        let y = visible.minY + 48
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

}

@MainActor
private final class WaveformView: NSView {
    var level: CGFloat = 0 {
        didSet {
            needsDisplay = true
        }
    }

    private let weights: [CGFloat] = [0.5, 0.8, 1.0, 0.75, 0.55]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.92).setFill()
        let barWidth: CGFloat = 3
        let gap: CGFloat = 3
        let totalWidth = CGFloat(weights.count) * barWidth + CGFloat(weights.count - 1) * gap
        let startX = bounds.midX - totalWidth / 2

        for (index, weight) in weights.enumerated() {
            let normalized = max(0.08, min(1, level * weight))
            let height = 5 + normalized * 19
            let x = startX + CGFloat(index) * (barWidth + gap)
            let rect = NSRect(x: x, y: bounds.midY - height / 2, width: barWidth, height: height)
            NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
    }
}
