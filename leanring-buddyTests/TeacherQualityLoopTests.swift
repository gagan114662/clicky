import XCTest
@testable import ipop_ai

@MainActor
final class TeacherQualityLoopTests: XCTestCase {
    func testRefinesGenericMoveIntoAhaAndSpecificLearnerMove() {
        let context = LearningAssetContext(
            assetType: .whiteboard,
            frontmostAppName: "Freeform",
            candidateTopic: "multiplication",
            browserTitle: nil,
            browserURL: nil,
            selectedFilePaths: [],
            selectedFilePreview: nil,
            screenContextLines: []
        )
        let controller = TeacherModeController()
        let lesson = controller.beginOrUpdateLesson(
            transcript: "teach multiplication",
            assetContext: context,
            preparedLearningSurfaceContext: FreeformDiagramSpec(
                kind: .multiplicationArray,
                title: "Multiplication as an array"
            ).promptContext
        )
        let move = TeachingMove(spokenResponse: "Multiplication means repeated addition.")

        let refined = TeacherQualityLoop.refinedMove(move, lesson: lesson, assetContext: context)

        XCTAssertTrue(refined.combinedSpokenText.lowercased().contains("aha"))
        XCTAssertTrue(refined.combinedSpokenText.lowercased().contains("row"))
        XCTAssertEqual(
            refined.studentMove,
            "Cover every row except the top one in your mind: how many dots are in that one row?"
        )
        XCTAssertFalse(refined.learnerGap.isEmpty)
    }

    func testConfusionSwitchesExplanationStyle() {
        let context = LearningAssetContext(
            assetType: .whiteboard,
            frontmostAppName: "Freeform",
            candidateTopic: "fractions",
            browserTitle: nil,
            browserURL: nil,
            selectedFilePaths: [],
            selectedFilePreview: nil,
            screenContextLines: []
        )
        let controller = TeacherModeController()
        _ = controller.beginOrUpdateLesson(
            transcript: "teach fractions",
            assetContext: context,
            preparedLearningSurfaceContext: FreeformDiagramSpec(
                kind: .fractionBar,
                title: "Fractions as equal parts"
            ).promptContext
        )
        _ = controller.completeTurn(
            userTranscript: "teach fractions",
            assistantResponse: "Look at the bar. What does the denominator name?",
            teachingMove: TeachingMove(
                spokenResponse: "Look at the bar.",
                question: "What does the denominator name?"
            )
        )
        let confusedLesson = controller.beginOrUpdateLesson(
            transcript: "I still do not get it, I am lost",
            assetContext: context
        )
        let repeatedMove = TeachingMove(
            learnerGap: "",
            spokenResponse: "The denominator is the bottom number.",
            question: "What is the denominator?"
        )

        let refined = TeacherQualityLoop.refinedMove(repeatedMove, lesson: confusedLesson, assetContext: context)

        XCTAssertTrue(refined.combinedSpokenText.lowercased().contains("switch moves"))
        XCTAssertTrue(refined.combinedSpokenText.lowercased().contains("empty space"))
        XCTAssertTrue(refined.learnerGap.lowercased().contains("shaded"))
    }

    func testMasteryRisesAndArcTransfersAfterCorrectAnswer() {
        let context = LearningAssetContext(
            assetType: .whiteboard,
            frontmostAppName: "Freeform",
            candidateTopic: "multiplication",
            browserTitle: nil,
            browserURL: nil,
            selectedFilePaths: [],
            selectedFilePreview: nil,
            screenContextLines: []
        )
        let controller = TeacherModeController()
        let lesson = controller.beginOrUpdateLesson(
            transcript: "teach multiplication",
            assetContext: context,
            preparedLearningSurfaceContext: FreeformDiagramSpec(
                kind: .multiplicationArray,
                title: "Multiplication as an array"
            ).promptContext
        )
        var lessonReadyForTransfer = lesson
        lessonReadyForTransfer.phase = .evaluatingAnswer
        lessonReadyForTransfer.mastery.confidence = 60
        let move = TeachingMove(
            spokenResponse: "Yes. Five rows with six dots gives 30.",
            question: "What would happen if it were 6 rows of 5?",
            memoryCandidate: "User can read a multiplication array."
        )

        let refined = TeacherQualityLoop.refinedMove(
            move,
            lesson: lessonReadyForTransfer,
            assetContext: context
        )
        let mastery = TeacherQualityLoop.updatedMasteryState(
            lesson: lessonReadyForTransfer,
            userTranscript: "5 times 6 equals 30 because each row has 6",
            teachingMove: refined
        )
        let arc = TeacherQualityLoop.updatedArcState(
            lesson: lessonReadyForTransfer,
            teachingMove: refined
        )

        XCTAssertGreaterThan(mastery.confidence, 60)
        XCTAssertEqual(arc.step, .transfer)
        XCTAssertTrue(refined.question?.lowercased().contains("would the total change") == true)
    }

    func testSpecificWrongAnswerGetsSpecificRepair() {
        let context = LearningAssetContext(
            assetType: .whiteboard,
            frontmostAppName: "Freeform",
            candidateTopic: "multiplication",
            browserTitle: nil,
            browserURL: nil,
            selectedFilePaths: [],
            selectedFilePreview: nil,
            screenContextLines: []
        )
        let controller = TeacherModeController()
        _ = controller.beginOrUpdateLesson(
            transcript: "teach multiplication",
            assetContext: context,
            preparedLearningSurfaceContext: FreeformDiagramSpec(
                kind: .multiplicationArray,
                title: "Multiplication as an array"
            ).promptContext
        )
        _ = controller.completeTurn(
            userTranscript: "teach multiplication",
            assistantResponse: "Look at the green array. What total does it make?",
            teachingMove: TeachingMove(
                spokenResponse: "Look at the green array.",
                question: "What total does it make?"
            )
        )
        let lessonAfterWrongAnswer = controller.beginOrUpdateLesson(
            transcript: "25",
            assetContext: context
        )
        let weakRepair = TeachingMove(
            spokenResponse: "Try again.",
            question: "What is the answer?"
        )

        let refined = TeacherQualityLoop.refinedMove(
            weakRepair,
            lesson: lessonAfterWrongAnswer,
            assetContext: context
        )

        XCTAssertTrue(refined.learnerGap.lowercased().contains("number of groups"))
        XCTAssertTrue(refined.question?.lowercased().contains("top row") == true)
        XCTAssertEqual(
            LearningExperienceDesigner.brief(for: lessonAfterWrongAnswer, assetContext: context).mode,
            .misconceptionLab
        )
    }

    func testTutorPraiseAloneDoesNotInflateMastery() {
        let context = LearningAssetContext(
            assetType: .whiteboard,
            frontmostAppName: "Freeform",
            candidateTopic: "multiplication",
            browserTitle: nil,
            browserURL: nil,
            selectedFilePaths: [],
            selectedFilePreview: nil,
            screenContextLines: []
        )
        let controller = TeacherModeController()
        let lesson = controller.beginOrUpdateLesson(
            transcript: "teach multiplication",
            assetContext: context,
            preparedLearningSurfaceContext: FreeformDiagramSpec(
                kind: .multiplicationArray,
                title: "Multiplication as an array"
            ).promptContext
        )
        var answerTurn = lesson
        answerTurn.phase = .evaluatingAnswer
        answerTurn.mastery.confidence = 40
        let move = TeachingMove(
            spokenResponse: "Exactly. Correct. That's the move.",
            question: "What is the total?"
        )

        let mastery = TeacherQualityLoop.updatedMasteryState(
            lesson: answerTurn,
            userTranscript: "I don't get it",
            teachingMove: move
        )

        XCTAssertLessThan(mastery.confidence, 40)
    }

    func testHighMasteryMovesToTeachBack() {
        let context = LearningAssetContext(
            assetType: .whiteboard,
            frontmostAppName: "Freeform",
            candidateTopic: "derivatives",
            browserTitle: nil,
            browserURL: nil,
            selectedFilePaths: [],
            selectedFilePreview: nil,
            screenContextLines: []
        )
        let controller = TeacherModeController()
        let lesson = controller.beginOrUpdateLesson(
            transcript: "teach derivatives visually",
            assetContext: context,
            preparedLearningSurfaceContext: FreeformDiagramSpec(
                kind: .derivativeSlope,
                title: "Derivative intuition"
            ).promptContext
        )
        var highMasteryLesson = lesson
        highMasteryLesson.phase = .evaluatingAnswer
        highMasteryLesson.mastery.confidence = 86
        let move = TeachingMove(
            spokenResponse: "Yes, the tangent line slopes upward.",
            question: "What does that sign mean?"
        )

        let refined = TeacherQualityLoop.refinedMove(
            move,
            lesson: highMasteryLesson,
            assetContext: context
        )
        let arc = TeacherQualityLoop.updatedArcState(
            lesson: highMasteryLesson,
            teachingMove: refined
        )

        XCTAssertEqual(arc.step, .teachBack)
        XCTAssertTrue(refined.question?.lowercased().contains("say it back") == true)
    }

    func testCurriculumPlanTurnsConfusionIntoRepairArc() {
        let context = LearningAssetContext(
            assetType: .whiteboard,
            frontmostAppName: "Freeform",
            candidateTopic: "fractions",
            browserTitle: nil,
            browserURL: nil,
            selectedFilePaths: [],
            selectedFilePreview: nil,
            screenContextLines: []
        )
        let controller = TeacherModeController()
        _ = controller.beginOrUpdateLesson(
            transcript: "teach fractions",
            assetContext: context,
            preparedLearningSurfaceContext: FreeformDiagramSpec(
                kind: .fractionBar,
                title: "Fractions as equal parts"
            ).promptContext
        )
        var confusedLesson = controller.beginOrUpdateLesson(
            transcript: "I still do not get why the empty parts count",
            assetContext: context
        )
        confusedLesson.arcState.lastExplanationStyle = .concrete

        let plan = TeacherQualityLoop.curriculumPlan(for: confusedLesson)

        XCTAssertEqual(plan.currentMilestone, "repair the smallest misconception with a changed explanation style")
        XCTAssertTrue(plan.diagnosticQuestion.lowercased().contains("unshaded"))
        XCTAssertTrue(plan.upcomingMilestones.contains("transfer the idea to a nearby example"))
        XCTAssertTrue(plan.repetitionPlan.lowercased().contains("change style"))
    }

    func testExperienceDesignerPinsVisibleMoveOnWhiteboard() {
        let context = LearningAssetContext(
            assetType: .whiteboard,
            frontmostAppName: "Freeform",
            candidateTopic: "multiplication",
            browserTitle: nil,
            browserURL: nil,
            selectedFilePaths: [],
            selectedFilePreview: nil,
            screenContextLines: []
        )
        let controller = TeacherModeController()
        let lesson = controller.beginOrUpdateLesson(
            transcript: "teach multiplication",
            assetContext: context,
            preparedLearningSurfaceContext: FreeformDiagramSpec(
                kind: .multiplicationArray,
                title: "Multiplication as an array"
            ).promptContext
        )
        let move = TeachingMove(
            spokenResponse: "Look at one row first.",
            question: "How many dots are in that top row?"
        )

        let refined = LearningExperienceDesigner.refinedMove(
            move,
            lesson: lesson,
            assetContext: context
        )

        if case .writeFreeformText(let noteText) = refined.surfaceAction {
            XCTAssertTrue(noteText.contains("Try:"))
            XCTAssertTrue(noteText.contains("top row"))
        } else {
            XCTFail("expected a visible board note, got \(String(describing: refined.surfaceAction))")
        }
        XCTAssertTrue(refined.nextMove?.contains("experience:livingModel") == true)
    }

    func testPresenceEngineTurnsWrongAnswerIntoLiveDiagnosis() {
        let context = LearningAssetContext(
            assetType: .whiteboard,
            frontmostAppName: "Freeform",
            candidateTopic: "multiplication",
            browserTitle: nil,
            browserURL: nil,
            selectedFilePaths: [],
            selectedFilePreview: nil,
            screenContextLines: []
        )
        let controller = TeacherModeController()
        _ = controller.beginOrUpdateLesson(
            transcript: "teach multiplication",
            assetContext: context,
            preparedLearningSurfaceContext: FreeformDiagramSpec(
                kind: .multiplicationArray,
                title: "Multiplication as an array"
            ).promptContext
        )
        _ = controller.completeTurn(
            userTranscript: "teach multiplication",
            assistantResponse: "What total does the green array make?",
            teachingMove: TeachingMove(
                spokenResponse: "Look at the green array.",
                question: "What total does the green array make?"
            )
        )
        let wrongLesson = controller.beginOrUpdateLesson(
            transcript: "25",
            assetContext: context
        )
        let qualityMove = TeacherQualityLoop.refinedMove(
            TeacherTurnValidator.repairedMove(
                TeachingMove(spokenResponse: "Try again.", question: "What is the answer?"),
                lesson: wrongLesson,
                assetContext: context
            ),
            lesson: wrongLesson,
            assetContext: context
        )
        let experienceMove = LearningExperienceDesigner.refinedMove(
            qualityMove,
            lesson: wrongLesson,
            assetContext: context
        )

        let presenceMove = LearningPresenceEngine.refinedMove(
            experienceMove,
            transcript: "25",
            lesson: wrongLesson,
            assetContext: context
        )

        XCTAssertTrue(presenceMove.combinedSpokenText.contains("That 25 is useful"))
        XCTAssertTrue(presenceMove.combinedSpokenText.contains("reused 5 as the row size"))
        XCTAssertFalse(presenceMove.combinedSpokenText.contains("Try again"))
        XCTAssertTrue(presenceMove.nextMove?.contains("presence:repair") == true)
    }

    func testExperienceBriefChoosesRepairLabForConfusion() {
        let context = LearningAssetContext(
            assetType: .whiteboard,
            frontmostAppName: "Freeform",
            candidateTopic: "fractions",
            browserTitle: nil,
            browserURL: nil,
            selectedFilePaths: [],
            selectedFilePreview: nil,
            screenContextLines: []
        )
        let controller = TeacherModeController()
        _ = controller.beginOrUpdateLesson(
            transcript: "teach fractions",
            assetContext: context,
            preparedLearningSurfaceContext: FreeformDiagramSpec(
                kind: .fractionBar,
                title: "Fractions as equal parts"
            ).promptContext
        )
        let confusedLesson = controller.beginOrUpdateLesson(
            transcript: "I don't get numerator and denominator",
            assetContext: context
        )

        let brief = LearningExperienceDesigner.brief(
            for: confusedLesson,
            assetContext: context
        )

        XCTAssertEqual(brief.mode, .misconceptionLab)
        XCTAssertTrue(brief.visibleMove.contains("whole partition"))
        XCTAssertTrue(brief.feedbackLoop.contains("mistake"))
    }
}
