import AppKit
import SwiftUI

@MainActor
final class FloatingPanel {
    private let panel: NSPanel
    private let model = FloatingHUDModel()
    private var presentationID = UUID()
    private var pendingHide: DispatchWorkItem?
    private var preferredAnchor: NSPoint?
    // Width only grows within one presentation so streaming partials do not make the capsule
    // jitter left and right around the screen center.
    private var minimumWidth: CGFloat = 0

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 196, height: Self.height),
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
        model.updateLevel(CGFloat(level))
    }

    /// Stop the listening chrome while keeping the last partial transcript visible.
    func stopWaveform() {
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
        pendingHide?.cancel()
        pendingHide = nil
        hide(presentationID: presentationID)
    }

    private func beginPresentation() {
        pendingHide?.cancel()
        pendingHide = nil
        presentationID = UUID()
        minimumWidth = 0
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
        model.showStatus(text, phase: phase)
        updateWidthForCurrentText()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
            position()
        }
    }

    private func updateWidthForCurrentText() {
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let fittingWidth = ceil((model.text as NSString).size(withAttributes: [.font: font]).width)
        // Leading padding + glyph + spacing + trailing padding, matching FloatingHUDView.
        // Plus the elapsed-time label (and its spacing) while listening.
        let chrome: CGFloat = 12 + 30 + 10 + 16 + (model.phase == .listening ? 44 : 0)
        let width = min(Self.maximumWidth, max(Self.minimumBaseWidth, minimumWidth, chrome + fittingWidth))
        if model.phase == .listening {
            minimumWidth = width
        }
        guard panel.frame.width != width else { return }
        panel.setContentSize(NSSize(width: width, height: Self.height))
    }

    private static let height: CGFloat = 44
    private static let minimumBaseWidth: CGFloat = 168
    private static let maximumWidth: CGFloat = 360

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
