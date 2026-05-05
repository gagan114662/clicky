import XCTest
import AppKit
@testable import ipop_ai

final class AgentTargetScreenResolverTests: XCTestCase {
    func testReturnsScreenContainingMousePoint() {
        let leftMonitorFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let rightMonitorFrame = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
        let leftMonitor = MockScreen(frame: leftMonitorFrame)
        let rightMonitor = MockScreen(frame: rightMonitorFrame)
        let mousePointOnRight = CGPoint(x: 2500, y: 500)
        let resolved = AgentTargetScreenResolver.pickTargetScreen(
            mouseGlobalPoint: mousePointOnRight,
            connectedScreens: [leftMonitor, rightMonitor],
            fallbackPrimary: leftMonitor
        )
        XCTAssertEqual(resolved.frame, rightMonitorFrame)
    }

    func testFallsBackToPrimaryWhenMouseOffscreen() {
        let leftMonitorFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let leftMonitor = MockScreen(frame: leftMonitorFrame)
        let mousePointOffscreen = CGPoint(x: -500, y: -500)
        let resolved = AgentTargetScreenResolver.pickTargetScreen(
            mouseGlobalPoint: mousePointOffscreen,
            connectedScreens: [leftMonitor],
            fallbackPrimary: leftMonitor
        )
        XCTAssertEqual(resolved.frame, leftMonitorFrame)
    }
}

/// Test double that conforms to the protocol the resolver depends on.
private struct MockScreen: ScreenLike {
    let frame: CGRect
}
