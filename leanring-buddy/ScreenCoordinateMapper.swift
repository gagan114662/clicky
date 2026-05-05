import AppKit
import Foundation

/// Pure functions for translating between Claude's image-space coords and macOS global coords.
/// Anthropic recommends sending images at <=1280px wide for best computer-use accuracy.
enum ScreenCoordinateMapper {

    /// Returns a viewport size <=1280 wide that preserves the native aspect ratio.
    static func recommendedClaudeViewport(forNativeScreenSize nativeSize: CGSize) -> (width: Int, height: Int) {
        let maxWidth: CGFloat = 1280
        if nativeSize.width <= maxWidth {
            return (Int(nativeSize.width.rounded()), Int(nativeSize.height.rounded()))
        }
        let scale = maxWidth / nativeSize.width
        return (Int(maxWidth), Int((nativeSize.height * scale).rounded()))
    }

    static func isClaudePointInsideViewport(
        _ claudePoint: CGPoint,
        claudeViewportSize: CGSize
    ) -> Bool {
        claudeViewportSize.width > 0
            && claudeViewportSize.height > 0
            && claudePoint.x >= 0
            && claudePoint.y >= 0
            && claudePoint.x < claudeViewportSize.width
            && claudePoint.y < claudeViewportSize.height
    }

    /// Map a point Claude returned (origin top-left, in viewport coords) to AppKit
    /// global coords (origin bottom-left of the primary screen).
    static func mapClaudePointToGlobalScreenPoint(
        claudePoint: CGPoint,
        claudeViewportSize: CGSize,
        targetScreenFrame: CGRect
    ) -> CGPoint {
        let scaleX = targetScreenFrame.width / claudeViewportSize.width
        let scaleY = targetScreenFrame.height / claudeViewportSize.height
        let xInScreenSpace = targetScreenFrame.origin.x + claudePoint.x * scaleX
        // Flip y: claude is top-down, AppKit global is bottom-up.
        let yInScreenSpace = targetScreenFrame.origin.y + targetScreenFrame.height - (claudePoint.y * scaleY)
        return CGPoint(x: xInScreenSpace, y: yInScreenSpace)
    }

    /// CGEvent (HID) coords are top-left origin and use the same pixel space as the
    /// physical screen. Use this when posting events instead of AppKit conversion.
    static func mapClaudePointToCGHIDPoint(
        claudePoint: CGPoint,
        claudeViewportSize: CGSize,
        targetScreenFrame: CGRect
    ) -> CGPoint {
        let scaleX = targetScreenFrame.width / claudeViewportSize.width
        let scaleY = targetScreenFrame.height / claudeViewportSize.height
        let xCGHID = targetScreenFrame.origin.x + claudePoint.x * scaleX
        let yCGHID = targetScreenFrame.origin.y + claudePoint.y * scaleY
        return CGPoint(x: xCGHID, y: yCGHID)
    }
}
