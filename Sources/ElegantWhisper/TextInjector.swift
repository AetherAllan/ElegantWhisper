import AppKit
import ApplicationServices
import Foundation

enum InjectionResult {
    case pasted
    case copied
}

final class TextInjector {
    private let focusDetector: FocusDetector
    private let inputSourceManager: InputSourceManager

    init(focusDetector: FocusDetector, inputSourceManager: InputSourceManager) {
        self.focusDetector = focusDetector
        self.inputSourceManager = inputSourceManager
    }

    func inject(_ text: String, target: FocusTarget?, completion: @escaping (InjectionResult) -> Void) {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        copy(text, to: pasteboard)

        guard let target, focusDetector.isValid(target) else {
            completion(.copied)
            return
        }

        if NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier {
            target.app.activate(options: [])
        }

        let previousInputSource = inputSourceManager.switchToASCIIIfNeeded()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard self?.focusDetector.isValid(target) == true else {
                self?.inputSourceManager.restore(previousInputSource)
                completion(.copied)
                return
            }

            self?.paste()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                snapshot.restore(to: pasteboard)
                self?.inputSourceManager.restore(previousInputSource)
                completion(.pasted)
            }
        }
    }

    private func copy(_ text: String, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func paste() {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

private struct PasteboardSnapshot {
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
