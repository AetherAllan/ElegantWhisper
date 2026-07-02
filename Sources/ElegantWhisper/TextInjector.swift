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

    func inject(_ text: String, target: FocusTarget?, completion: @escaping @MainActor @Sendable (InjectionResult) -> Void) {
        let pasteboard = NSPasteboard.general
        // Preserve every pasteboard flavor, not just plain text. Users often keep rich text,
        // images, or files on the clipboard, and dictation should not permanently destroy that.
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        let sessionToken = UUID().uuidString
        copy(text, sessionToken: sessionToken, to: pasteboard)
        let ownedChangeCount = pasteboard.changeCount

        guard let target, focusDetector.isValid(target) else {
            completion(.copied)
            return
        }

        if NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier {
            target.app.activate(options: [])
        }

        let previousInputSource = inputSourceManager.switchToASCIIIfNeeded()

        Task { @MainActor [weak self, target, previousInputSource, snapshot, text, sessionToken] in
            try? await Task.sleep(for: .milliseconds(150))
            let pasteboard = NSPasteboard.general
            // Re-read focus after activation. The original AX element may be stale, and pasting
            // into a stale or different app is worse than falling back to "copied".
            guard let self,
                  let focused = self.focusDetector.currentEditableTarget(processIdentifier: target.processIdentifier),
                  self.focusDetector.isValid(focused),
                  self.focusDetector.isSameElement(focused.element, target.element)
            else {
                self?.inputSourceManager.restore(previousInputSource)
                completion(.copied)
                return
            }

            guard self.paste() else {
                self.inputSourceManager.restore(previousInputSource)
                completion(.copied)
                return
            }

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
            completion(.pasteAttempted)
        }
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
