import XCTest
@testable import ipop_ai

final class LearningIntentRouterTests: XCTestCase {
    func testExplicitTeachMeRoutesToTeacherMode() {
        XCTAssertEqual(
            LearningIntentRouter.route(
                transcript: "teach me this",
                isTeacherModeEnabled: true,
                hasActiveLesson: false
            ),
            .teacherMode
        )
    }

    func testHelpSomeoneLearnRoutesToTeacherMode() {
        XCTAssertEqual(
            LearningIntentRouter.route(
                transcript: "Clicky, this is Codex speaking. Help Gagan learn multiplication like a patient teacher.",
                isTeacherModeEnabled: true,
                hasActiveLesson: false
            ),
            .teacherMode
        )
    }

    func testExplainTopicRoutesToTeacherMode() {
        XCTAssertEqual(
            LearningIntentRouter.route(
                transcript: "Open Freeform and explain multiplication.",
                isTeacherModeEnabled: true,
                hasActiveLesson: false
            ),
            .teacherMode
        )
        XCTAssertEqual(
            LearningIntentRouter.route(
                transcript: "Explain derivatives visually.",
                isTeacherModeEnabled: true,
                hasActiveLesson: false
            ),
            .teacherMode
        )
    }

    func testYouTubeLessonAssetRoutesToTeacherMode() {
        XCTAssertEqual(
            LearningIntentRouter.route(
                transcript: "Use this YouTube video as the lesson.",
                isTeacherModeEnabled: true,
                hasActiveLesson: false
            ),
            .teacherMode
        )
    }

    func testEndLessonOnlyRoutesWhenLessonIsActive() {
        XCTAssertEqual(
            LearningIntentRouter.route(
                transcript: "end lesson",
                isTeacherModeEnabled: true,
                hasActiveLesson: true
            ),
            .endLesson
        )
        XCTAssertEqual(
            LearningIntentRouter.route(
                transcript: "end lesson",
                isTeacherModeEnabled: true,
                hasActiveLesson: false
            ),
            .notLearning
        )
        XCTAssertTrue(
            LearningIntentRouter.isEndLessonRequest("Clicky, this is Codex speaking. End lesson.")
        )
        XCTAssertEqual(
            LearningIntentRouter.route(
                transcript: "Stop right there. Codex—",
                isTeacherModeEnabled: true,
                hasActiveLesson: true
            ),
            .endLesson
        )
    }

    func testActiveLessonFollowUpsRouteBackToTeacherMode() {
        XCTAssertEqual(
            LearningIntentRouter.route(
                transcript: "why?",
                isTeacherModeEnabled: true,
                hasActiveLesson: true
            ),
            .teacherMode
        )
        XCTAssertEqual(
            LearningIntentRouter.route(
                transcript: "I think it means the loop stops when the condition is false",
                isTeacherModeEnabled: true,
                hasActiveLesson: true
            ),
            .teacherMode
        )
        XCTAssertEqual(
            LearningIntentRouter.route(
                transcript: "tell me more",
                isTeacherModeEnabled: true,
                hasActiveLesson: true
            ),
            .teacherMode
        )
        XCTAssertEqual(
            LearningIntentRouter.route(
                transcript: "I don't know",
                isTeacherModeEnabled: true,
                hasActiveLesson: true
            ),
            .teacherMode
        )
    }

    func testCurlyApostropheConfusionRoutesToTeacherMode() {
        XCTAssertEqual(
            LearningIntentRouter.route(
                transcript: "I don’t get numerator and denominator.",
                isTeacherModeEnabled: true,
                hasActiveLesson: true
            ),
            .teacherMode
        )
        XCTAssertEqual(
            LearningIntentRouter.route(
                transcript: "I don’t get numerator and denominator.",
                isTeacherModeEnabled: true,
                hasActiveLesson: false
            ),
            .teacherMode
        )
    }

    func testDirectComputerCommandDoesNotGetCapturedByActiveLesson() {
        XCTAssertEqual(
            LearningIntentRouter.route(
                transcript: "open calculator",
                isTeacherModeEnabled: true,
                hasActiveLesson: true
            ),
            .notLearning
        )
    }

    func testNotesDraftDoesNotGetCapturedByActiveLesson() {
        XCTAssertEqual(
            LearningIntentRouter.route(
                transcript: "Open Notes and draft a note called Pasta plan with three ingredients.",
                isTeacherModeEnabled: true,
                hasActiveLesson: true
            ),
            .notLearning
        )
        XCTAssertEqual(
            LearningIntentRouter.route(
                transcript: "open notes",
                isTeacherModeEnabled: true,
                hasActiveLesson: true
            ),
            .notLearning
        )
    }

    func testExternalActionDoesNotGetCapturedByActiveLesson() {
        XCTAssertEqual(
            LearningIntentRouter.route(
                transcript: "Apply to this Upwork job with a short proposal.",
                isTeacherModeEnabled: true,
                hasActiveLesson: true
            ),
            .notLearning
        )
        XCTAssertEqual(
            LearningIntentRouter.route(
                transcript: "Tell John I am running late on Slack.",
                isTeacherModeEnabled: true,
                hasActiveLesson: true
            ),
            .notLearning
        )
    }

    func testTeacherModeDisabledRoutesNothing() {
        XCTAssertEqual(
            LearningIntentRouter.route(
                transcript: "teach me this",
                isTeacherModeEnabled: false,
                hasActiveLesson: false
            ),
            .notLearning
        )
    }
}
