import AppKit
import ApplicationServices
import Carbon
import Foundation

enum InjectionResult: Sendable {
    case pasteAttempted
    case copied
}

@MainActor
final class TextInjector {
    private let focusDetector: FocusDetector
    private let inputSourceManager: InputSourceManager
    private let sessionPasteboardType = NSPasteboard.PasteboardType("\(AppConstants.bundleIdentifier).session")

    init(focusDetector: FocusDetector, inputSourceManager: InputSourceManager) {
        self.focusDetector = focusDetector
        self.inputSourceManager = inputSourceManager
    }

    func inject(
        _ text: String,
        target: FocusTarget?,
        fallbackApp: NSRunningApplication?,
        pasteSent: @escaping @MainActor @Sendable () -> Void = {},
        completion: @escaping @MainActor @Sendable (InjectionResult) -> Void
    ) {
        let pasteboard = NSPasteboard.general
        // Preserve every pasteboard flavor, not just plain text. Users often keep rich text,
        // images, or files on the clipboard, and dictation should not permanently destroy that.
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        let sessionToken = UUID().uuidString
        copy(text, sessionToken: sessionToken, to: pasteboard)
        let ownedChangeCount = pasteboard.changeCount

        let targetApp: NSRunningApplication
        let validatedTarget: FocusTarget?
        if let target, focusDetector.isValid(target) {
            targetApp = target.app
            validatedTarget = target
        } else if let fallbackApp, isUsableFallbackApp(fallbackApp) {
            targetApp = fallbackApp
            validatedTarget = nil
            DebugLog.event("textInjectionUsingFallbackApp")
        } else {
            DebugLog.event(target == nil ? "textInjectionCopied:noTarget" : "textInjectionCopied:invalidTarget")
            completion(.copied)
            return
        }

        if NSWorkspace.shared.frontmostApplication?.processIdentifier != targetApp.processIdentifier {
            targetApp.activate(options: [])
        }

        let previousInputSource = inputSourceManager.switchToASCIIIfNeeded()

        Task { @MainActor [weak self, validatedTarget, targetApp, previousInputSource, snapshot, text, sessionToken] in
            try? await Task.sleep(for: .milliseconds(150))
            let pasteboard = NSPasteboard.general
            guard let self, self.canPaste(to: targetApp, target: validatedTarget) else {
                self?.inputSourceManager.restore(previousInputSource)
                DebugLog.event("textInjectionCopied:pasteCheckFailed")
                completion(.copied)
                return
            }

            guard self.paste() else {
                self.inputSourceManager.restore(previousInputSource)
                DebugLog.event("textInjectionCopied:pasteEventFailed")
                completion(.copied)
                return
            }
            pasteSent()

            try? await Task.sleep(for: .milliseconds(700))
            // Many apps read the pasteboard asynchronously after Cmd+V. Restoring too early
            // makes the target paste the user's old clipboard instead of the transcript.
            if pasteboard.changeCount == ownedChangeCount,
               pasteboard.string(forType: .string) == text,
               pasteboard.string(forType: self.sessionPasteboardType) == sessionToken
            {
                snapshot.restore(to: pasteboard)
            }
            self.inputSourceManager.restore(previousInputSource)
            DebugLog.event("textInjectionPasteAttempted")
            completion(.pasteAttempted)
        }
    }

    private func canPaste(to app: NSRunningApplication, target: FocusTarget?) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            return false
        }

        guard let target else {
            // ponytail: optimistic paste fallback. Some real editors, especially Electron/Monaco
            // and web inputs, do not expose a stable editable AX element even when the insertion
            // cursor is visible. When AppController has no AX target but knows the non-ElegantWhisper
            // frontmost app, copy text and send Cmd+V to that app. If this ever causes unwanted
            // pastes in non-editor surfaces, make this app allowlisted instead of adding another
            // broad AX tree crawler.
            return true
        }

        // Re-read focus after activation. Browser and Electron editors often expose a new AX
        // wrapper for the same visible insertion point after a short delay, so requiring
        // CFEqual(original, focused) makes valid inputs fall back to "copied". The safe
        // invariant is narrower and matches the product behavior: the same target process must
        // still own a currently focused editable element before we send Cmd+V.
        if let focused = focusDetector.currentEditableTarget(processIdentifier: app.processIdentifier) {
            return focusDetector.isValid(focused)
        }

        // Cursor, Codex, and other Electron-backed editors can keep keyboard focus in the editor
        // while AXFocusedUIElement briefly returns nil after activation. Falling back to the exact
        // element captured at recording start avoids losing the transcript, but still keeps the
        // safety boundary tight: the same app must be frontmost and the original AX element must
        // still be alive/editable before Cmd+V is posted.
        if focusDetector.isValid(target) {
            DebugLog.event("pasteUsingOriginalTargetFallback")
            return true
        }
        return false
    }

    private func isUsableFallbackApp(_ app: NSRunningApplication) -> Bool {
        !app.isTerminated && app.bundleIdentifier != AppConstants.bundleIdentifier
    }

    private func copy(_ text: String, sessionToken: String, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setString(sessionToken, forType: sessionPasteboardType)
    }

    private func paste() -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyCode = pasteKeyCode()
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else {
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private func pasteKeyCode() -> CGKeyCode {
        keyCode(for: "v") ?? 9
    }

    private func keyCode(for character: String) -> CGKeyCode? {
        // Non-US keyboard layouts can move the physical V key. Resolve the current layout first
        // so simulated Cmd+V remains a paste command instead of producing a different shortcut.
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else {
            return nil
        }

        let data = unsafeBitCast(pointer, to: CFData.self)
        guard let bytes = CFDataGetBytePtr(data) else {
            return nil
        }
        return bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            for keyCode in UInt16(0)..<UInt16(128) {
                var deadKeyState: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var actualLength = 0
                let status = UCKeyTranslate(
                    layout,
                    keyCode,
                    UInt16(kUCKeyActionDown),
                    0,
                    UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState,
                    chars.count,
                    &actualLength,
                    &chars
                )
                if status == noErr,
                   actualLength > 0,
                   String(utf16CodeUnits: chars, count: actualLength).lowercased() == character
                {
                    return CGKeyCode(keyCode)
                }
            }
            return nil
        }
    }
}

// NSPasteboardItem is an AppKit reference object and is not annotated Sendable.
// The snapshot is immutable after capture and is restored only on MainActor
// after a deliberate delay, so this wrapper is the narrow concurrency boundary.
private struct PasteboardSnapshot: @unchecked Sendable {
    let items: [NSPasteboardItem]

    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let copies = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
        return PasteboardSnapshot(items: copies)
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.writeObjects(items)
    }
}
