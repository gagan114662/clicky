import XCTest
@testable import ipop_ai

@MainActor
final class CompanionManagerSafetyTests: XCTestCase {
    func testNotesDraftTranscriptRequiresConfirmationForCompanionActions() {
        let requiresConfirmation = CompanionManager.companionActionTagsRequireConfirmation(
            transcript: "Open Notes and draft a note called Pasta plan with three ingredients.",
            actions: [
                .launchOrActivateApp(name: "Notes"),
                .pressKeyChord(chord: "cmd+n"),
                .typeText(text: "Pasta plan\n\nIngredients:\n1. \n2. \n3.")
            ]
        )

        XCTAssertTrue(requiresConfirmation)
    }

    func testOpenNotesAndTypeShapeRequiresConfirmationEvenWithoutRiskyTranscript() {
        let requiresConfirmation = CompanionManager.companionActionTagsRequireConfirmation(
            transcript: "Put this somewhere for later.",
            actions: [
                .launchOrActivateApp(name: "Notes"),
                .typeText(text: "Remember the pricing idea.")
            ]
        )

        XCTAssertTrue(requiresConfirmation)
    }

    func testPlainCalculatorActionsStayAuto() {
        let requiresConfirmation = CompanionManager.companionActionTagsRequireConfirmation(
            transcript: "Open Calculator and show me 17 times 24.",
            actions: [
                .calculateInCalculator(expression: "17*24")
            ]
        )

        XCTAssertFalse(requiresConfirmation)
        XCTAssertNil(CompanionManager.companionActionSequenceSafetyDecision(
            for: .calculateInCalculator(expression: "17*24"),
            requiresConfirmation: requiresConfirmation
        ))
    }

    func testMissionRequiredTypeAndNewDocumentKeyAreConfirmRequired() {
        let typeDecision = CompanionManager.companionActionSequenceSafetyDecision(
            for: .typeText(text: "Pasta plan"),
            requiresConfirmation: true
        )
        let newDocumentDecision = CompanionManager.companionActionSequenceSafetyDecision(
            for: .pressKeyChord(chord: "command+n"),
            requiresConfirmation: true
        )

        if case .confirmRequired(let reason) = typeDecision {
            XCTAssertTrue(reason.lowercased().contains("persistent"))
        } else {
            XCTFail("Expected type action to require confirmation, got \(String(describing: typeDecision))")
        }
        if case .confirmRequired(let reason) = newDocumentDecision {
            XCTAssertTrue(reason.lowercased().contains("creating"))
        } else {
            XCTFail("Expected cmd+n to require confirmation, got \(String(describing: newDocumentDecision))")
        }
    }

    func testMissionRequiredReturnKeysAreConfirmRequired() {
        for chord in ["return", "cmd+return", "command+return"] {
            let decision = CompanionManager.companionActionSequenceSafetyDecision(
                for: .pressKeyChord(chord: chord),
                requiresConfirmation: true
            )
            if case .confirmRequired = decision {
                continue
            }
            XCTFail("Expected \(chord) to require confirmation, got \(String(describing: decision))")
        }
    }

    func testSynthesizedClickBlockUsesClassifierForSendTarget() {
        let block = CompanionManager.synthesizedToolUseBlock(
            forCompanionAction: .clickByName(targetName: "Send")
        )

        XCTAssertEqual(block.toolName, "computer")
        XCTAssertEqual(block.inputJSON["action"] as? String, "ax_click")
        XCTAssertEqual(block.inputJSON["text"] as? String, "Send")
        if case .confirmRequired = AgentSafetyClassifier.classify(toolUseBlock: block) {
            return
        }
        XCTFail("Expected synthesized Send click to require confirmation")
    }

    func testSpokenTextDeduplicatesSafetyMessages() {
        let spokenText = CompanionManager.spokenText(
            "The note is ready.",
            appendingSafetyMessages: [
                "i need your confirmation before i do that.",
                "i need your confirmation before i do that."
            ]
        )

        XCTAssertEqual(spokenText, "The note is ready. i need your confirmation before i do that.")
    }
}
