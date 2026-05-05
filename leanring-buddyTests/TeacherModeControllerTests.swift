import XCTest
@testable import ipop_ai

@MainActor
final class TeacherModeControllerTests: XCTestCase {
    func testLearningActionTagParserStripsActionTag() {
        let parsed = LearningActionTagParser.parse(
            from: "let's pause here and predict what happens next. [LEARN_ACTION:pause_play]"
        )

        XCTAssertEqual(parsed.spokenText, "let's pause here and predict what happens next.")
        XCTAssertEqual(parsed.action, .pausePlay)
    }

    func testLearningActionTagParserParsesOpenURL() {
        let parsed = LearningActionTagParser.parse(
            from: "i found a better source for the next step. [LEARN_ACTION:open_url:https://example.com/lesson]"
        )

        XCTAssertEqual(parsed.spokenText, "i found a better source for the next step.")
        XCTAssertEqual(parsed.action, .openURL("https://example.com/lesson"))
    }

    func testLearningActionTagParserParsesScratchpad() {
        let parsed = LearningActionTagParser.parse(
            from: "I'll work this out where you can see it. [LEARN_ACTION:scratchpad:6 x 3 = 6 + 6 + 6 = 18]"
        )

        XCTAssertEqual(parsed.spokenText, "I'll work this out where you can see it.")
        XCTAssertEqual(parsed.action, .writeScratchpad("6 x 3 = 6 + 6 + 6 = 18"))
    }

    func testLearningActionTagParserRemovesMiddleActionTag() {
        let parsed = LearningActionTagParser.parse(
            from: "I'll write this down.\n[LEARN_ACTION:scratchpad:5 x 3 = 15]\nNow try 4 x 6."
        )

        XCTAssertEqual(parsed.spokenText, "I'll write this down.\n\nNow try 4 x 6.")
        XCTAssertEqual(parsed.action, .writeScratchpad("5 x 3 = 15"))
    }

    func testLearningActionTagParserParsesRestrictedNativeAppOpen() {
        let parsed = LearningActionTagParser.parse(
            from: "Let's use a whiteboard for this. [LEARN_ACTION:open_native_app:Freeform]"
        )

        XCTAssertEqual(parsed.spokenText, "Let's use a whiteboard for this.")
        XCTAssertEqual(parsed.action, .openNativeApp("Freeform"))
    }

    func testLearningActionTagParserParsesFreeformText() {
        let parsed = LearningActionTagParser.parse(
            from: "I'll put the setup on the board. [LEARN_ACTION:freeform_text:3 groups of 4 dots means 4 + 4 + 4]"
        )

        XCTAssertEqual(parsed.spokenText, "I'll put the setup on the board.")
        XCTAssertEqual(parsed.action, .writeFreeformText("3 groups of 4 dots means 4 + 4 + 4"))
    }

    func testLearningActionTagParserParsesFreeformBoard() {
        let parsed = LearningActionTagParser.parse(
            from: "I'll set up the board first. [LEARN_ACTION:freeform_board:3 x 4\\no o o o\\no o o o\\no o o o]"
        )

        XCTAssertEqual(parsed.spokenText, "I'll set up the board first.")
        XCTAssertEqual(parsed.action, .prepareFreeformBoard("3 x 4\\no o o o\\no o o o\\no o o o"))
    }

    func testLearningActionTagParserParsesFreeformDiagram() {
        let parsed = LearningActionTagParser.parse(
            from: "I'll make that visual. [LEARN_ACTION:freeform_diagram:multiplication_array:Array model]"
        )

        XCTAssertEqual(parsed.spokenText, "I'll make that visual.")
        XCTAssertEqual(
            parsed.action,
            .prepareFreeformDiagram(FreeformDiagramSpec(kind: .multiplicationArray, title: "Array model"))
        )
    }

    func testTeachingMoveParserAcceptsStructuredJSON() {
        let raw = """
        {
          "spokenResponse": "Look at the left array: three rows, four in each row.",
          "surfaceAction": "freeform_text:3 x 4 = 12",
          "pointTarget": "640,420:left array",
          "question": "What fact does the green array show?",
          "memoryCandidate": "User is working with array models.",
          "nextMove": "evaluate array answer"
        }
        """

        let move = TeachingMove.parse(from: raw)

        XCTAssertEqual(move.combinedSpokenText, "Look at the left array: three rows, four in each row.\n\nWhat fact does the green array show?")
        XCTAssertEqual(move.surfaceAction, .writeFreeformText("3 x 4 = 12"))
        XCTAssertEqual(move.responseWithPointTag().contains("[POINT:640,420:left array]"), true)
        XCTAssertEqual(move.nextMove, "evaluate array answer")
    }

    func testBridgeLineIsImmediateSurfaceAware() {
        let controller = TeacherModeController()

        XCTAssertEqual(
            controller.bridgeLine(for: "Teach multiplication visually in Freeform"),
            "Got you. I'll put the picture on screen first."
        )
        XCTAssertEqual(
            controller.bridgeLine(for: "Teach me this Xcode error"),
            "I'm looking at the error and I'll teach the idea behind it."
        )
    }

    func testUserPromptIncludesCurriculumArc() {
        let controller = TeacherModeController()
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
        let lesson = controller.beginOrUpdateLesson(
            transcript: "Teach multiplication visually",
            assetContext: context,
            preparedLearningSurfaceContext: FreeformDiagramSpec(
                kind: .multiplicationArray,
                title: "Multiplication as an array"
            ).promptContext
        )

        let prompt = controller.userPrompt(
            transcript: "Teach multiplication visually",
            assetContext: context,
            lesson: lesson
        )

        XCTAssertTrue(prompt.contains("Curriculum arc:"))
        XCTAssertTrue(prompt.contains("current_milestone:"))
        XCTAssertTrue(prompt.contains("upcoming_milestones:"))
        XCTAssertTrue(prompt.contains("diagnostic_question:"))
    }

    func testLocalTeachingMoveForGeneratedMultiplicationDiagramAvoidsModelRoundTrip() {
        let controller = TeacherModeController()
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
        let lesson = controller.beginOrUpdateLesson(
            transcript: "Teach multiplication visually",
            assetContext: context,
            preparedLearningSurfaceContext: FreeformDiagramSpec(
                kind: .multiplicationArray,
                title: "Multiplication as an array"
            ).promptContext
        )

        let move = controller.localTeachingMove(
            transcript: "Teach multiplication visually",
            lesson: lesson,
            preparedDiagramSpec: FreeformDiagramSpec(kind: .multiplicationArray, title: "Multiplication as an array")
        )

        XCTAssertEqual(move?.surfaceAction, nil)
        XCTAssertEqual(move?.question, "What are the rows, what is in each row, and what total does that make?")
        XCTAssertTrue(move?.combinedSpokenText.contains("3 rows") == true)
        XCTAssertTrue(move?.responseWithPointTag().contains("[POINT:730,300:your turn array]") == true)
    }

    func testConfusedMultiplicationStartShrinksToOneRow() {
        let controller = TeacherModeController()
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
        let spec = FreeformDiagramSpec(kind: .multiplicationArray, title: "Multiplication as an array")
        let lesson = controller.beginOrUpdateLesson(
            transcript: "Teach multiplication visually like I am confused and impatient",
            assetContext: context,
            preparedLearningSurfaceContext: spec.promptContext
        )

        let move = controller.localTeachingMove(
            transcript: "Teach multiplication visually like I am confused and impatient",
            lesson: lesson,
            preparedDiagramSpec: spec
        )

        XCTAssertTrue(move?.combinedSpokenText.contains("No lecture") == true)
        XCTAssertEqual(move?.question, "How many dots are in that top row?")
        XCTAssertTrue(move?.responseWithPointTag().contains("top row") == true)
    }

    func testLocalTeachingMoveEvaluatesGeneratedMultiplicationAnswer() {
        let controller = TeacherModeController()
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
        let spec = FreeformDiagramSpec(kind: .multiplicationArray, title: "Multiplication as an array")
        _ = controller.beginOrUpdateLesson(
            transcript: "Teach multiplication visually",
            assetContext: context,
            preparedLearningSurfaceContext: spec.promptContext
        )
        _ = controller.completeTurn(
            userTranscript: "Teach multiplication visually",
            assistantResponse: "What multiplication fact does the green array show?",
            teachingMove: controller.localTeachingMove(
                transcript: "Teach multiplication visually",
                lesson: controller.activeLesson!,
                preparedDiagramSpec: spec
            )
        )
        let answerTurn = controller.beginOrUpdateLesson(
            transcript: "5 times 6 equals 30",
            assetContext: context
        )

        let move = controller.localTeachingMove(
            transcript: "5 times 6 equals 30",
            lesson: answerTurn,
            preparedDiagramSpec: nil
        )

        XCTAssertTrue(move?.combinedSpokenText.contains("5 times 6 gives 30") == true)
        XCTAssertEqual(move?.question, "Now flip the idea: if it were 6 rows with 5 dots in each row, would the total change, or stay 30?")
    }

    func testWrongMultiplicationAnswerRepairsWithoutModelRoundTrip() {
        let controller = TeacherModeController()
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
        let spec = FreeformDiagramSpec(kind: .multiplicationArray, title: "Multiplication as an array")
        _ = controller.beginOrUpdateLesson(
            transcript: "Teach multiplication visually",
            assetContext: context,
            preparedLearningSurfaceContext: spec.promptContext
        )
        _ = controller.completeTurn(
            userTranscript: "Teach multiplication visually",
            assistantResponse: "What are the rows, what is in each row, and what total does that make?",
            teachingMove: controller.localTeachingMove(
                transcript: "Teach multiplication visually",
                lesson: controller.activeLesson!,
                preparedDiagramSpec: spec
            )
        )
        let answerTurn = controller.beginOrUpdateLesson(
            transcript: "I think it is 25. I still do not get it.",
            assetContext: context
        )

        let move = controller.localTeachingMove(
            transcript: "I think it is 25. I still do not get it.",
            lesson: answerTurn,
            preparedDiagramSpec: nil
        )

        XCTAssertTrue(move?.combinedSpokenText.contains("Twenty five means you saw the 5 rows") == true)
        XCTAssertEqual(move?.question, "How many green dots are in just the top row?")
        XCTAssertTrue(move?.responseWithPointTag().contains("top row") == true)
    }

    func testControllerStartsAndUpdatesLesson() {
        let controller = TeacherModeController()
        let context = LearningAssetContext(
            assetType: .youtube,
            frontmostAppName: "Safari",
            candidateTopic: "Derivative intuition",
            browserTitle: "Derivative intuition",
            browserURL: "https://www.youtube.com/watch?v=test",
            selectedFilePaths: [],
            selectedFilePreview: nil,
            screenContextLines: ["user's screen (cursor is here), image 1280x720 pixels"]
        )

        let lesson = controller.beginOrUpdateLesson(
            transcript: "teach me this",
            assetContext: context
        )

        XCTAssertEqual(lesson.topic, "Derivative intuition")
        XCTAssertEqual(lesson.assetType, .youtube)
        XCTAssertEqual(lesson.phase, .starting)
        XCTAssertEqual(lesson.currentTeachingMove, "orient")
        XCTAssertEqual(lesson.learnerHypothesis, "unknown, infer from the user's next answer")
        XCTAssertEqual(controller.activeLesson?.compactStatus, "YouTube in Safari")
    }

    func testLearningAssetPromptIncludesAssetNotes() {
        let context = LearningAssetContext(
            assetType: .youtube,
            frontmostAppName: "Safari",
            candidateTopic: "Derivative intuition",
            browserTitle: "Derivative intuition",
            browserURL: "https://www.youtube.com/watch?v=test",
            selectedFilePaths: [],
            selectedFilePreview: nil,
            screenContextLines: [],
            assetNotes: [
                "visible_youtube_captions: slope means rate of change",
                "visible_page_text: derivative intuition and tangent lines"
            ]
        )

        XCTAssertTrue(context.promptBlock.contains("asset_notes:"))
        XCTAssertTrue(context.promptBlock.contains("visible_youtube_captions: slope means rate of change"))
        XCTAssertTrue(context.promptBlock.contains("visible_page_text: derivative intuition and tangent lines"))
    }

    func testExplicitTopicBeatsIncidentalScreenTopic() {
        let controller = TeacherModeController()
        let context = LearningAssetContext(
            assetType: .browserPage,
            frontmostAppName: "Google Chrome",
            candidateTopic: "Gmail inbox",
            browserTitle: "Gmail inbox",
            browserURL: "https://mail.google.com/",
            selectedFilePaths: [],
            selectedFilePreview: nil,
            screenContextLines: ["user's screen (cursor is here), image 1280x720 pixels"]
        )

        let lesson = controller.beginOrUpdateLesson(
            transcript: "Clicky, this is Codex speaking. Teach multiplication with one concrete example and one checkpoint question.",
            assetContext: context
        )

        XCTAssertEqual(lesson.topic, "multiplication")
    }

    func testExplicitTeachRequestStartsFreshLesson() {
        let controller = TeacherModeController()
        let context = LearningAssetContext(
            assetType: .screen,
            frontmostAppName: "Xcode",
            candidateTopic: "code in Xcode",
            browserTitle: nil,
            browserURL: nil,
            selectedFilePaths: [],
            selectedFilePreview: nil,
            screenContextLines: []
        )

        let firstLesson = controller.beginOrUpdateLesson(
            transcript: "teach multiplication with one example",
            assetContext: context
        )
        _ = controller.completeTurn(
            userTranscript: "teach multiplication with one example",
            assistantResponse: "try 4 x 6?"
        )
        let secondLesson = controller.beginOrUpdateLesson(
            transcript: "teach multiplication using your scratchpad",
            assetContext: context
        )

        XCTAssertNotEqual(firstLesson.id, secondLesson.id)
        XCTAssertNil(secondLesson.lastCheckpointQuestion)
        XCTAssertEqual(secondLesson.phase, .starting)
    }

    func testLearnerAnswerAfterCheckpointEntersEvaluationPhase() {
        let controller = TeacherModeController()
        let context = LearningAssetContext(
            assetType: .screen,
            frontmostAppName: "Freeform",
            candidateTopic: "multiplication",
            browserTitle: nil,
            browserURL: nil,
            selectedFilePaths: [],
            selectedFilePreview: nil,
            screenContextLines: []
        )

        _ = controller.beginOrUpdateLesson(
            transcript: "teach multiplication",
            assetContext: context
        )
        _ = controller.completeTurn(
            userTranscript: "teach multiplication",
            assistantResponse: "3 groups of 4 is 12. What is 2 groups of 5?"
        )
        let answerTurn = controller.beginOrUpdateLesson(
            transcript: "I think it is 10",
            assetContext: context
        )

        XCTAssertEqual(answerTurn.phase, .evaluatingAnswer)
        XCTAssertEqual(answerTurn.lastCheckpointQuestion, "3 groups of 4 is 12. What is 2 groups of 5?")
    }

    func testLearnerAnswerDoesNotRenameActiveLessonToIncidentalScreenTopic() {
        let controller = TeacherModeController()
        let firstContext = LearningAssetContext(
            assetType: .screen,
            frontmostAppName: "TextEdit",
            candidateTopic: "multiplication",
            browserTitle: nil,
            browserURL: nil,
            selectedFilePaths: [],
            selectedFilePreview: nil,
            screenContextLines: []
        )
        let incidentalContext = LearningAssetContext(
            assetType: .screen,
            frontmostAppName: "TextEdit",
            candidateTopic: "screen in TextEdit",
            browserTitle: nil,
            browserURL: nil,
            selectedFilePaths: [],
            selectedFilePreview: nil,
            screenContextLines: []
        )

        _ = controller.beginOrUpdateLesson(
            transcript: "teach multiplication",
            assetContext: firstContext
        )
        _ = controller.completeTurn(
            userTranscript: "teach multiplication",
            assistantResponse: "What is 4 x 6?"
        )
        let answerTurn = controller.beginOrUpdateLesson(
            transcript: "I think the answer is 24",
            assetContext: incidentalContext
        )

        XCTAssertEqual(answerTurn.topic, "multiplication")
        XCTAssertEqual(answerTurn.phase, .evaluatingAnswer)
    }

    func testConfusionAfterCheckpointEntersRepairPhase() {
        let controller = TeacherModeController()
        let context = LearningAssetContext(
            assetType: .screen,
            frontmostAppName: "Freeform",
            candidateTopic: "multiplication",
            browserTitle: nil,
            browserURL: nil,
            selectedFilePaths: [],
            selectedFilePreview: nil,
            screenContextLines: []
        )

        _ = controller.beginOrUpdateLesson(
            transcript: "teach multiplication",
            assetContext: context
        )
        _ = controller.completeTurn(
            userTranscript: "teach multiplication",
            assistantResponse: "3 groups of 4 is 12. What is 2 groups of 5?"
        )
        let repairTurn = controller.beginOrUpdateLesson(
            transcript: "I don't get it",
            assetContext: context
        )

        XCTAssertEqual(repairTurn.phase, .repairingConfusion)
    }

    func testCurlyApostropheTopicSwitchStartsFreshFractionLesson() {
        let controller = TeacherModeController()
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

        let firstLesson = controller.beginOrUpdateLesson(
            transcript: "Teach multiplication visually",
            assetContext: context,
            preparedLearningSurfaceContext: FreeformDiagramSpec(
                kind: .multiplicationArray,
                title: "Multiplication as an array"
            ).promptContext
        )
        _ = controller.completeTurn(
            userTranscript: "Teach multiplication visually",
            assistantResponse: "What are the rows, what is in each row, and what total does that make?"
        )

        let secondLesson = controller.beginOrUpdateLesson(
            transcript: "I don’t get numerator and denominator.",
            assetContext: context
        )

        XCTAssertNotEqual(firstLesson.id, secondLesson.id)
        XCTAssertEqual(secondLesson.topic, "numerator and denominator")
        XCTAssertEqual(secondLesson.phase, .starting)
    }

    func testNumeratorDenominatorConfusionPreparesFractionWhiteboard() {
        let controller = TeacherModeController()
        let context = LearningAssetContext(
            assetType: .screen,
            frontmostAppName: "Xcode",
            candidateTopic: "screen in Xcode",
            browserTitle: nil,
            browserURL: nil,
            selectedFilePaths: [],
            selectedFilePreview: nil,
            screenContextLines: []
        )

        let action = controller.immediateLearningAction(
            transcript: "I don’t get numerator and denominator.",
            assetContext: context
        )

        if case .prepareFreeformDiagram(let spec) = action {
            XCTAssertEqual(spec.kind, .fractionBar)
            XCTAssertEqual(spec.title, "Fractions as equal parts")
        } else {
            XCTFail("expected fraction diagram preparation, got \(String(describing: action))")
        }
    }

    func testWhiteboardRequestOpensFreeformWhenNotAlreadyOnWhiteboard() {
        let controller = TeacherModeController()
        let context = LearningAssetContext(
            assetType: .screen,
            frontmostAppName: "Xcode",
            candidateTopic: "screen in Xcode",
            browserTitle: nil,
            browserURL: nil,
            selectedFilePaths: [],
            selectedFilePreview: nil,
            screenContextLines: []
        )

        let action = controller.immediateLearningAction(
            transcript: "teach this on a whiteboard in Freeform",
            assetContext: context
        )

        if case .prepareFreeformDiagram(let spec) = action {
            XCTAssertEqual(spec.kind, .conceptMap)
            XCTAssertEqual(spec.title, "screen in Xcode")
        } else {
            XCTFail("expected Freeform diagram preparation, got \(String(describing: action))")
        }
    }

    func testVisualMathLessonOpensFreeformInsteadOfTextScratchpad() {
        let controller = TeacherModeController()
        let context = LearningAssetContext(
            assetType: .code,
            frontmostAppName: "Xcode",
            candidateTopic: "code in Xcode",
            browserTitle: nil,
            browserURL: nil,
            selectedFilePaths: [],
            selectedFilePreview: nil,
            screenContextLines: []
        )

        let action = controller.immediateLearningAction(
            transcript: "Teach multiplication. Ask one checkpoint.",
            assetContext: context
        )

        if case .prepareFreeformDiagram(let spec) = action {
            XCTAssertEqual(spec.kind, .multiplicationArray)
            XCTAssertEqual(spec.title, "Multiplication as an array")
        } else {
            XCTFail("expected Freeform diagram preparation, got \(String(describing: action))")
        }
    }

    func testPreparedFreeformDiagramContextCarriesExactArrayFactsIntoPrompt() {
        let controller = TeacherModeController()
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
        let spec = FreeformDiagramSpec(kind: .multiplicationArray, title: "Multiplication as an array")
        let lesson = controller.beginOrUpdateLesson(
            transcript: "Teach multiplication visually",
            assetContext: context,
            preparedLearningSurfaceContext: spec.promptContext
        )

        let prompt = controller.userPrompt(
            transcript: "Teach multiplication visually",
            assetContext: context,
            lesson: lesson
        )

        XCTAssertTrue(prompt.contains("Left example card: 3 rows and 4 columns"))
        XCTAssertTrue(prompt.contains("Right practice card: 5 rows and 6 columns"))
        XCTAssertTrue(prompt.contains("Do not infer different row/column counts"))
    }

    func testTeacherPromptIncludesLearningExperienceBrief() {
        let controller = TeacherModeController()
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
        let lesson = controller.beginOrUpdateLesson(
            transcript: "Teach multiplication visually",
            assetContext: context,
            preparedLearningSurfaceContext: FreeformDiagramSpec(
                kind: .multiplicationArray,
                title: "Multiplication as an array"
            ).promptContext
        )

        let prompt = controller.userPrompt(
            transcript: "Teach multiplication visually",
            assetContext: context,
            lesson: lesson
        )

        XCTAssertTrue(prompt.contains("<learning-presence-frame>"))
        XCTAssertTrue(prompt.contains("agi_move:"))
        XCTAssertTrue(prompt.contains("<learning-experience-brief>"))
        XCTAssertTrue(prompt.contains("visible_move:"))
        XCTAssertTrue(prompt.contains("predict, manipulate, compare, transfer, or explain back"))
    }

    func testXcodeErrorLessonDoesNotStealFocusToFreeform() {
        let controller = TeacherModeController()
        let context = LearningAssetContext(
            assetType: .code,
            frontmostAppName: "Xcode",
            candidateTopic: "Swift compile error",
            browserTitle: nil,
            browserURL: nil,
            selectedFilePaths: [],
            selectedFilePreview: nil,
            screenContextLines: []
        )

        let action = controller.immediateLearningAction(
            transcript: "teach me this Xcode error",
            assetContext: context
        )

        XCTAssertNil(action)
    }

    func testTeacherCanOpenLearningURLFromTranscript() {
        let controller = TeacherModeController()
        let context = LearningAssetContext(
            assetType: .screen,
            frontmostAppName: "Xcode",
            candidateTopic: "screen in Xcode",
            browserTitle: nil,
            browserURL: nil,
            selectedFilePaths: [],
            selectedFilePreview: nil,
            screenContextLines: []
        )

        let action = controller.immediateLearningAction(
            transcript: "teach me from https://www.youtube.com/watch?v=test123",
            assetContext: context
        )

        XCTAssertEqual(action, .openURL("https://www.youtube.com/watch?v=test123"))
    }

    func testTeacherCanonicalizesShortYouTubeURLBeforeOpening() {
        let controller = TeacherModeController()
        let context = LearningAssetContext(
            assetType: .screen,
            frontmostAppName: "Xcode",
            candidateTopic: "screen in Xcode",
            browserTitle: nil,
            browserURL: nil,
            selectedFilePaths: [],
            selectedFilePreview: nil,
            screenContextLines: []
        )

        let action = controller.immediateLearningAction(
            transcript: "teach me from https://youtu.be/test123?t=12",
            assetContext: context
        )

        XCTAssertEqual(action, .openURL("https://www.youtube.com/watch?v=test123&t=12"))
    }

    func testBrokenYouTubeWatchURLFallsBackToSearchInsteadOfDeadLink() {
        let controller = TeacherModeController()
        let context = LearningAssetContext(
            assetType: .screen,
            frontmostAppName: "Xcode",
            candidateTopic: "screen in Xcode",
            browserTitle: nil,
            browserURL: nil,
            selectedFilePaths: [],
            selectedFilePreview: nil,
            screenContextLines: []
        )

        let action = controller.immediateLearningAction(
            transcript: "teach me from https://www.youtube.com/watch?v= as a YouTube learning asset about derivatives",
            assetContext: context
        )

        if case .openURL(let urlString) = action {
            XCTAssertTrue(urlString.hasPrefix("https://www.youtube.com/results?search_query="))
            XCTAssertFalse(urlString.contains("/watch?v="))
        } else {
            XCTFail("expected YouTube search fallback, got \(String(describing: action))")
        }
    }

    func testLearningActionParserDoesNotCanonicalizeBrokenYouTubeWatchURL() {
        let parsed = LearningActionTagParser.parse(
            from: "opening that. [LEARN_ACTION:open_url:https://www.youtube.com/watch?v=]"
        )

        XCTAssertEqual(parsed.action, .openURL("https://www.youtube.com/watch?v="))
        XCTAssertNil(LearningURLSanitizer.openableURLString(from: "https://www.youtube.com/watch?v="))
    }

    func testYouTubeLessonKeepsBrowserSurfaceInsteadOfOpeningScratchpad() {
        let controller = TeacherModeController()
        let context = LearningAssetContext(
            assetType: .youtube,
            frontmostAppName: "Safari",
            candidateTopic: "YouTube video",
            browserTitle: "How derivatives work - YouTube",
            browserURL: "https://www.youtube.com/watch?v=test123",
            selectedFilePaths: [],
            selectedFilePreview: nil,
            screenContextLines: []
        )

        let action = controller.immediateLearningAction(
            transcript: "Use this YouTube video as the lesson and explain the key idea.",
            assetContext: context
        )

        XCTAssertNil(action)
    }

    func testBrowserVideoLessonDoesNotOpenScratchpadWhenScreenFallbackIsGeneric() {
        let controller = TeacherModeController()
        let context = LearningAssetContext(
            assetType: .screen,
            frontmostAppName: "Safari",
            candidateTopic: "screen in Safari",
            browserTitle: nil,
            browserURL: nil,
            selectedFilePaths: [],
            selectedFilePreview: nil,
            screenContextLines: []
        )

        let action = controller.immediateLearningAction(
            transcript: "Use this YouTube video as the lesson and explain the key idea.",
            assetContext: context
        )

        XCTAssertNil(action)
    }

    func testMalformedSpokenYouTubeURLFallsBackToSearchAsset() {
        let controller = TeacherModeController()
        let context = LearningAssetContext(
            assetType: .screen,
            frontmostAppName: "Xcode",
            candidateTopic: "screen in Xcode",
            browserTitle: nil,
            browserURL: nil,
            selectedFilePaths: [],
            selectedFilePreview: nil,
            screenContextLines: []
        )

        let action = controller.immediateLearningAction(
            transcript: "teach me from https://www.youtube— watch v=wavtayankzm as a YouTube learning asset",
            assetContext: context
        )

        if case .openURL(let urlString) = action {
            XCTAssertTrue(urlString.hasPrefix("https://www.youtube.com/results?search_query="))
        } else {
            XCTFail("expected YouTube search fallback, got \(String(describing: action))")
        }
    }

    func testSpokenYouTubeTopicBuildsCleanSearchAsset() {
        let controller = TeacherModeController()
        let context = LearningAssetContext(
            assetType: .screen,
            frontmostAppName: "Xcode",
            candidateTopic: "screen in Xcode",
            browserTitle: nil,
            browserURL: nil,
            selectedFilePaths: [],
            selectedFilePreview: nil,
            screenContextLines: []
        )

        let action = controller.immediateLearningAction(
            transcript: "Teach me from a YouTube video about derivatives. Use YouTube as the learning asset and ask one checkpoint question.",
            assetContext: context
        )

        XCTAssertEqual(action, .openURL("https://www.youtube.com/results?search_query=derivatives"))
    }

    func testWhiteboardRequestAddsDiagramWhenAlreadyOnWhiteboard() {
        let controller = TeacherModeController()
        let context = LearningAssetContext(
            assetType: .whiteboard,
            frontmostAppName: "Freeform",
            candidateTopic: "whiteboard in Freeform",
            browserTitle: nil,
            browserURL: nil,
            selectedFilePaths: [],
            selectedFilePreview: nil,
            screenContextLines: []
        )

        let action = controller.immediateLearningAction(
            transcript: "draw this on a whiteboard",
            assetContext: context
        )

        if case .prepareFreeformDiagram(let spec) = action {
            XCTAssertEqual(spec.kind, .conceptMap)
            XCTAssertEqual(spec.title, "whiteboard in Freeform")
        } else {
            XCTFail("expected Freeform diagram preparation, got \(String(describing: action))")
        }
    }

    func testControllerCapturesCheckpointQuestion() {
        let controller = TeacherModeController()
        let context = LearningAssetContext(
            assetType: .code,
            frontmostAppName: "Xcode",
            candidateTopic: "Swift optionals",
            browserTitle: nil,
            browserURL: nil,
            selectedFilePaths: [],
            selectedFilePreview: nil,
            screenContextLines: []
        )
        _ = controller.beginOrUpdateLesson(transcript: "teach me this error", assetContext: context)
        let updated = controller.completeTurn(
            userTranscript: "teach me this error",
            assistantResponse: "an optional is a box that may be empty. what would happen if you unwrap an empty one?"
        )

        XCTAssertEqual(updated?.lastCheckpointQuestion, "an optional is a box that may be empty. what would happen if you unwrap an empty one?")
        XCTAssertEqual(updated?.phase, .awaitingAnswer)
        XCTAssertEqual(updated?.turnCount, 1)
    }
}
