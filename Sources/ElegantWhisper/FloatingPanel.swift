import AppKit
import Foundation

final class FloatingPanel {
    private let panel: NSPanel
    private let rootView = NSView()
    private let container = NSVisualEffectView()
    private let stack = NSStackView()
    private let waveform = WaveformView()
    private let label = NSTextField(labelWithString: "Listening...")
    private var widthConstraint: NSLayoutConstraint?

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 56),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .floating
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

        container.material = .hudWindow
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        container.layer?.cornerRadius = 28
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        container.translatesAutoresizingMaskIntoConstraints = false

        waveform.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingMiddle
        label.textColor = .white
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 18, bottom: 0, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(waveform)
        stack.addArrangedSubview(label)

        container.addSubview(stack)
        rootView.addSubview(container)
        panel.contentView = rootView

        widthConstraint = panel.contentView?.widthAnchor.constraint(equalToConstant: 260)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            container.topAnchor.constraint(equalTo: rootView.topAnchor),
            container.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            container.heightAnchor.constraint(equalToConstant: 56),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            waveform.widthAnchor.constraint(equalToConstant: 44),
            waveform.heightAnchor.constraint(equalToConstant: 32),
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
            widthConstraint!
        ])
    }

    func showRecording(text: String) {
        waveform.isHidden = false
        waveform.level = 0
        setText(text.isEmpty ? "Listening..." : text)
        show()
    }

    func updatePartial(_ text: String) {
        setText(text.isEmpty ? "Listening..." : text)
    }

    func updateLevel(_ level: Float) {
        waveform.level = CGFloat(level)
    }

    func showStatus(_ text: String) {
        waveform.isHidden = true
        setText(text)
        show()
    }

    func showSuccess(_ text: String = "Inserted") {
        waveform.isHidden = true
        setText(text)
        show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
            self?.hide()
        }
    }

    func showError(_ text: String) {
        waveform.isHidden = true
        setText(text)
        show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.hide()
        }
    }

    func hide() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            panel.animator().alphaValue = 0
            panel.animator().setFrame(scaledFrame(0.96), display: true)
        } completionHandler: { [panel] in
            panel.orderOut(nil)
            panel.alphaValue = 1
        }
    }

    private func show() {
        position()
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.35
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }
    }

    private func setText(_ text: String) {
        label.stringValue = text
        let textWidth = min(560, max(160, ceil(label.intrinsicContentSize.width)))
        let totalWidth = textWidth + (waveform.isHidden ? 48 : 96)
        widthConstraint?.constant = totalWidth

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            panel.contentView?.layoutSubtreeIfNeeded()
            position()
        }
    }

    private func position() {
        guard let screen = NSScreen.main else {
            return
        }
        let frame = panel.frame
        let visible = screen.visibleFrame
        let x = visible.midX - frame.width / 2
        let y = visible.minY + 36
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func scaledFrame(_ scale: CGFloat) -> NSRect {
        let frame = panel.frame
        let newWidth = frame.width * scale
        let newHeight = frame.height * scale
        return NSRect(
            x: frame.midX - newWidth / 2,
            y: frame.midY - newHeight / 2,
            width: newWidth,
            height: newHeight
        )
    }
}

private final class WaveformView: NSView {
    var level: CGFloat = 0 {
        didSet {
            needsDisplay = true
        }
    }

    private let weights: [CGFloat] = [0.5, 0.8, 1.0, 0.75, 0.55]

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.92).setFill()
        let barWidth: CGFloat = 5
        let gap: CGFloat = 4
        let totalWidth = CGFloat(weights.count) * barWidth + CGFloat(weights.count - 1) * gap
        let startX = bounds.midX - totalWidth / 2

        for (index, weight) in weights.enumerated() {
            let jitter = CGFloat.random(in: -0.04...0.04)
            let normalized = max(0.08, min(1, level * weight + jitter))
            let height = 6 + normalized * 26
            let x = startX + CGFloat(index) * (barWidth + gap)
            let rect = NSRect(x: x, y: bounds.midY - height / 2, width: barWidth, height: height)
            NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
    }
}
