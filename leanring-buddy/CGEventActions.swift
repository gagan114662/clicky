import AppKit
import CoreGraphics

/// Pure CGEvent primitives for synthesizing mouse and keyboard input.
/// All functions are static and side-effect-only — they post events into the
/// HID system event source and return immediately.
enum CGEventActions {

    // MARK: - Public API: mouse

    /// Move the cursor to a global screen point without clicking.
    static func moveMouse(toGlobalPoint targetGlobalPoint: CGPoint) {
        let moveEvent = CGEvent(mouseEventSource: nil,
                                mouseType: .mouseMoved,
                                mouseCursorPosition: targetGlobalPoint,
                                mouseButton: .left)
        moveEvent?.post(tap: .cghidEventTap)
    }

    /// Move + left click at a global screen point.
    static func leftClick(atGlobalPoint targetGlobalPoint: CGPoint) {
        moveMouse(toGlobalPoint: targetGlobalPoint)
        Self.postMouseClick(at: targetGlobalPoint, button: .left)
    }

    static func rightClick(atGlobalPoint targetGlobalPoint: CGPoint) {
        moveMouse(toGlobalPoint: targetGlobalPoint)
        Self.postMouseClick(at: targetGlobalPoint, button: .right)
    }

    static func doubleLeftClick(atGlobalPoint targetGlobalPoint: CGPoint) {
        moveMouse(toGlobalPoint: targetGlobalPoint)
        Self.postMouseClick(at: targetGlobalPoint, button: .left, clickCount: 2)
    }

    /// Click-and-drag from start to end.
    static func leftClickDrag(fromGlobalPoint startGlobalPoint: CGPoint,
                              toGlobalPoint endGlobalPoint: CGPoint) {
        let downEvent = CGEvent(mouseEventSource: nil,
                                mouseType: .leftMouseDown,
                                mouseCursorPosition: startGlobalPoint,
                                mouseButton: .left)
        downEvent?.post(tap: .cghidEventTap)
        let dragEvent = CGEvent(mouseEventSource: nil,
                                mouseType: .leftMouseDragged,
                                mouseCursorPosition: endGlobalPoint,
                                mouseButton: .left)
        dragEvent?.post(tap: .cghidEventTap)
        let upEvent = CGEvent(mouseEventSource: nil,
                              mouseType: .leftMouseUp,
                              mouseCursorPosition: endGlobalPoint,
                              mouseButton: .left)
        upEvent?.post(tap: .cghidEventTap)
    }

    /// Vertical scroll. Positive units scroll up; negative scrolls down.
    static func scrollVertical(byUnits scrollUnitCount: Int32) {
        let event = CGEvent(scrollWheelEvent2Source: nil,
                            units: .pixel,
                            wheelCount: 1,
                            wheel1: scrollUnitCount,
                            wheel2: 0,
                            wheel3: 0)
        event?.post(tap: .cghidEventTap)
    }

    // MARK: - Public API: keyboard

    /// Type text into the focused control. Accessibility value-setting is used
    /// first for focused text fields because CG keyboard events can be dropped
    /// by macOS when the app is launched from Xcode without Input Monitoring.
    @discardableResult
    static func typeText(_ stringToType: String) -> Bool {
        if typeIntoFocusedAccessibleTextElement(stringToType) {
            return true
        }
        typeUnicodeString(stringToType)
        return false
    }

    /// Type a unicode string (uses keyboardSetUnicodeString for full UTF-8).
    static func typeUnicodeString(_ stringToType: String) {
        for character in stringToType {
            let utf16Units = Array(String(character).utf16)
            let downEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
            downEvent?.keyboardSetUnicodeString(stringLength: utf16Units.count, unicodeString: utf16Units)
            downEvent?.post(tap: .cghidEventTap)
            let upEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
            upEvent?.keyboardSetUnicodeString(stringLength: utf16Units.count, unicodeString: utf16Units)
            upEvent?.post(tap: .cghidEventTap)
        }
    }

    /// Press a key combination (e.g., "cmd+t", "ctrl+shift+a", "Return", "Escape").
    @discardableResult
    static func pressKeyCombo(_ keyComboString: String) -> Bool {
        guard canPressKeyCombo(keyComboString) else {
            return false
        }
        let parsed = parseKeyComboString(keyComboString)
        guard let downEvent = CGEvent(keyboardEventSource: nil,
                                      virtualKey: parsed.virtualKeyCode,
                                      keyDown: true),
              let upEvent = CGEvent(keyboardEventSource: nil,
                                    virtualKey: parsed.virtualKeyCode,
                                    keyDown: false) else {
            return false
        }
        downEvent.flags = parsed.modifierFlags
        downEvent.post(tap: .cghidEventTap)
        upEvent.flags = parsed.modifierFlags
        upEvent.post(tap: .cghidEventTap)
        return true
    }

    // MARK: - Public API: parsing helpers (testable)

    struct ParsedKeyCombo {
        let virtualKeyCode: CGKeyCode
        let modifierFlags: CGEventFlags
    }

    /// Parses strings like "cmd+t", "ctrl+shift+a", "Return", "space".
    /// Returns key code 0 (and no modifiers) if the final segment is unknown.
    static func parseKeyComboString(_ keyComboString: String) -> ParsedKeyCombo {
        let segments = keyComboString
            .split(separator: "+")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var modifierFlags: CGEventFlags = []
        var lastSegmentRepresentingKey: String = keyComboString
        for (index, segment) in segments.enumerated() {
            let lowercased = segment.lowercased()
            let isLastSegment = (index == segments.count - 1)
            switch lowercased {
            case "cmd", "command", "meta": modifierFlags.insert(.maskCommand)
            case "ctrl", "control": modifierFlags.insert(.maskControl)
            case "shift": modifierFlags.insert(.maskShift)
            case "alt", "option", "opt": modifierFlags.insert(.maskAlternate)
            default:
                if isLastSegment { lastSegmentRepresentingKey = segment }
            }
        }
        let keyCode = virtualKeyCodeForName(lastSegmentRepresentingKey) ?? CGKeyCode(0)
        return ParsedKeyCombo(virtualKeyCode: keyCode, modifierFlags: modifierFlags)
    }

    static func canPressKeyCombo(_ keyComboString: String) -> Bool {
        guard let keyName = finalKeyName(in: keyComboString) else { return false }
        return virtualKeyCodeForName(keyName) != nil
    }

    static func finalKeyName(in keyComboString: String) -> String? {
        let segments = keyComboString
            .split(separator: "+")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return segments.last
    }

    /// Maps a human-readable key name (case-insensitive for special keys, case-sensitive for letters) to a virtual key code.
    static func virtualKeyCodeForName(_ keyName: String) -> CGKeyCode? {
        // Special keys (case-insensitive)
        let specialKeyMap: [String: CGKeyCode] = [
            "return": 0x24, "enter": 0x24, "tab": 0x30, "space": 0x31,
            "delete": 0x33, "backspace": 0x33, "escape": 0x35, "esc": 0x35,
            "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
            "home": 0x73, "end": 0x77, "pageup": 0x74, "pagedown": 0x79,
            "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60,
            "f6": 0x61, "f7": 0x62, "f8": 0x64, "f9": 0x65, "f10": 0x6D,
            "f11": 0x67, "f12": 0x6F
        ]
        if let code = specialKeyMap[keyName.lowercased()] { return code }

        // Letters and digits — only handle single-character names
        guard keyName.count == 1, let asciiValue = keyName.lowercased().first?.asciiValue else {
            return nil
        }
        let letterCodeMap: [Character: CGKeyCode] = [
            "a": 0x00, "b": 0x0B, "c": 0x08, "d": 0x02, "e": 0x0E,
            "f": 0x03, "g": 0x05, "h": 0x04, "i": 0x22, "j": 0x26,
            "k": 0x28, "l": 0x25, "m": 0x2E, "n": 0x2D, "o": 0x1F,
            "p": 0x23, "q": 0x0C, "r": 0x0F, "s": 0x01, "t": 0x11,
            "u": 0x20, "v": 0x09, "w": 0x0D, "x": 0x07, "y": 0x10, "z": 0x06
        ]
        let digitCodeMap: [Character: CGKeyCode] = [
            "0": 0x1D, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15,
            "5": 0x17, "6": 0x16, "7": 0x1A, "8": 0x1C, "9": 0x19
        ]
        let symbolCodeMap: [Character: CGKeyCode] = [
            "=": 0x18, "+": 0x18, "-": 0x1B
        ]
        let lowerCharacter = Character(UnicodeScalar(asciiValue))
        return letterCodeMap[lowerCharacter] ?? digitCodeMap[lowerCharacter] ?? symbolCodeMap[lowerCharacter]
    }

    // MARK: - Private

    private static func typeIntoFocusedAccessibleTextElement(_ stringToType: String) -> Bool {
        guard !stringToType.isEmpty else { return true }

        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedObject: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedObject
        ) == .success,
              let focusedElement = focusedObject else {
            return false
        }

        let focusedAXElement = focusedElement as! AXUIElement
        var roleObject: CFTypeRef?
        let role = (AXUIElementCopyAttributeValue(
            focusedAXElement,
            kAXRoleAttribute as CFString,
            &roleObject
        ) == .success) ? (roleObject as? String ?? "") : ""

        let textRoles: Set<String> = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXSearchFieldSubrole as String,
            "AXComboBox"
        ]
        guard textRoles.contains(role) || role.localizedCaseInsensitiveContains("text") else {
            return false
        }

        var valueObject: CFTypeRef?
        let existingValue = (AXUIElementCopyAttributeValue(
            focusedAXElement,
            kAXValueAttribute as CFString,
            &valueObject
        ) == .success) ? (valueObject as? String ?? "") : ""

        let existingNSString = existingValue as NSString
        var replacementRange = CFRange(location: existingNSString.length, length: 0)
        var selectedRangeObject: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            focusedAXElement,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRangeObject
        ) == .success,
           let selectedRangeObject {
            let selectedRangeAXValue = selectedRangeObject as! AXValue
            var selectedRange = CFRange()
            if AXValueGetValue(selectedRangeAXValue, .cfRange, &selectedRange),
               selectedRange.location >= 0,
               selectedRange.length >= 0,
               selectedRange.location + selectedRange.length <= existingNSString.length {
                replacementRange = selectedRange
            }
        }

        let updatedValue = existingNSString.replacingCharacters(
            in: NSRange(location: replacementRange.location, length: replacementRange.length),
            with: stringToType
        )
        let setResult = AXUIElementSetAttributeValue(
            focusedAXElement,
            kAXValueAttribute as CFString,
            updatedValue as CFString
        )
        guard setResult == .success else { return false }

        var newCursorRange = CFRange(
            location: replacementRange.location + (stringToType as NSString).length,
            length: 0
        )
        if let newCursorAXValue = AXValueCreate(.cfRange, &newCursorRange) {
            AXUIElementSetAttributeValue(
                focusedAXElement,
                kAXSelectedTextRangeAttribute as CFString,
                newCursorAXValue
            )
        }
        return true
    }

    private static func postMouseClick(at globalPoint: CGPoint,
                                       button: CGMouseButton,
                                       clickCount: Int64 = 1) {
        let downType: CGEventType = (button == .right) ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = (button == .right) ? .rightMouseUp : .leftMouseUp
        let downEvent = CGEvent(mouseEventSource: nil,
                                mouseType: downType,
                                mouseCursorPosition: globalPoint,
                                mouseButton: button)
        downEvent?.setIntegerValueField(.mouseEventClickState, value: clickCount)
        downEvent?.post(tap: .cghidEventTap)
        let upEvent = CGEvent(mouseEventSource: nil,
                              mouseType: upType,
                              mouseCursorPosition: globalPoint,
                              mouseButton: button)
        upEvent?.setIntegerValueField(.mouseEventClickState, value: clickCount)
        upEvent?.post(tap: .cghidEventTap)
    }
}
