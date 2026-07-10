import AppKit
import SwiftUI

@MainActor
final class FloatingPanel {
    private let panel: NSPanel
    private let model = FloatingHUDModel()
    private var presentationID = UUID()
    private var pendingHide: DispatchWorkItem?
    private var preferredAnchor: NSPoint?

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 196, height: 40),
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

        let hostingView = NSHostingView(rootView: FloatingHUDView(model: model))
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
        model.updatePartial(text)
        updateWidthForCurrentText()
        position()
    }

    func updateLevel(_ level: Float) {
        model.level = CGFloat(level)
    }

    /// Stop the listening chrome while keeping the last partial transcript visible.
    func stopWaveform() {
        model.showsWaveform = false
        model.level = 0
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
        setText(text)
        show()
        scheduleHide(after: 0.55, presentationID: presentationID)
    }

    func showError(_ text: String) {
        beginPresentation()
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

    private func setText(_ text: String) {
        model.showStatus(text)
        updateWidthForCurrentText()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
            position()
        }
    }

    private func updateWidthForCurrentText() {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let fittingWidth = ceil((model.text as NSString).size(withAttributes: [.font: font]).width)
        let labelWidth = min(172, max(72, fittingWidth))
        let waveformSpace: CGFloat = model.showsWaveform ? 42 : 0
        let width = min(270, max(150, 30 + waveformSpace + labelWidth))
        panel.setContentSize(NSSize(width: width, height: 40))
    }

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
