import ApplicationServices
import Foundation
import IOKit.hid

// The event tap and IOHID fallback deliberately live on a private run loop so
// Command/Option detection keeps working while the app is in the background.
// Internal lifecycle state is protected by lifecycleLock because stop() can be
// called from the app side while the event tap/watchdog is running on the
// monitor thread. Callbacks are the only values that cross back to MainActor.
final class OptionKeyMonitor: @unchecked Sendable {
    var onToggle: (@MainActor @Sendable () -> Void)?
    var onCancel: (@MainActor @Sendable () -> Void)?

    private let lifecycleLock = NSLock()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var hidManager: IOHIDManager?
    private var runLoop: CFRunLoop?
    private var monitorThread: Thread?
    private var watchdog: Timer?
    private let detector = ShortcutDetector()
    private let detectorLock = NSLock()
    private var lastToggleTime: TimeInterval = 0
    private var shouldStop = false

    static func canCreateListenOnlyKeyboardTap() -> Bool {
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            // This probes only the CGEventTap path. PermissionManager also checks the official
            // ListenEvent preflight/HID APIs because the production listener has an IOHID fallback.
            options: .listenOnly,
            eventsOfInterest: keyboardEventMask,
            callback: OptionKeyMonitor.probeCallback,
            userInfo: nil
        ) else {
            return false
        }
        CFMachPortInvalidate(tap)
        return true
    }

    func start() -> Bool {
        if withLifecycleLock({ eventTap != nil || hidManager != nil || monitorThread != nil }) {
            return true
        }

        // The keyboard monitor must keep working while the Dock window is closed or another
        // app is frontmost. Running the tap on its own run loop avoids coupling hotkeys to
        // AppKit window focus or the main run loop's current mode.
        withLifecycleLock {
            shouldStop = false
        }
        let semaphore = DispatchSemaphore(value: 0)
        // Thread's closure is @Sendable in Swift 6. This box is written once by
        // the monitor thread before signaling the semaphore and read once by the
        // caller after the semaphore returns.
        final class StartResult: @unchecked Sendable {
            var ok = false
        }
        let result = StartResult()

        let thread = Thread { [weak self] in
            guard let self else {
                semaphore.signal()
                return
            }
            result.ok = self.startKeyboardMonitorOnCurrentThread()
            semaphore.signal()
            if result.ok {
                CFRunLoopRun()
            }
            self.cleanupKeyboardMonitorState()
        }
        thread.name = "\(AppConstants.productName).KeyboardMonitor"
        withLifecycleLock {
            monitorThread = thread
        }
        thread.start()

        let waitResult = semaphore.wait(timeout: .now() + 3)
        guard waitResult == .success else {
            let loop = withLifecycleLock { () -> CFRunLoop? in
                shouldStop = true
                monitorThread = nil
                return runLoop
            }
            if let loop {
                CFRunLoopStop(loop)
            }
            return false
        }
        if result.ok {
            return true
        }

        withLifecycleLock {
            monitorThread = nil
        }
        return false
    }

    func stop() {
        let state = withLifecycleLock { () -> (CFMachPort?, CFRunLoopSource?, IOHIDManager?, CFRunLoop?, Timer?) in
            shouldStop = true
            let state = (eventTap, runLoopSource, hidManager, runLoop, watchdog)
            eventTap = nil
            runLoopSource = nil
            hidManager = nil
            runLoop = nil
            watchdog = nil
            return state
        }
        if let tap = state.0 {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource = state.1, let runLoop = state.3 {
            CFRunLoopRemoveSource(runLoop, runLoopSource, .commonModes)
        }
        if let hidManager = state.2, let runLoop = state.3 {
            IOHIDManagerUnscheduleFromRunLoop(hidManager, runLoop, CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        if let runLoop = state.3 {
            CFRunLoopStop(runLoop)
        }
        state.4?.invalidate()
        resetDetector()
    }

    private func startKeyboardMonitorOnCurrentThread() -> Bool {
        withLifecycleLock {
            runLoop = CFRunLoopGetCurrent()
        }
        if createEventTap() {
            // macOS can disable an event tap after timeout or user-input pressure. The watchdog
            // keeps the app from silently losing global hotkeys until the user restarts it.
            let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                self?.watchEventTap()
            }
            withLifecycleLock {
                watchdog = timer
            }
            RunLoop.current.add(timer, forMode: .common)
            return true
        }

        // CGEventTap is the normal path, but real machines sometimes keep a stale ListenEvent TCC
        // row after re-signing/rebuilding. IOHIDManager uses the same Input Monitoring permission
        // and still observes raw keyboard state while ElegantWhisper is in the background.
        return createHIDMonitor()
    }

    private func createEventTap() -> Bool {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            // Keep this listen-only. ElegantWhisper only observes modifier taps; Command/Option
            // combinations must still reach macOS and the frontmost app as real shortcuts.
            options: .listenOnly,
            eventsOfInterest: Self.keyboardEventMask,
            callback: OptionKeyMonitor.callback,
            userInfo: refcon
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if withLifecycleLock({ shouldStop }) {
            CFMachPortInvalidate(tap)
            return false
        }
        withLifecycleLock {
            eventTap = tap
            runLoopSource = source
        }
        if let source {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        DebugLog.event("eventTapCreated")
        return true
    }

    private func watchEventTap() {
        let state = withLifecycleLock { (shouldStop, runLoop, eventTap) }
        guard !state.0 else {
            if let runLoop = state.1 {
                CFRunLoopStop(runLoop)
            }
            return
        }
        guard let tap = state.2 else {
            DebugLog.event("eventTapRecreated")
            resetDetector()
            _ = createEventTap()
            return
        }
        if CFMachPortIsValid(tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
        } else {
            DebugLog.event("eventTapRecreated")
            resetDetector()
            removeCurrentEventTap()
            _ = createEventTap()
        }
    }

    private func removeCurrentEventTap() {
        let state = withLifecycleLock { () -> (CFMachPort?, CFRunLoopSource?) in
            let state = (eventTap, runLoopSource)
            eventTap = nil
            runLoopSource = nil
            return state
        }
        if let tap = state.0 {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource = state.1 {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
    }

    private func cleanupEventTapState() {
        let timer = withLifecycleLock { () -> Timer? in
            let timer = watchdog
            watchdog = nil
            return timer
        }
        timer?.invalidate()
        removeCurrentEventTap()
    }

    private func createHIDMonitor() -> Bool {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let keyboardMatch: [String: Any] = [
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard
        ]
        IOHIDManagerSetDeviceMatching(manager, keyboardMatch as CFDictionary)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(manager, OptionKeyMonitor.hidValueCallback, refcon)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            DebugLog.event("hidMonitorFailed:\(result)")
            return false
        }

        if withLifecycleLock({ shouldStop }) {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            return false
        }
        withLifecycleLock {
            hidManager = manager
        }
        DebugLog.event("hidMonitorCreated")
        return true
    }

    private func removeCurrentHIDMonitor() {
        let manager = withLifecycleLock { () -> IOHIDManager? in
            let manager = hidManager
            hidManager = nil
            return manager
        }
        guard let manager else {
            return
        }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    private func cleanupKeyboardMonitorState() {
        cleanupEventTapState()
        removeCurrentHIDMonitor()
        withLifecycleLock {
            runLoop = nil
            monitorThread = nil
        }
    }

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            resetDetector()
            if let eventTap = withLifecycleLock({ eventTap }) {
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
        handleAction(detectorAction { $0.handleKeyDown(keyCode: keyCode) })
    }

    private func handleFlagsChanged(keyCode: Int64, flags: CGEventFlags) {
        handleAction(detectorAction { $0.handleFlagsChanged(keyCode: keyCode, flags: flags) })
    }

    private func handleHIDValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        guard IOHIDElementGetUsagePage(element) == UInt32(kHIDPage_KeyboardOrKeypad) else {
            return
        }

        let usage = Int64(IOHIDElementGetUsage(element))
        let isPressed = IOHIDValueGetIntegerValue(value) != 0

        if usage == Self.hidEscapeUsage, isPressed {
            handleKeyDown(53)
            return
        }

        guard let keyCode = Self.hidUsageToKeyCode[usage] else {
            if isPressed {
                // Non-trigger key presses invalidate the current modifier-only cycle. That is what
                // preserves normal Command/Option shortcuts: Command+C, Option+Arrow, etc. remain
                // the foreground app's shortcuts and never become dictation toggles.
                handleKeyDown(0)
            }
            return
        }

        handleFlagsChanged(keyCode: keyCode, flags: currentHIDFlags(usage: usage, isPressed: isPressed))
    }

    private func currentHIDFlags(usage: Int64, isPressed: Bool) -> CGEventFlags {
        var flags = CGEventFlags()
        if (usage == Self.hidLeftCommandUsage || usage == Self.hidRightCommandUsage) && isPressed {
            flags.insert(.maskCommand)
        }
        if (usage == Self.hidLeftOptionUsage || usage == Self.hidRightOptionUsage) && isPressed {
            flags.insert(.maskAlternate)
        }
        return flags
    }

    private func handleAction(_ action: ShortcutAction?) {
        switch action {
        case .toggle:
            fireToggle()
        case .cancel:
            let handler = onCancel
            Task { @MainActor in
                handler?()
            }
        case nil:
            break
        }
    }

    private func detectorAction(_ body: (ShortcutDetector) -> ShortcutAction?) -> ShortcutAction? {
        detectorLock.lock()
        let action = body(detector)
        detectorLock.unlock()
        return action
    }

    private func fireToggle() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastToggleTime > 0.25 else {
            return
        }
        lastToggleTime = now
        DebugLog.event("shortcutDetected")
        let handler = onToggle
        Task { @MainActor in
            handler?()
        }
    }

    private func resetDetector() {
        detectorLock.lock()
        detector.reset()
        detectorLock.unlock()
    }

    private func withLifecycleLock<T>(_ body: () -> T) -> T {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return body()
    }

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }
        let monitor = Unmanaged<OptionKeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        monitor.handle(type: type, event: event)
        return Unmanaged.passUnretained(event)
    }

    private static let probeCallback: CGEventTapCallBack = { _, _, event, _ in
        Unmanaged.passUnretained(event)
    }

    private static let hidValueCallback: IOHIDValueCallback = { context, result, _, value in
        guard result == kIOReturnSuccess, let context else {
            return
        }
        let monitor = Unmanaged<OptionKeyMonitor>.fromOpaque(context).takeUnretainedValue()
        monitor.handleHIDValue(value)
    }

    private static let keyboardEventMask = CGEventMask(
        (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
    )

    private static let hidLeftOptionUsage: Int64 = 0xE2
    private static let hidLeftCommandUsage: Int64 = 0xE3
    private static let hidRightOptionUsage: Int64 = 0xE6
    private static let hidRightCommandUsage: Int64 = 0xE7
    private static let hidEscapeUsage: Int64 = 0x29
    private static let hidUsageToKeyCode: [Int64: Int64] = [
        hidLeftCommandUsage: 55,
        hidRightCommandUsage: 54,
        hidLeftOptionUsage: 58,
        hidRightOptionUsage: 61
    ]
}
