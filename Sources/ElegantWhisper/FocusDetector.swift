import AppKit
import ApplicationServices
import Foundation

struct FocusTarget {
    let app: NSRunningApplication
    let element: AXUIElement

    var processIdentifier: pid_t {
        app.processIdentifier
    }
}

final class FocusDetector {
    private let editableRoles: Set<String> = [
        kAXTextFieldRole,
        kAXTextAreaRole,
        kAXComboBoxRole,
        kAXSearchFieldSubrole,
        "AXTextEntryArea"
    ]

    func currentEditableTarget() -> FocusTarget? {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication,
              let element = editableElement(from: focusedElement())
        else {
            return nil
        }
        return FocusTarget(app: app, element: element)
    }

    func isValid(_ target: FocusTarget) -> Bool {
        guard AXIsProcessTrusted() else {
            return false
        }

        var pid: pid_t = 0
        AXUIElementGetPid(target.element, &pid)
        guard pid == target.processIdentifier else {
            return false
        }

        return isEditable(target.element)
    }

    private func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &value)
        guard result == .success, let element = value else {
            return nil
        }
        return (element as! AXUIElement)
    }

    private func editableElement(from element: AXUIElement?, depth: Int = 0) -> AXUIElement? {
        guard let element else {
            return nil
        }
        if isEditable(element) {
            return element
        }
        guard depth < 2 else {
            return nil
        }
        for attribute in ["AXEditableAncestor", "AXHighestEditableAncestor", "AXActiveElement"] {
            if let child = elementAttribute(element, attribute),
               let editable = editableElement(from: child, depth: depth + 1)
            {
                return editable
            }
        }
        return nil
    }

    private func isEditable(_ element: AXUIElement) -> Bool {
        if let role = stringAttribute(element, kAXRoleAttribute), editableRoles.contains(role) {
            return true
        }
        if let subrole = stringAttribute(element, kAXSubroleAttribute), editableRoles.contains(subrole) {
            return true
        }

        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue {
            return true
        }
        if AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success, settable.boolValue {
            return true
        }

        return false
    }

    private func elementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value
        else {
            return nil
        }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }
}
