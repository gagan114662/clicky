import XCTest
import AppKit
@testable import ipop_ai

final class ScreenCoordinateMapperTests: XCTestCase {
    func testTopLeftMapsToScreenOrigin() {
        let claudePoint = CGPoint(x: 0, y: 0)
        let screenFrame = CGRect(x: 100, y: 50, width: 1920, height: 1200)
        let claudeViewportSize = CGSize(width: 1280, height: 800)
        let mapped = ScreenCoordinateMapper.mapClaudePointToGlobalScreenPoint(
            claudePoint: claudePoint,
            claudeViewportSize: claudeViewportSize,
            targetScreenFrame: screenFrame
        )
        XCTAssertEqual(mapped.x, 100, accuracy: 0.5)
        // AppKit's global coord origin is bottom-left, so y=0 in Claude space (top of screen)
        // maps to the top of the screen frame in AppKit: frame.origin.y + frame.height.
        XCTAssertEqual(mapped.y, 50 + 1200, accuracy: 0.5)
    }

    func testCenterMapsToScreenCenter() {
        let claudePoint = CGPoint(x: 640, y: 400)
        let screenFrame = CGRect(x: 0, y: 0, width: 1920, height: 1200)
        let claudeViewportSize = CGSize(width: 1280, height: 800)
        let mapped = ScreenCoordinateMapper.mapClaudePointToGlobalScreenPoint(
            claudePoint: claudePoint,
            claudeViewportSize: claudeViewportSize,
            targetScreenFrame: screenFrame
        )
        XCTAssertEqual(mapped.x, 960, accuracy: 0.5)
        XCTAssertEqual(mapped.y, 600, accuracy: 0.5)
    }

    func testRecommendedClaudeViewportNeverExceeds1280Wide() {
        let nativeSize = CGSize(width: 3840, height: 2160)
        let viewport = ScreenCoordinateMapper.recommendedClaudeViewport(forNativeScreenSize: nativeSize)
        XCTAssertLessThanOrEqual(viewport.width, 1280)
        // Aspect ratio preserved
        let nativeRatio = nativeSize.width / nativeSize.height
        let viewportRatio = CGFloat(viewport.width) / CGFloat(viewport.height)
        XCTAssertEqual(nativeRatio, viewportRatio, accuracy: 0.01)
    }

    func testViewportBoundsRejectsOutsideCoordinates() {
        let viewport = CGSize(width: 1280, height: 720)
        XCTAssertTrue(ScreenCoordinateMapper.isClaudePointInsideViewport(CGPoint(x: 0, y: 0), claudeViewportSize: viewport))
        XCTAssertTrue(ScreenCoordinateMapper.isClaudePointInsideViewport(CGPoint(x: 1279, y: 719), claudeViewportSize: viewport))
        XCTAssertFalse(ScreenCoordinateMapper.isClaudePointInsideViewport(CGPoint(x: 1280, y: 719), claudeViewportSize: viewport))
        XCTAssertFalse(ScreenCoordinateMapper.isClaudePointInsideViewport(CGPoint(x: 1279, y: 720), claudeViewportSize: viewport))
        XCTAssertFalse(ScreenCoordinateMapper.isClaudePointInsideViewport(CGPoint(x: -1, y: 0), claudeViewportSize: viewport))
    }
}
