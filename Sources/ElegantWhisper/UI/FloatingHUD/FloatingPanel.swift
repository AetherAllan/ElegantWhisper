import AppKit
import SwiftUI

@MainActor
final class FloatingPanel {
    private let panel: NSPanel
    private let model = FloatingHUDModel()
    private var presentationID = UUID()
    private var pendingHide: DispatchWorkItem?
    private var preferredAnchor: NSPoint?
    var onCancel: (@MainActor () -> Void)?
    var onConfirm: (@MainActor () -> Void)?
    private lazy var waveformClock = WaveformClock { [model] in
        model.advanceFrame()
    }

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: FloatingHUDView.compactWidth, height: FloatingHUDView.height),
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
        // The cancel and finish buttons take clicks. The panel is non-activating and never
        // becomes key, so clicking them leaves keyboard focus in the app being dictated into.
        panel.ignoresMouseEvents = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true

        let hostingView = FirstMouseHostingView(rootView: FloatingHUDView(
            model: model,
            onCancel: { [weak self] in self?.onCancel?() },
            onConfirm: { [weak self] in self?.onConfirm?() }
        ))
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hostingView
        updateWidthForCurrentText()
    }

    func showRecording(text: String) {
        beginPresentation()
        model.showRecording(text: text)
        updateWidthForCurrentText()
        show()
        if let view = panel.contentView {
            waveformClock.start(in: view)
        }
    }

    func setPreferredAnchor(_ point: NSPoint?) {
        preferredAnchor = point
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
            // isVisible can remain true while an interrupted hide leaves the panel transparent.
            DebugLog.event("panelShowRetry")
            self.show()
        }
    }

    func updatePartial(_ text: String) {
        // Kept for accessibility; the compact capsule does not show live text.
        model.updatePartial(text)
    }

    func enqueueLevels(_ levels: [Float]) {
        model.enqueueLevels(levels.map { CGFloat($0) })
    }

    /// Stop the listening chrome while keeping the last partial transcript visible.
    func stopWaveform() {
        waveformClock.stop()
        model.stopListening()
        updateWidthForCurrentText()
        position()
    }

    func showStatus(_ text: String) {
        beginPresentation()
        setText(text)
        show()
    }

    func showSuccess(_ text: String = "Inserted") {
        beginPresentation()
        setText(text, phase: .success)
        show()
        scheduleHide(after: 0.9, presentationID: presentationID)
    }

    func showError(_ text: String) {
        beginPresentation()
        setText(text, phase: .failure)
        show()
        // Errors carry a reason the user needs to read; give them longer than a success flash.
        scheduleHide(after: 2.2, presentationID: presentationID)
    }

    func hide() {
        waveformClock.stop()
        pendingHide?.cancel()
        pendingHide = nil
        hide(presentationID: presentationID)
    }

    private func beginPresentation() {
        pendingHide?.cancel()
        pendingHide = nil
        presentationID = UUID()
        // A new dictation can begin while the previous success/error fade is still running.
        // Reset alpha before show() inspects visibility so stale animation state cannot win.
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
        guard presentationID == expectedID else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.22
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard self?.presentationID == expectedID else { return }
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
        // Always front and restore alpha. isVisible alone is not visual readiness.
        panel.orderFrontRegardless()
        DebugLog.event("panelShowState:visible=\(wasVisible):alpha=\(panel.alphaValue)")
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || (wasVisible && panel.alphaValue >= 0.99) ? 0 : 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func setText(_ text: String, phase: FloatingHUDPhase = .working) {
        waveformClock.stop()
        model.showStatus(text, phase: phase)
        updateWidthForCurrentText()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
            position()
        }
    }

    private func updateWidthForCurrentText() {
        let width: CGFloat
        switch model.phase {
        case .listening, .working:
            width = FloatingHUDView.compactWidth
        case .success, .failure:
            let font = NSFont.systemFont(ofSize: 13, weight: .medium)
            let textWidth = ceil((model.text as NSString).size(withAttributes: [.font: font]).width)
            // Padding + icon + spacing + padding, matching FloatingHUDView's message layout.
            width = min(Self.maximumMessageWidth, max(FloatingHUDView.compactWidth, 14 + 18 + 8 + 14 + textWidth))
        }
        guard panel.frame.width != width else { return }
        panel.setContentSize(NSSize(width: width, height: FloatingHUDView.height))
    }

    private static let maximumMessageWidth: CGFloat = 360

    private func position() {
        let screens = NSScreen.screens
        let mouse = NSEvent.mouseLocation
        guard let screen = preferredAnchor.flatMap({ anchor in
            screens.first { $0.frame.contains(anchor) }
        }) ?? screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main ?? screens.first
        else {
            return
        }
        let visible = screen.visibleFrame
        panel.setFrameOrigin(FloatingPanelPlacement.origin(panelSize: panel.frame.size, visibleFrame: visible))
    }
}

/// Lets the first click on a button act immediately. The panel is never key, so without this the
/// first click would only be spent focusing the window.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

/// Ticks once per display refresh (up to 60 fps) while the HUD is listening, so the waveform
/// animates at screen rate instead of at the audio buffer rate.
@MainActor
private final class WaveformClock: NSObject {
    private var link: CADisplayLink?
    private let tick: @MainActor () -> Void

    init(tick: @escaping @MainActor () -> Void) {
        self.tick = tick
    }

    func start(in view: NSView) {
        guard link == nil else { return }
        let link = view.displayLink(target: self, selector: #selector(step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        tick()
    }
}

enum FloatingPanelPlacement {
    static func origin(panelSize: NSSize, visibleFrame: NSRect) -> NSPoint {
        let centeredX = visibleFrame.midX - panelSize.width / 2
        let preferredY = visibleFrame.minY + 48
        return NSPoint(
            x: min(max(centeredX, visibleFrame.minX), max(visibleFrame.minX, visibleFrame.maxX - panelSize.width)),
            y: min(max(preferredY, visibleFrame.minY), max(visibleFrame.minY, visibleFrame.maxY - panelSize.height))
        )
    }
}
