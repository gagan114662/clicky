import XCTest
@testable import ipop_ai

@MainActor
final class TeacherTurnValidatorTests: XCTestCase {
    func testFlagsScriptedLectureWithoutVisualAnchor() {
        let context = LearningAssetContext(
            assetType: .whiteboard,
            frontmostAppName: "Freeform",
            candidateTopic: "fractions",
            browserTitle: nil,
            browserURL: nil,
            selectedFilePaths: [],
            selectedFilePreview: nil,
            screenContextLines: ["user's screen (cursor is here), image 1280x720 pixels"]
        )
        let lesson = TeacherModeController().beginOrUpdateLesson(
            transcript: "I don't get numerator and denominator",
            assetContext: context
        )
        let move = TeachingMove(
            spokenResponse: "Lesson objective: let's break it down. checkpoint question: what is the correct answer?",
            pointTarget: "none",
            question: nil
        )

        let flags = TeacherTurnValidator.flags(for: move, lesson: lesson, assetContext: context)

        XCTAssertTrue(flags.contains(.scriptedPhrase))
        XCTAssertTrue(flags.contains(.missingVisualAnchor))
    }

    func testRepairsScriptedTurnIntoNaturalVisualMove() {
        let context = LearningAssetContext(
            assetType: .whiteboard,
            frontmostAppName: "Freeform",
            candidateTopic: "multiplication",
            browserTitle: nil,
            browserURL: nil,
            selectedFilePaths: [],
            selectedFilePreview: nil,
            screenContextLines: ["user's screen (cursor is here), image 1280x720 pixels"]
        )
        let lesson = TeacherModeController().beginOrUpdateLesson(
            transcript: "teach multiplication",
            assetContext: context,
            preparedLearningSurfaceContext: FreeformDiagramSpec(
                kind: .multiplicationArray,
                title: "Multiplication as an array"
            ).promptContext
        )
        let move = TeachingMove(
            spokenResponse: "Checkpoint question: this concept is important.",
            surfaceAction: .prepareFreeformDiagram(
                FreeformDiagramSpec(kind: .multiplicationArray, title: "Multiplication as an array")
            ),
            pointTarget: "none"
        )

        let repaired = TeacherTurnValidator.repairedMove(move, lesson: lesson, assetContext: context)

        XCTAssertFalse(repaired.combinedSpokenText.lowercased().contains("checkpoint question"))
        XCTAssertFalse(repaired.visualAnchor.isEmpty)
        XCTAssertTrue(repaired.studentMove?.lowercased().contains("row") == true)
    }
}
