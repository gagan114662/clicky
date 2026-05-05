import XCTest
@testable import ipop_ai

final class CGEventActionsTests: XCTestCase {
    func testParseSingleKeyName() {
        XCTAssertEqual(CGEventActions.virtualKeyCodeForName("Return"), CGKeyCode(0x24))
        XCTAssertEqual(CGEventActions.virtualKeyCodeForName("Tab"), CGKeyCode(0x30))
        XCTAssertEqual(CGEventActions.virtualKeyCodeForName("Escape"), CGKeyCode(0x35))
        XCTAssertEqual(CGEventActions.virtualKeyCodeForName("space"), CGKeyCode(0x31))
        XCTAssertEqual(CGEventActions.virtualKeyCodeForName("a"), CGKeyCode(0x00))
    }

    func testParseModifierComboFromKeyString() {
        // Anthropic computer-use sends key combos like "cmd+t" or "ctrl+shift+a"
        let parsed = CGEventActions.parseKeyComboString("cmd+shift+a")
        XCTAssertTrue(parsed.modifierFlags.contains(.maskCommand))
        XCTAssertTrue(parsed.modifierFlags.contains(.maskShift))
        XCTAssertEqual(parsed.virtualKeyCode, CGKeyCode(0x00))
    }

    func testParseKeyComboWithFunctionKeys() {
        let parsed = CGEventActions.parseKeyComboString("cmd+space")
        XCTAssertTrue(parsed.modifierFlags.contains(.maskCommand))
        XCTAssertEqual(parsed.virtualKeyCode, CGKeyCode(0x31))
    }

    func testUnknownKeyReturnsNil() {
        XCTAssertNil(CGEventActions.virtualKeyCodeForName("totally_made_up_key"))
    }

    func testCanPressKeyComboRejectsUnknownFinalKey() {
        XCTAssertTrue(CGEventActions.canPressKeyCombo("cmd+space"))
        XCTAssertTrue(CGEventActions.canPressKeyCombo("cmd + space"))
        XCTAssertFalse(CGEventActions.canPressKeyCombo("cmd+totally_made_up_key"))
    }
}
