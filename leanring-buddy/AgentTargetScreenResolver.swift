import AppKit

/// Minimal protocol so `AgentTargetScreenResolver` is testable without real `NSScreen`.
protocol ScreenLike {
    var frame: CGRect { get }
}

extension NSScreen: ScreenLike {}

enum AgentTargetScreenResolver {

    /// Picks the screen that currently contains the user's mouse cursor.
    /// Falls back to the supplied primary screen if the mouse is somehow off all screens.
    static func pickTargetScreen<S: ScreenLike>(
        mouseGlobalPoint: CGPoint,
        connectedScreens: [S],
        fallbackPrimary: S
    ) -> S {
        for screen in connectedScreens {
            if screen.frame.contains(mouseGlobalPoint) {
                return screen
            }
        }
        return fallbackPrimary
    }

    /// Convenience for production: queries `NSEvent.mouseLocation` and `NSScreen.screens`.
    @MainActor
    static func currentTargetScreen() -> NSScreen {
        let mousePoint = NSEvent.mouseLocation
        let allScreens = NSScreen.screens
        let primary = NSScreen.main ?? allScreens.first ?? NSScreen.screens[0]
        return pickTargetScreen(
            mouseGlobalPoint: mousePoint,
            connectedScreens: allScreens,
            fallbackPrimary: primary
        )
    }
}
