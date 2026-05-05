import XCTest
@testable import ipop_ai

final class AgentActionTagParserTests: XCTestCase {

    // MARK: - Mouse

    func testParsesClickWithCoordinates() {
        let actions = AgentActionTagParser.parse("I'll click the button. [CLICK 320,180]")
        XCTAssertEqual(actions, [.click(x: 320, y: 180)])
    }

    func testParsesClickToleratesSpacesAroundComma() {
        XCTAssertEqual(AgentActionTagParser.parse("[CLICK 100, 200]"), [.click(x: 100, y: 200)])
    }

    func testParsesDoubleClickAndRightClick() {
        let actions = AgentActionTagParser.parse("[DOUBLECLICK 50,50][RIGHTCLICK 60,60]")
        XCTAssertEqual(actions, [.doubleClick(x: 50, y: 50), .rightClick(x: 60, y: 60)])
    }

    func testParsesMouseMoveAndDrag() {
        let actions = AgentActionTagParser.parse("[MOUSE_MOVE 10,20][DRAG 10,20 90,120]")
        XCTAssertEqual(actions, [
            .mouseMove(x: 10, y: 20),
            .drag(startX: 10, startY: 20, endX: 90, endY: 120)
        ])
    }

    func testParsesNativeMacActions() {
        let actions = AgentActionTagParser.parse("[OPEN_APP \"Freeform\"][AX_CLICK \"File\"][CLOSE_WINDOW]")
        XCTAssertEqual(actions, [
            .openApp(name: "Freeform"),
            .accessibilityClick(name: "File"),
            .closeWindow
        ])
    }

    // MARK: - Type / Key

    func testParsesQuotedTypeText() {
        let actions = AgentActionTagParser.parse("[TYPE \"hello world\"]")
        XCTAssertEqual(actions, [.type(text: "hello world")])
    }

    func testParsesEscapedQuotesInTypeText() {
        let actions = AgentActionTagParser.parse("[TYPE \"she said \\\"hi\\\"\"]")
        XCTAssertEqual(actions, [.type(text: "she said \"hi\"")])
    }

    func testParsesUnquotedTypeText() {
        let actions = AgentActionTagParser.parse("[TYPE meeting notes]")
        XCTAssertEqual(actions, [.type(text: "meeting notes")])
    }

    func testParsesKeyCombo() {
        XCTAssertEqual(AgentActionTagParser.parse("[KEY cmd+t]"), [.key(combo: "cmd+t")])
        XCTAssertEqual(AgentActionTagParser.parse("[KEY return]"), [.key(combo: "return")])
    }

    // MARK: - Scroll / Wait / Screenshot / Done

    func testParsesScrollUpAndDown() {
        XCTAssertEqual(AgentActionTagParser.parse("[SCROLL down 5]"),
                       [.scroll(direction: .down, amount: 5)])
        XCTAssertEqual(AgentActionTagParser.parse("[SCROLL up 2]"),
                       [.scroll(direction: .up, amount: 2)])
    }

    func testParsesScrollDefaultsAmountTo3WhenMissing() {
        XCTAssertEqual(AgentActionTagParser.parse("[SCROLL down]"),
                       [.scroll(direction: .down, amount: 3)])
    }

    func testParsesWaitMilliseconds() {
        XCTAssertEqual(AgentActionTagParser.parse("[WAIT 750]"), [.wait(milliseconds: 750)])
    }

    func testParsesScreenshotNoArgs() {
        XCTAssertEqual(AgentActionTagParser.parse("[SCREENSHOT]"), [.screenshot])
    }

    func testParsesDoneWithFinalMessage() {
        XCTAssertEqual(AgentActionTagParser.parse("Calculator opened. [DONE Calculator is now open]"),
                       [.done(finalMessage: "Calculator is now open")])
    }

    func testStopsAtDoneEvenIfMoreTagsFollow() {
        let actions = AgentActionTagParser.parse("[CLICK 1,2][DONE all set][CLICK 3,4]")
        XCTAssertEqual(actions, [.click(x: 1, y: 2), .done(finalMessage: "all set")])
    }

    // MARK: - Bash / file editor

    func testParsesBashCommand() {
        XCTAssertEqual(AgentActionTagParser.parse("[BASH \"ls -la /tmp\"]"),
                       [.bash(command: "ls -la /tmp")])
    }

    func testParsesFileViewPath() {
        XCTAssertEqual(AgentActionTagParser.parse("[FILE_VIEW /tmp/notes.txt]"),
                       [.fileView(path: "/tmp/notes.txt")])
    }

    func testParsesFileCreatePathAndContents() {
        let actions = AgentActionTagParser.parse("[FILE_CREATE /tmp/x.txt \"hello\\nworld\"]")
        XCTAssertEqual(actions, [.fileCreate(path: "/tmp/x.txt", contents: "hello\nworld")])
    }

    func testParsesFileReplaceTwoQuotedStrings() {
        let actions = AgentActionTagParser.parse("[FILE_REPLACE /tmp/x.txt \"hello\" \"goodbye\"]")
        XCTAssertEqual(actions, [.fileReplace(path: "/tmp/x.txt", oldString: "hello", newString: "goodbye")])
    }

    func testIgnoresFileReplaceMissingNewString() {
        let actions = AgentActionTagParser.parse("[FILE_REPLACE /tmp/x.txt \"hello\"]")
        XCTAssertEqual(actions, [])
    }

    func testParsesFileReplaceEscapedQuotes() {
        let actions = AgentActionTagParser.parse("[FILE_REPLACE /tmp/x.txt \"say \\\"hi\\\"\" \"say \\\"bye\\\"\"]")
        XCTAssertEqual(actions, [.fileReplace(path: "/tmp/x.txt",
                                              oldString: "say \"hi\"",
                                              newString: "say \"bye\"")])
    }

    func testParsesUpworkPreworkProof() {
        let actions = AgentActionTagParser.parse("[UPWORK_PREWORK_PROOF \"Inspected visible public URL and reproduced the console error; proof artifact is a diagnostic note.\"]")
        XCTAssertEqual(actions, [
            .upworkPreworkProof(summary: "Inspected visible public URL and reproduced the console error; proof artifact is a diagnostic note.")
        ])
    }

    // MARK: - Robustness

    func testIgnoresPlainTextOutsideTags() {
        let actions = AgentActionTagParser.parse("Let me think about this. The button is on the right. [CLICK 800,400] After that, [TYPE \"submit\"]")
        XCTAssertEqual(actions, [.click(x: 800, y: 400), .type(text: "submit")])
    }

    func testIgnoresUnknownTags() {
        let actions = AgentActionTagParser.parse("[CLICK 1,1][SOMETHING WEIRD][TYPE \"ok\"]")
        XCTAssertEqual(actions, [.click(x: 1, y: 1), .type(text: "ok")])
    }

    func testIgnoresMalformedClick() {
        let actions = AgentActionTagParser.parse("[CLICK abc][CLICK 1,2]")
        XCTAssertEqual(actions, [.click(x: 1, y: 2)])
    }

    func testHandlesBracketsInsideQuotedTypeText() {
        let actions = AgentActionTagParser.parse("[TYPE \"array[0]\"]")
        XCTAssertEqual(actions, [.type(text: "array[0]")])
    }
}
