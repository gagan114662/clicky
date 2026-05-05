import AppKit
import Combine
import Foundation

/// Bridges the agent's "I'm about to click here" intent to the existing blue companion
/// cursor animation in `OverlayWindow`. Reuses the same `@Published` properties on
/// `CompanionManager` that the conversational POINT system already drives.
@MainActor
final class AgentCursorFlightCoordinator {
    private let companionManager: CompanionManager
    /// Time the existing BlueCursorView takes to complete its arc + a small dwell so
    /// the user actually sees it land before we post the click event.
    /// Tune by watching the cursor in TextEdit.
    private let cursorFlightDurationSeconds: TimeInterval = 0.55

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
    }

    /// Animates the blue cursor to `globalPoint` on the given screen, then resolves.
    /// After this returns, callers post their CGEvent click.
    func flyCursor(toGlobalPoint globalPoint: CGPoint,
                   onScreen targetScreen: NSScreen,
                   speechBubbleText: String?) async {
        // Drive the same Published properties the POINT-tag path drives. BlueCursorView
        // observes these and runs its bezier-arc animation.
        companionManager.detectedElementBubbleText = speechBubbleText
        companionManager.detectedElementDisplayFrame = targetScreen.frame
        companionManager.detectedElementScreenLocation = globalPoint
        try? await Task.sleep(nanoseconds: UInt64(cursorFlightDurationSeconds * 1_000_000_000))
        // Leave the cursor on screen during the click; clear the bubble so it doesn't
        // linger across multiple clicks in one turn.
        companionManager.detectedElementBubbleText = nil
    }

    /// Hides the bubble + clears pointing state (called when an agent turn ends).
    func clearAfterTurn() {
        companionManager.detectedElementBubbleText = nil
        companionManager.detectedElementScreenLocation = nil
        companionManager.detectedElementDisplayFrame = nil
    }
}
