import ApplicationServices
import CoreGraphics
import Foundation

enum ComputerUsePreflight {
    static func assertReadyForAgentRun() throws {
        let missing = missingPermissionMessages()
        guard missing.isEmpty else {
            let message = """
            Computer use is not ready yet.
            \(missing.map { "- \($0)" }.joined(separator: "\n"))
            Open System Settings, grant the missing permissions to iPOP, then relaunch the app.
            """
            throw NSError(
                domain: "ComputerUsePreflight",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }

    static func missingPermissionMessages() -> [String] {
        var messages: [String] = []

        if !AXIsProcessTrusted() {
            messages.append("Accessibility permission is required to click, type, press keys, and inspect named UI elements.")
        }

        if !CGPreflightScreenCaptureAccess() {
            messages.append("Screen Recording permission is required so the agent can see the current Mac screen.")
        }

        return messages
    }
}
