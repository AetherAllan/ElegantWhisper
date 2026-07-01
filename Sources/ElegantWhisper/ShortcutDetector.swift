import ApplicationServices
import Foundation

enum ShortcutAction: Equatable {
    case toggle
    case cancel
}

final class ShortcutDetector {
    private let triggerKeyCodes: Set<Int64> = [54, 55, 58, 61]
    private let commandKeyCodes: Set<Int64> = [54, 55]
    private let optionKeyCodes: Set<Int64> = [58, 61]
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
        if flags.contains(.maskShift) || flags.contains(.maskControl) {
            return true
        }
        if commandKeyCodes.contains(keyCode) {
            return flags.contains(.maskAlternate)
        }
        if optionKeyCodes.contains(keyCode) {
            return flags.contains(.maskCommand)
        }
        return true
    }

    private func isModifierFlagDown(for keyCode: Int64, flags: CGEventFlags) -> Bool {
        if commandKeyCodes.contains(keyCode) {
            return flags.contains(.maskCommand)
        }
        if optionKeyCodes.contains(keyCode) {
            return flags.contains(.maskAlternate)
        }
        return false
    }
}
