import AppKit
import ApplicationServices
import Foundation

enum LearningEligibility: Equatable {
    case eligible
    case disabled
    case secureField
    case noAXValue
    case noSelectedRange
    case pasteOnly
    case unsupportedApp
}

struct LearningTextSnapshot {
    let beforeValue: String
    let selectedRangeBeforeInsertion: NSRange
    let insertedText: String
    let expectedRangeAfterInsertion: NSRange
    let prefixAnchor: String
    let suffixAnchor: String
}

struct LearningCandidateDraft: Equatable {
    let original: String
    let replacement: String
}

enum LearningDiffEngine {
    static func candidate(snapshot: LearningTextSnapshot, currentValue: String) -> LearningCandidateDraft? {
        guard let expectedValue = expectedValue(from: snapshot),
              expectedValue != currentValue
        else {
            return nil
        }

        guard anchorsStillExist(snapshot: snapshot, in: currentValue) else {
            return nil
        }

        let expected = expectedValue as NSString
        let current = currentValue as NSString
        let expectedLength = expected.length
        let currentLength = current.length

        var prefixLength = 0
        while prefixLength < expectedLength,
              prefixLength < currentLength,
              expected.character(at: prefixLength) == current.character(at: prefixLength)
        {
            prefixLength += 1
        }

        var suffixLength = 0
        while suffixLength < expectedLength - prefixLength,
              suffixLength < currentLength - prefixLength,
              expected.character(at: expectedLength - suffixLength - 1) == current.character(at: currentLength - suffixLength - 1)
        {
            suffixLength += 1
        }

        let originalRange = NSRange(location: prefixLength, length: expectedLength - prefixLength - suffixLength)
        let replacementRange = NSRange(location: prefixLength, length: currentLength - prefixLength - suffixLength)

        guard originalRange.length > 0, replacementRange.length > 0 else {
            return nil
        }
        guard contains(snapshot.expectedRangeAfterInsertion, originalRange) else {
            return nil
        }

        let original = expected.substring(with: originalRange).trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = current.substring(with: replacementRange).trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSafeDictionaryPair(original: original, replacement: replacement, insertedText: snapshot.insertedText) else {
            return nil
        }
        return LearningCandidateDraft(original: original, replacement: replacement)
    }

    private static func expectedValue(from snapshot: LearningTextSnapshot) -> String? {
        let before = snapshot.beforeValue as NSString
        guard NSMaxRange(snapshot.selectedRangeBeforeInsertion) <= before.length else {
            return nil
        }
        return before.replacingCharacters(in: snapshot.selectedRangeBeforeInsertion, with: snapshot.insertedText)
    }

    private static func anchorsStillExist(snapshot: LearningTextSnapshot, in currentValue: String) -> Bool {
        let current = currentValue as NSString
        if !snapshot.prefixAnchor.isEmpty,
           current.range(of: snapshot.prefixAnchor).location == NSNotFound
        {
            return false
        }
        if !snapshot.suffixAnchor.isEmpty,
           current.range(of: snapshot.suffixAnchor).location == NSNotFound
        {
            return false
        }
        return true
    }

    private static func contains(_ outer: NSRange, _ inner: NSRange) -> Bool {
        inner.location >= outer.location && NSMaxRange(inner) <= NSMaxRange(outer)
    }

    private static func isSafeDictionaryPair(original: String, replacement: String, insertedText: String) -> Bool {
        guard !original.isEmpty, !replacement.isEmpty else {
            return false
        }
        guard original.count <= 64, replacement.count <= 64 else {
            return false
        }
        guard hasLetterOrNumber(original), hasLetterOrNumber(replacement) else {
            return false
        }

        let smaller = max(1, min(original.count, replacement.count))
        let larger = max(original.count, replacement.count)
        guard Double(larger) / Double(smaller) <= 3 else {
            return false
        }

        if insertedText.count > 20,
           Double(original.count) / Double(insertedText.count) > 0.6
        {
            return false
        }
        return true
    }

    private static func hasLetterOrNumber(_ value: String) -> Bool {
        value.unicodeScalars.contains {
            CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
        }
    }
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
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
