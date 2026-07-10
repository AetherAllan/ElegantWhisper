import AppKit
import ApplicationServices
import Foundation

enum LearningEligibility {
    case eligible
    case disabled
    case secureField
    case noAXValue
    case noSelectedRange
    case pasteOnly
    case unsupportedApp
}

struct PostEditLearningContext {
    let target: FocusTarget
    let snapshot: LearningTextSnapshot
    let language: RecognitionLanguage
    let insertedAt: Date
}

@MainActor
final class PostEditLearner {
    private let store: LearningCandidateStore
    private var session: EditObservationSession?

    init(store: LearningCandidateStore = .shared) {
        self.store = store
    }

    func prepare(
        target: FocusTarget?,
        insertedText: String,
        language: RecognitionLanguage,
        enabled: Bool
    ) -> (LearningEligibility, PostEditLearningContext?) {
        guard enabled else {
            return (.disabled, nil)
        }
        guard let target else {
            return (.pasteOnly, nil)
        }
        guard Self.isSupportedApp(bundleIdentifier: target.bundleIdentifier) else {
            return (.unsupportedApp, nil)
        }
        guard !isSecureField(target.element) else {
            return (.secureField, nil)
        }
        guard let beforeValue = stringAttribute(target.element, kAXValueAttribute) else {
            return (.noAXValue, nil)
        }
        guard let selectedRange = selectedTextRange(target.element) else {
            return (.noSelectedRange, nil)
        }
        guard selectedRange.location >= 0,
              selectedRange.length >= 0,
              NSMaxRange(selectedRange) <= (beforeValue as NSString).length
        else {
            return (.noSelectedRange, nil)
        }

        let insertedLength = (insertedText as NSString).length
        let expectedRange = NSRange(location: selectedRange.location, length: insertedLength)
        let snapshot = LearningTextSnapshot(
            beforeValue: beforeValue,
            selectedRangeBeforeInsertion: selectedRange,
            insertedText: insertedText,
            expectedRangeAfterInsertion: expectedRange,
            prefixAnchor: anchor(in: beforeValue, range: NSRange(location: max(0, selectedRange.location - 24), length: selectedRange.location - max(0, selectedRange.location - 24))),
            suffixAnchor: anchor(in: beforeValue, range: NSRange(location: NSMaxRange(selectedRange), length: min(24, (beforeValue as NSString).length - NSMaxRange(selectedRange))))
        )
        return (.eligible, PostEditLearningContext(
            target: target,
            snapshot: snapshot,
            language: language,
            insertedAt: Date()
        ))
    }

    func start(_ context: PostEditLearningContext?) {
        stop()
        guard let context,
              let currentValue = stringAttribute(context.target.element, kAXValueAttribute),
              LearningDiffEngine.candidate(snapshot: context.snapshot, currentValue: currentValue) == nil
        else {
            return
        }
        session = EditObservationSession(context: context, store: store)
        session?.start()
    }

    func stop() {
        session?.stop()
        session = nil
    }

    static func isSupportedApp(bundleIdentifier: String?) -> Bool {
        bundleIdentifier != AppConstants.bundleIdentifier
    }

    private func anchor(in value: String, range: NSRange) -> String {
        guard range.length > 0, NSMaxRange(range) <= (value as NSString).length else {
            return ""
        }
        return (value as NSString).substring(with: range)
    }

    private func isSecureField(_ element: AXUIElement) -> Bool {
        stringAttribute(element, kAXRoleAttribute) == "AXSecureTextField" ||
            stringAttribute(element, kAXSubroleAttribute) == "AXSecureTextField"
    }

    private func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func selectedTextRange(_ element: AXUIElement) -> NSRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID()
        else {
            return nil
        }
        var range = CFRange()
        guard AXValueGetValue((value as! AXValue), .cfRange, &range) else {
            return nil
        }
        return NSRange(location: range.location, length: range.length)
    }
}

@MainActor
protocol AXObserverCallbackScheduling: AnyObject {
    func scheduleReadFromObserver()
}

final class AXObserverCallbackBox: @unchecked Sendable {
    weak var session: AXObserverCallbackScheduling?

    init(session: AXObserverCallbackScheduling?) {
        self.session = session
    }

    // AX callbacks receive an opaque refcon on AppKit's callback path. The refcon owns this box,
    // not the observation session itself, so a late callback after stop() can safely become a no-op.
    static func scheduleRead(from refcon: UnsafeMutableRawPointer?) {
        guard let refcon else {
            return
        }
        let box = Unmanaged<AXObserverCallbackBox>.fromOpaque(refcon).takeUnretainedValue()
        Task { @MainActor [weak box] in
            box?.session?.scheduleReadFromObserver()
        }
    }
}

@MainActor
private final class EditObservationSession: AXObserverCallbackScheduling {
    private let context: PostEditLearningContext
    private let store: LearningCandidateStore
    private var observer: AXObserver?
    private var callbackBox: AXObserverCallbackBox?
    private var retainedRefcon: UnsafeMutableRawPointer?
    private var debounceWorkItem: DispatchWorkItem?
    private var stopWorkItem: DispatchWorkItem?
    private var stopped = false

    init(context: PostEditLearningContext, store: LearningCandidateStore) {
        self.context = context
        self.store = store
    }

    func start() {
        var observerRef: AXObserver?
        guard AXObserverCreate(context.target.processIdentifier, Self.callback, &observerRef) == .success,
              let observerRef
        else {
            DebugLog.event("postEditObserverCreateFailed")
            return
        }

        observer = observerRef
        let box = AXObserverCallbackBox(session: self)
        let refcon = Unmanaged.passRetained(box).toOpaque()
        guard AXObserverAddNotification(
            observerRef,
            context.target.element,
            kAXValueChangedNotification as CFString,
            refcon
        ) == .success else {
            DebugLog.event("postEditObserverAddFailed")
            Unmanaged<AXObserverCallbackBox>.fromOpaque(refcon).release()
            observer = nil
            return
        }

        callbackBox = box
        retainedRefcon = refcon
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observerRef), .commonModes)
        let stop = DispatchWorkItem { [weak self] in
            self?.stop()
        }
        stopWorkItem = stop
        DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: stop)
        DebugLog.event("postEditObserverStarted")
    }

    func stop() {
        guard !stopped else {
            return
        }
        stopped = true
        callbackBox?.session = nil
        debounceWorkItem?.cancel()
        stopWorkItem?.cancel()
        if let observer {
            AXObserverRemoveNotification(observer, context.target.element, kAXValueChangedNotification as CFString)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        if let retainedRefcon {
            self.retainedRefcon = nil
            Unmanaged<AXObserverCallbackBox>.fromOpaque(retainedRefcon).release()
        }
        callbackBox = nil
    }

    deinit {
        MainActor.assumeIsolated {
            stop()
        }
    }

    func scheduleReadFromObserver() {
        scheduleRead()
    }

    private func scheduleRead() {
        guard !stopped else {
            return
        }
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.readCurrentValue()
        }
        debounceWorkItem = work
        // Wait for a complete word. A shorter debounce records intermediate edits such as
        // "optio" before the user finishes typing "option".
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    private func readCurrentValue() {
        guard !stopped,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == context.target.processIdentifier,
              let value = stringAttribute(context.target.element, kAXValueAttribute)
        else {
            stop()
            return
        }
        guard let draft = LearningDiffEngine.candidate(snapshot: context.snapshot, currentValue: value) else {
            return
        }
        store.record(
            original: draft.original,
            replacement: draft.replacement,
            language: context.language,
            bundleIdentifier: context.target.bundleIdentifier
        )
        DebugLog.event("learningCandidateRecorded")
        stop()
    }

    private func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static let callback: AXObserverCallback = { _, _, _, refcon in
        AXObserverCallbackBox.scheduleRead(from: refcon)
    }
}
