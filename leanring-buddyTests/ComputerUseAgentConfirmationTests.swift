import XCTest
@testable import ipop_ai

@MainActor
final class ComputerUseAgentConfirmationTests: XCTestCase {
    func testStaleConfirmationCannotClearCurrentPendingAction() {
        let manager = CompanionManager()
        let agent = manager.computerUseAgent
        let activeConfirmation = ComputerUseAgent.PendingConfirmation(
            turnID: UUID(),
            pendingAction: .click(x: 10, y: 20),
            humanReadableSummary: "Click at 10,20"
        )

        agent.pendingConfirmation = activeConfirmation
        agent.resolvePendingConfirmation(id: UUID(), approved: true)

        XCTAssertEqual(agent.pendingConfirmation, activeConfirmation)
    }

    func testEditedConfirmationClearsCurrentPendingAction() {
        let manager = CompanionManager()
        let agent = manager.computerUseAgent
        let activeConfirmation = ComputerUseAgent.PendingConfirmation(
            turnID: UUID(),
            pendingAction: .accessibilityClick(name: "Submit Proposal"),
            humanReadableSummary: "Submit Proposal"
        )

        agent.pendingConfirmation = activeConfirmation
        agent.resolvePendingConfirmation(
            id: activeConfirmation.id,
            editInstruction: "Use the proposal draft but ask one clarifying question first."
        )

        XCTAssertNil(agent.pendingConfirmation)
    }

    func testEmptyEditedConfirmationDoesNotClearCurrentPendingAction() {
        let manager = CompanionManager()
        let agent = manager.computerUseAgent
        let activeConfirmation = ComputerUseAgent.PendingConfirmation(
            turnID: UUID(),
            pendingAction: .accessibilityClick(name: "Submit Proposal"),
            humanReadableSummary: "Submit Proposal"
        )

        agent.pendingConfirmation = activeConfirmation
        agent.resolvePendingConfirmation(id: activeConfirmation.id, editInstruction: "   ")

        XCTAssertEqual(agent.pendingConfirmation, activeConfirmation)
    }
}
