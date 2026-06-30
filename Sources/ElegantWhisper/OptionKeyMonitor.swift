import AppKit
import ApplicationServices
import Foundation

final class OptionKeyMonitor {
    var onToggle: (() -> Void)?
    var onCancel: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private var monitorThread: Thread?
    private var watchdog: Timer?
    private var eventMonitors: [Any] = []
    private var armedModifier: ModifierPress?
    private var invalidated = false
    private var lastToggleTime: TimeInterval = 0
    private var shouldStop = false

    private enum ModifierKind {
        case command
        case option
    }

    private struct ModifierPress {
        let keyCode: Int64
        let kind: ModifierKind
    }

    private let optionKeyCodes: Set<Int64> = [58, 61]
    private let commandKeyCodes: Set<Int64> = [54, 55]
    private let escapeKeyCode: Int64 = 53

    func start() -> Bool {
        if eventTap != nil || !eventMonitors.isEmpty || monitorThread != nil {
            return true
        }

        // The keyboard monitor must keep working while the Dock window is closed or another
        // app is frontmost. Running the tap on its own run loop avoids coupling hotkeys to
        // AppKit window focus or the main run loop's current mode.
        shouldStop = false
        let semaphore = DispatchSemaphore(value: 0)
        final class StartResult {
            var ok = false
        }
        let result = StartResult()

        let thread = Thread { [weak self] in
            guard let self else {
                semaphore.signal()
                return
            }
            result.ok = self.startEventTapOnCurrentThread()
            semaphore.signal()
            if result.ok {
                CFRunLoopRun()
            }
            self.cleanupEventTapState()
        }
        thread.name = "\(AppConstants.productName).KeyboardMonitor"
        monitorThread = thread
        thread.start()

        _ = semaphore.wait(timeout: .now() + 1)
        if result.ok {
            return true
        }

        monitorThread = nil
        startFallbackMonitors()
        return !eventMonitors.isEmpty
    }

    func stop() {
        shouldStop = true
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource, let runLoop {
            CFRunLoopRemoveSource(runLoop, runLoopSource, .commonModes)
        }
        if let runLoop {
            CFRunLoopStop(runLoop)
        }
        for monitor in eventMonitors {
            NSEvent.removeMonitor(monitor)
        }
        eventMonitors.removeAll()
        watchdog?.invalidate()
        eventTap = nil
        runLoopSource = nil
        runLoop = nil
        monitorThread = nil
        reset()
    }

    private func startEventTapOnCurrentThread() -> Bool {
        runLoop = CFRunLoopGetCurrent()
        guard createEventTap() else {
            return false
        }
        // macOS can disable an event tap after timeout or user-input pressure. The watchdog
        // keeps the app from silently losing global hotkeys until the user restarts it.
        watchdog = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            self?.watchEventTap()
        }
        if let watchdog {
            RunLoop.current.add(watchdog, forMode: .common)
        }
        return true
    }

    private func createEventTap() -> Bool {
        let mask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            // Keep this listen-only. ElegantWhisper only observes modifier taps; Command/Option
            // combinations must still reach macOS and the frontmost app as real shortcuts.
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: OptionKeyMonitor.callback,
            userInfo: refcon
        ) else {
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        DebugLog.event("eventTapCreated")
        return true
    }

    private func watchEventTap() {
        guard !shouldStop else {
            if let runLoop {
                CFRunLoopStop(runLoop)
            }
            return
        }
        guard let tap = eventTap else {
            DebugLog.event("eventTapRecreated")
            _ = createEventTap()
            return
        }
        if CFMachPortIsValid(tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
        } else {
            DebugLog.event("eventTapRecreated")
            removeCurrentEventTap()
            _ = createEventTap()
        }
    }

    private func removeCurrentEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private func cleanupEventTapState() {
        watchdog?.invalidate()
        watchdog = nil
        removeCurrentEventTap()
        runLoop = nil
        monitorThread = nil
    }

    private func startFallbackMonitors() {
        // Fallback monitors are deliberately passive as well. The local monitor returns the
        // original event so the app never steals shortcuts when the CGEventTap path fails.
        let options: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        if let local = NSEvent.addLocalMonitorForEvents(matching: options, handler: { [weak self] event in
            self?.handle(event)
            return event
        }) {
            eventMonitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: options, handler: { [weak self] event in
            self?.handle(event)
        }) {
            eventMonitors.append(global)
        }
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            handleFlagsChanged(keyCode: Int64(event.keyCode), flags: CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)))
        case .keyDown:
            handleKeyDown(Int64(event.keyCode))
        default:
            break
        }
    }

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
                DebugLog.event("eventTapReenabled")
            }
        case .flagsChanged:
            handleFlagsChanged(
                keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                flags: event.flags
            )
        case .keyDown:
            handleKeyDown(event.getIntegerValueField(.keyboardEventKeycode))
        default:
            break
        }
    }

    private func handleKeyDown(_ keyCode: Int64) {
        if keyCode == escapeKeyCode {
            reset()
            DispatchQueue.main.async { [weak self] in
                self?.onCancel?()
            }
        } else if armedModifier != nil, !isTriggerKey(keyCode) {
            invalidated = true
        }
    }

    private func handleFlagsChanged(keyCode: Int64, flags: CGEventFlags) {
        guard let kind = modifierKind(for: keyCode) else {
            if armedModifier != nil {
                invalidated = true
            }
            return
        }

        let isDown = flags.contains(flag(for: kind))
        if isDown {
            if armedModifier == nil {
                armedModifier = ModifierPress(keyCode: keyCode, kind: kind)
                // A trigger key is valid only when pressed alone. If another modifier is already
                // down, the user is almost certainly invoking a system/app shortcut, so this
                // press cycle is ignored.
                invalidated = hasOtherModifiers(flags, excluding: kind)
            } else if armedModifier?.keyCode != keyCode {
                // Pressing another trigger key before releasing the first one is a chord, not a
                // single-key tap. Preserve that chord for the system instead of toggling recording.
                invalidated = true
            }
        } else if armedModifier?.keyCode == keyCode {
            if !invalidated {
                fireToggle()
            }
            reset()
        } else if armedModifier != nil {
            invalidated = true
        }
    }

    private func fireToggle() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastToggleTime > 0.25 else {
            return
        }
        lastToggleTime = now
        DebugLog.event("shortcutDetected")
        DispatchQueue.main.async { [weak self] in
            self?.onToggle?()
        }
    }

    private func reset() {
        armedModifier = nil
        invalidated = false
    }

    private func modifierKind(for keyCode: Int64) -> ModifierKind? {
        if commandKeyCodes.contains(keyCode) {
            return .command
        }
        if optionKeyCodes.contains(keyCode) {
            return .option
        }
        return nil
    }

    private func flag(for kind: ModifierKind) -> CGEventFlags {
        switch kind {
        case .command: .maskCommand
        case .option: .maskAlternate
        }
    }

    private func hasOtherModifiers(_ flags: CGEventFlags, excluding kind: ModifierKind) -> Bool {
        // Only the currently tracked Command or Option key may be down. Shift, Control, and the
        // opposite Command/Option flag all mean "shortcut chord", so ElegantWhisper must stand down.
        var blocked: [CGEventFlags] = [.maskShift, .maskControl]
        if kind != .command {
            blocked.append(.maskCommand)
        }
        if kind != .option {
            blocked.append(.maskAlternate)
        }
        return blocked.contains { flags.contains($0) }
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
