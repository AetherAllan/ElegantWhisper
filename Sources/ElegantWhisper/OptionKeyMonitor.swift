import AppKit
import ApplicationServices
import Foundation

final class OptionKeyMonitor {
    var onToggle: (() -> Void)?
    var onCancel: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var globalMonitors: [Any] = []
    private var activeKeyCode: Int64?
    private var invalidated = false
    private var lastToggleTime: TimeInterval = 0

    private let optionKeyCodes: Set<Int64> = [58, 61]
    private let commandKeyCodes: Set<Int64> = [54, 55]
    private let escapeKeyCode: Int64 = 53

    func start() -> Bool {
        if eventTap != nil || !globalMonitors.isEmpty {
            return true
        }

        let mask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgAnnotatedSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: OptionKeyMonitor.callback,
            userInfo: refcon
        ) else {
            startGlobalFallback()
            return !globalMonitors.isEmpty
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        for monitor in globalMonitors {
            NSEvent.removeMonitor(monitor)
        }
        globalMonitors.removeAll()
        reset()
    }

    private func startGlobalFallback() {
        let flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handleModifierKey(keyCode: Int64(event.keyCode))
        }
        let keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            let keyCode = Int64(event.keyCode)
            if keyCode == self?.escapeKeyCode {
                self?.reset()
                DispatchQueue.main.async {
                    self?.onCancel?()
                }
            } else if self?.activeKeyCode != nil {
                self?.invalidated = true
            }
        }
        if let flagsMonitor {
            globalMonitors.append(flagsMonitor)
        }
        if let keyMonitor {
            globalMonitors.append(keyMonitor)
        }
    }

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
        case .flagsChanged:
            handleFlagsChanged(event)
        case .keyDown:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == escapeKeyCode {
                reset()
                DispatchQueue.main.async { [weak self] in
                    self?.onCancel?()
                }
            } else if activeKeyCode != nil {
                invalidated = true
            }
        default:
            break
        }
    }

    private func handleFlagsChanged(_ event: CGEvent) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        handleModifierKey(keyCode: keyCode)
    }

    private func handleModifierKey(keyCode: Int64) {
        guard isTriggerKey(keyCode) else {
            if activeKeyCode != nil {
                invalidated = true
            }
            return
        }

        if activeKeyCode == nil {
            activeKeyCode = keyCode
            invalidated = false
            return
        }

        let shouldToggle = activeKeyCode == keyCode && !invalidated
        reset()
        if shouldToggle {
            fireToggle()
        }
    }

    private func fireToggle() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastToggleTime > 0.25 else {
            return
        }
        lastToggleTime = now
        DispatchQueue.main.async { [weak self] in
            self?.onToggle?()
        }
    }

    private func reset() {
        activeKeyCode = nil
        invalidated = false
    }

    private func isTriggerKey(_ keyCode: Int64) -> Bool {
        optionKeyCodes.contains(keyCode) || commandKeyCodes.contains(keyCode)
    }

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }
        let monitor = Unmanaged<OptionKeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        monitor.handle(type: type, event: event)
        return Unmanaged.passUnretained(event)
    }
}
