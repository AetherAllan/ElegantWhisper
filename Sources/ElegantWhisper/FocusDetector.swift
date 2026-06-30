import AppKit
import ApplicationServices
import Foundation

struct FocusTarget {
    let app: NSRunningApplication
    let element: AXUIElement
    let bundleIdentifier: String?

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
              let focused = focusedElement(),
              let app = app(for: focused),
              let element = editableElement(from: focused)
        else {
            return nil
        }
        return FocusTarget(app: app, element: element, bundleIdentifier: app.bundleIdentifier)
    }

    func currentEditableTarget(processIdentifier: pid_t) -> FocusTarget? {
        guard let target = currentEditableTarget(),
              target.processIdentifier == processIdentifier
        else {
            return nil
        }
        return target
    }

    func isValid(_ target: FocusTarget) -> Bool {
        guard AXIsProcessTrusted(), !target.app.isTerminated else {
            return false
        }

        var pid: pid_t = 0
        AXUIElementGetPid(target.element, &pid)
        guard pid == target.processIdentifier else {
            return false
        }
        if let expected = target.bundleIdentifier,
           let current = target.app.bundleIdentifier,
           expected != current
        {
            return false
        }

        return isEditable(target.element)
    }

    private func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        // Prefer the focused application first. Browser text areas and Electron editors often
        // expose a better focused element through AXFocusedApplication than through the
        // system-wide fallback alone.
        if let focusedApp = elementAttribute(systemWide, kAXFocusedApplicationAttribute),
           let focused = elementAttribute(focusedApp, kAXFocusedUIElementAttribute)
        {
            return focused
        }

        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &value)
        guard result == .success, let element = value else {
            return nil
        }
        return (element as! AXUIElement)
    }

    private func app(for element: AXUIElement) -> NSRunningApplication? {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        if pid > 0, let app = NSRunningApplication(processIdentifier: pid) {
            return app
        }
        return NSWorkspace.shared.frontmostApplication
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
        // Web apps frequently focus a wrapper node while the editable text node is exposed as
        // an AX ancestor/active element. Keep the search shallow so we do not accidentally pick
        // an unrelated text field elsewhere in the page.
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

        // Some browser and custom editor controls do not report a classic text role. A settable
        // value or selected-text attribute is the safest native signal that Cmd+V should land in
        // an editable insertion point.
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
