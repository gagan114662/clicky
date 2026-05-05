import XCTest
@testable import ipop_ai

final class MemoryManagerTeacherFilteringTests: XCTestCase {
    func testTeacherMemoryFiltersSyntheticAndBusinessContext() {
        let rawMemory = """
        - User prefers visual explanations for math.
        - TeachMe probe asked Clicky to ask one checkpoint question.
        - Current GTM prospect list is in a spreadsheet.
        - User is confused by derivatives and likes tangent-line examples.
        """

        let lines = MemoryManager.sanitizedTeacherMemoryLines(from: rawMemory)

        XCTAssertTrue(lines.contains("- User prefers visual explanations for math."))
        XCTAssertTrue(lines.contains("- User is confused by derivatives and likes tangent-line examples."))
        XCTAssertFalse(lines.contains { $0.lowercased().contains("teachme") })
        XCTAssertFalse(lines.contains { $0.lowercased().contains("gtm") })
    }

    func testLearnerFactQuarantinesCodexAndProbePhrases() {
        XCTAssertFalse(MemoryManager.shouldSaveLearnerFact("TeachMe probe says the learner answered correctly."))
        XCTAssertFalse(MemoryManager.shouldSaveLearnerFact("Codex speaking synthetic QA found a lesson bug."))
        XCTAssertFalse(MemoryManager.shouldSaveLearnerFact("Possible mathematical vocabulary confusion: Student referenced numerator and denominator when discussing multiplication, suggesting mixing of fraction terminology."))
        XCTAssertFalse(MemoryManager.shouldSaveLearnerFact("Specific array counting error: student incorrectly assumes each row contains the same count as the total row count."))
        XCTAssertTrue(MemoryManager.shouldSaveLearnerFact("User needs fractions explained with shaded and unshaded parts visible."))
    }
}
