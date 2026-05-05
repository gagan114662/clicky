import XCTest
@testable import ipop_ai

final class AgentSafetyClassifierTests: XCTestCase {
    func testInnocuousMouseMoveIsAuto() {
        let block = ParsedToolUseBlock(toolUseId: "x", toolName: "computer",
                                       inputJSON: ["action": "mouse_move", "coordinate": [100, 200]])
        XCTAssertEqual(AgentSafetyClassifier.classify(toolUseBlock: block), .auto)
    }

    func testRmRfIsBlocked() {
        let block = ParsedToolUseBlock(toolUseId: "x", toolName: "bash",
                                       inputJSON: ["command": "rm -rf /Users/me/Important"])
        let decision = AgentSafetyClassifier.classify(toolUseBlock: block)
        if case .blocked = decision { return }
        XCTFail("Expected .blocked, got \(decision)")
    }

    func testPlainRmRequiresConfirmation() {
        let block = ParsedToolUseBlock(toolUseId: "x", toolName: "bash",
                                       inputJSON: ["command": "rm /tmp/clicky-rm.txt"])
        let decision = AgentSafetyClassifier.classify(toolUseBlock: block)
        if case .confirmRequired = decision { return }
        XCTFail("Expected .confirmRequired, got \(decision)")
    }

    func testSudoPlainRmRequiresConfirmation() {
        let block = ParsedToolUseBlock(toolUseId: "x", toolName: "bash",
                                       inputJSON: ["command": "sudo rm /tmp/clicky-rm.txt"])
        let decision = AgentSafetyClassifier.classify(toolUseBlock: block)
        if case .confirmRequired = decision { return }
        XCTFail("Expected .confirmRequired, got \(decision)")
    }

    func testPlainRmAfterShellSeparatorRequiresConfirmation() {
        let block = ParsedToolUseBlock(toolUseId: "x", toolName: "bash",
                                       inputJSON: ["command": "echo ok\nrm /tmp/clicky-rm.txt"])
        let decision = AgentSafetyClassifier.classify(toolUseBlock: block)
        if case .confirmRequired = decision { return }
        XCTFail("Expected .confirmRequired, got \(decision)")
    }

    func testGitPushForceRequiresConfirmation() {
        let block = ParsedToolUseBlock(toolUseId: "x", toolName: "bash",
                                       inputJSON: ["command": "git push --force origin main"])
        let decision = AgentSafetyClassifier.classify(toolUseBlock: block)
        if case .confirmRequired = decision { return }
        XCTFail("Expected .confirmRequired, got \(decision)")
    }

    func testTypingPlainTextIsAuto() {
        let block = ParsedToolUseBlock(toolUseId: "x", toolName: "computer",
                                       inputJSON: ["action": "type", "text": "hello world"])
        XCTAssertEqual(AgentSafetyClassifier.classify(toolUseBlock: block), .auto)
    }

    func testReturnAfterTypingRequiresConfirmation() {
        let typedBlock = ParsedToolUseBlock(toolUseId: "typed", toolName: "computer",
                                            inputJSON: ["action": "type", "text": "I am testing iPOP"])
        let returnBlock = ParsedToolUseBlock(toolUseId: "key", toolName: "computer",
                                             inputJSON: ["action": "key", "text": "return"])

        let decision = AgentSafetyClassifier.classify(
            toolUseBlock: returnBlock,
            previousToolUseBlock: typedBlock
        )

        if case .confirmRequired(let reason) = decision {
            XCTAssertTrue(reason.lowercased().contains("typed content"))
            return
        }
        XCTFail("Expected .confirmRequired, got \(decision)")
    }

    func testCommandReturnAfterTypingRequiresConfirmation() {
        let typedBlock = ParsedToolUseBlock(toolUseId: "typed", toolName: "computer",
                                            inputJSON: ["action": "type", "text": "Proposal draft"])
        let returnBlock = ParsedToolUseBlock(toolUseId: "key", toolName: "computer",
                                             inputJSON: ["action": "key", "text": "command+enter"])

        let decision = AgentSafetyClassifier.classify(
            toolUseBlock: returnBlock,
            previousToolUseBlock: typedBlock
        )

        if case .confirmRequired = decision { return }
        XCTFail("Expected .confirmRequired, got \(decision)")
    }

    func testMissionRequiresConfirmationGatesReturnKey() {
        let block = ParsedToolUseBlock(toolUseId: "x", toolName: "computer",
                                       inputJSON: ["action": "key", "text": "return"])

        let decision = AgentSafetyClassifier.classify(
            toolUseBlock: block,
            missionRequiresConfirmation: true
        )

        if case .confirmRequired = decision { return }
        XCTFail("Expected .confirmRequired, got \(decision)")
    }

    func testMissionRequiresConfirmationGatesPixelClick() {
        let block = ParsedToolUseBlock(toolUseId: "x", toolName: "computer",
                                       inputJSON: ["action": "left_click", "coordinate": [500, 300]])

        let decision = AgentSafetyClassifier.classify(
            toolUseBlock: block,
            missionRequiresConfirmation: true
        )

        if case .confirmRequired = decision { return }
        XCTFail("Expected .confirmRequired, got \(decision)")
    }

    func testYoloCannotBypassTypedSubmitConfirmation() {
        let block = ParsedToolUseBlock(toolUseId: "x", toolName: "computer",
                                       inputJSON: ["action": "key", "text": "return"])
        let decision = AgentSafetyDecision.confirmRequired(reason: "Typed content followed by a submit key")

        XCTAssertFalse(AgentSafetyClassifier.yoloCanBypassConfirmation(toolUseBlock: block, decision: decision))
    }

    func testYoloCannotBypassShellConfirmation() {
        let block = ParsedToolUseBlock(toolUseId: "x", toolName: "bash",
                                       inputJSON: ["command": "osascript -e 'display dialog \"hi\"'"])
        let decision = AgentSafetyDecision.confirmRequired(reason: "Risky shell op: osascript")

        XCTAssertFalse(AgentSafetyClassifier.yoloCanBypassConfirmation(toolUseBlock: block, decision: decision))
    }

    func testOsascriptRequiresConfirmation() {
        let block = ParsedToolUseBlock(toolUseId: "x", toolName: "bash",
                                       inputJSON: ["command": "osascript -e 'tell application \"Mail\" to activate'"])
        let decision = AgentSafetyClassifier.classify(toolUseBlock: block)
        if case .confirmRequired = decision { return }
        XCTFail("Expected .confirmRequired, got \(decision)")
    }

    func testCurlPostRequiresConfirmation() {
        let block = ParsedToolUseBlock(toolUseId: "x", toolName: "bash",
                                       inputJSON: ["command": "curl -X POST https://example.com/hook -d '{\"ok\":true}'"])
        let decision = AgentSafetyClassifier.classify(toolUseBlock: block)
        if case .confirmRequired = decision { return }
        XCTFail("Expected .confirmRequired, got \(decision)")
    }

    func testCurlCompactPostRequiresConfirmation() {
        let block = ParsedToolUseBlock(toolUseId: "x", toolName: "bash",
                                       inputJSON: ["command": "curl -XPOST https://example.com/hook"])
        let decision = AgentSafetyClassifier.classify(toolUseBlock: block)
        if case .confirmRequired = decision { return }
        XCTFail("Expected .confirmRequired, got \(decision)")
    }

    func testNamedDestructiveClickRequiresConfirmation() {
        let block = ParsedToolUseBlock(toolUseId: "x", toolName: "computer",
                                       inputJSON: ["action": "ax_click", "text": "Delete message"])
        let decision = AgentSafetyClassifier.classify(toolUseBlock: block)
        if case .confirmRequired = decision { return }
        XCTFail("Expected .confirmRequired, got \(decision)")
    }

    func testSendClickRequiresConfirmationForCompanionActionTags() {
        let block = ParsedToolUseBlock(toolUseId: "x", toolName: "computer",
                                       inputJSON: ["action": "ax_click", "text": "Send"])
        let decision = AgentSafetyClassifier.classify(toolUseBlock: block)
        if case .confirmRequired = decision { return }
        XCTFail("Expected .confirmRequired, got \(decision)")
    }

    func testUpworkStandingApprovalRequiresPreworkProofBeforeNamedSubmitProposalClick() {
        let block = ParsedToolUseBlock(toolUseId: "x", toolName: "computer",
                                       inputJSON: ["action": "ax_click", "text": "Submit Proposal"])

        let decision = AgentSafetyClassifier.classify(
            toolUseBlock: block,
            upworkStandingSubmissionApproval: true
        )

        if case .blocked(let reason) = decision {
            XCTAssertTrue(reason.lowercased().contains("pre-application proof"))
            return
        }
        XCTFail("Expected .blocked, got \(decision)")
    }

    func testUpworkStandingApprovalAllowsNamedSubmitProposalClickAfterPreworkProof() {
        let block = ParsedToolUseBlock(toolUseId: "x", toolName: "computer",
                                       inputJSON: ["action": "ax_click", "text": "Submit Proposal"])

        let decision = AgentSafetyClassifier.classify(
            toolUseBlock: block,
            upworkStandingSubmissionApproval: true,
            upworkPreworkArtifactReady: true
        )

        XCTAssertEqual(decision, .auto)
    }

    func testUpworkStandingApprovalDoesNotAllowBoostClick() {
        let block = ParsedToolUseBlock(toolUseId: "x", toolName: "computer",
                                       inputJSON: ["action": "ax_click", "text": "Boost my proposal"])

        let decision = AgentSafetyClassifier.classify(
            toolUseBlock: block,
            upworkStandingSubmissionApproval: true
        )

        if case .confirmRequired = decision { return }
        XCTFail("Expected .confirmRequired, got \(decision)")
    }

    func testCloseWindowRequiresConfirmationForAgentPath() {
        let block = ParsedToolUseBlock(toolUseId: "x", toolName: "computer",
                                       inputJSON: ["action": "close_window"])
        let decision = AgentSafetyClassifier.classify(toolUseBlock: block)
        if case .confirmRequired = decision { return }
        XCTFail("Expected .confirmRequired, got \(decision)")
    }

    func testRiskyKeyComboRequiresConfirmation() {
        let block = ParsedToolUseBlock(toolUseId: "x", toolName: "computer",
                                       inputJSON: ["action": "key", "text": "command+q"])
        let decision = AgentSafetyClassifier.classify(toolUseBlock: block)
        if case .confirmRequired = decision { return }
        XCTFail("Expected .confirmRequired, got \(decision)")
    }

    func testOpenAppIsAuto() {
        let block = ParsedToolUseBlock(toolUseId: "x", toolName: "computer",
                                       inputJSON: ["action": "open_app", "text": "Calculator"])
        XCTAssertEqual(AgentSafetyClassifier.classify(toolUseBlock: block), .auto)
    }
}
