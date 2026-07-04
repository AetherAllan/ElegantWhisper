import ApplicationServices
import Foundation

enum ShortcutAction: Equatable {
    case toggle
    case cancel
}

final class ShortcutDetector {
    private let triggerKeyCodes: Set<Int64> = [61]
    private let escapeKeyCode: Int64 = 53

    private var downTriggerKeys = Set<Int64>()
    private var armedKeyCode: Int64?
    private var invalidated = false

    func handleFlagsChanged(keyCode: Int64, flags: CGEventFlags) -> ShortcutAction? {
        guard triggerKeyCodes.contains(keyCode) else {
            if !downTriggerKeys.isEmpty {
                invalidated = true
            }
            return nil
        }

        if downTriggerKeys.contains(keyCode) {
            return handleTriggerUp(keyCode)
        }
        guard isModifierFlagDown(for: keyCode, flags: flags) else {
            reset()
            return nil
        }
        return handleTriggerDown(keyCode, flags: flags)
    }

    func handleKeyDown(keyCode: Int64) -> ShortcutAction? {
        if keyCode == escapeKeyCode {
            reset()
            return .cancel
        }
        if !downTriggerKeys.isEmpty {
            invalidated = true
        }
        return nil
    }

    func reset() {
        downTriggerKeys.removeAll()
        armedKeyCode = nil
        invalidated = false
    }

    private func handleTriggerDown(_ keyCode: Int64, flags: CGEventFlags) -> ShortcutAction? {
        if downTriggerKeys.isEmpty {
            armedKeyCode = keyCode
            invalidated = hasBlockingModifiers(flags, for: keyCode)
        } else {
            // ponytail: a second trigger key is a chord; if users need combos later,
            // add explicit shortcut definitions instead of guessing here.
            invalidated = true
        }
        downTriggerKeys.insert(keyCode)
        return nil
    }

    private func handleTriggerUp(_ keyCode: Int64) -> ShortcutAction? {
        downTriggerKeys.remove(keyCode)

        if armedKeyCode == keyCode, downTriggerKeys.isEmpty {
            let shouldToggle = !invalidated
            reset()
            return shouldToggle ? .toggle : nil
        }

        if armedKeyCode != nil {
            invalidated = true
        }
        if downTriggerKeys.isEmpty {
            reset()
        }
        return nil
    }

    private func hasBlockingModifiers(_ flags: CGEventFlags, for keyCode: Int64) -> Bool {
        // Only right Option is a dictation trigger. Command is intentionally not a trigger:
        // macOS users expect Cmd+V/C/A/Z to remain pure editing shortcuts even if CGEventTap
        // misses the non-modifier keyDown inside a secure text field.
        flags.contains(.maskShift) || flags.contains(.maskControl) || flags.contains(.maskCommand) || keyCode != 61
    }

    private func isModifierFlagDown(for keyCode: Int64, flags: CGEventFlags) -> Bool {
        keyCode == 61 && flags.contains(.maskAlternate)
    }
}
