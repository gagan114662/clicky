import XCTest
@testable import ipop_ai

final class LocalIntentRouterTests: XCTestCase {
    func testCloseNamedWindowRoutesToTargetedWindowClose() {
        XCTAssertEqual(
            LocalIntentRouter.route(transcript: "close this Freeform window"),
            .closeWindowInApp(name: "freeform")
        )
    }

    func testCloseNamedWindowWithPunctuationRoutesToTargetedWindowClose() {
        XCTAssertEqual(
            LocalIntentRouter.route(transcript: "Close this Freeform window."),
            .closeWindowInApp(name: "freeform")
        )
    }

    func testCloseBareNamedWindowRoutesToTargetedWindowClose() {
        XCTAssertEqual(
            LocalIntentRouter.route(transcript: "close Freeform window"),
            .closeWindowInApp(name: "freeform")
        )
    }

    func testCloseThisWindowWithoutAppRoutesToFrontmostWindowClose() {
        XCTAssertEqual(
            LocalIntentRouter.route(transcript: "close this window"),
            .closeFrontmostWindow
        )
    }

    func testCloseWindowInNamedAppRoutesToTargetedWindowClose() {
        XCTAssertEqual(
            LocalIntentRouter.route(transcript: "close the window in Freeform"),
            .closeWindowInApp(name: "freeform")
        )
    }

    func testOpenFreeformStillRoutesToNativeApp() {
        XCTAssertEqual(
            LocalIntentRouter.route(transcript: "open Freeform"),
            .launchOrActivateApp(name: "freeform")
        )
    }

    func testOpenCalculatorAndShowMultiplicationRoutesToCalculatorExpression() {
        XCTAssertEqual(
            LocalIntentRouter.route(transcript: "Open Calculator and show me 17 times 24."),
            .calculateInCalculator(expression: "17*24")
        )
    }

    func testPlainCalculatorOpenStillRoutesToNativeApp() {
        XCTAssertEqual(
            LocalIntentRouter.route(transcript: "Open Calculator"),
            .launchOrActivateApp(name: "calculator")
        )
    }

    func testDraftNoteDoesNotRouteToSilentLocalWrite() {
        XCTAssertEqual(
            LocalIntentRouter.route(transcript: "Open Notes and draft a note called Pasta plan with three ingredients."),
            .unmatched
        )
    }

    func testJotDownNoteDoesNotRouteToSilentLocalWrite() {
        XCTAssertEqual(
            LocalIntentRouter.route(transcript: "Jot down that the launch plan needs three bullets."),
            .unmatched
        )
    }
}
