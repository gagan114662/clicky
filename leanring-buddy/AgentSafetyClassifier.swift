import Foundation

enum AgentSafetyDecision: Equatable {
    case auto
    case confirmRequired(reason: String)
    case blocked(reason: String)
}

enum AgentSafetyClassifier {

    /// Classifies one tool_use block.
    ///
    /// `previousToolUseBlock` lets us catch "type a message, then press Return"
    /// sequences that are harmless in isolation but dangerous together in Mail,
    /// Slack, Upwork, browser forms, etc. `missionRequiresConfirmation` comes
    /// from SuperAppMissionControl and forces finalizing actions to go through
    /// the confirmation UI even when the model uses pixels instead of named AX
    /// targets.
    static func classify(
        toolUseBlock: ParsedToolUseBlock,
        previousToolUseBlock: ParsedToolUseBlock? = nil,
        missionRequiresConfirmation: Bool = false,
        upworkStandingSubmissionApproval: Bool = false,
        upworkPreworkArtifactReady: Bool = false
    ) -> AgentSafetyDecision {
        switch toolUseBlock.toolName {
        case "bash":
            return classifyBashCommand(toolUseBlock.inputJSON["command"] as? String ?? "")
        case "computer":
            return classifyComputerAction(
                toolUseBlock.inputJSON,
                previousInputJSON: previousToolUseBlock?.inputJSON,
                missionRequiresConfirmation: missionRequiresConfirmation,
                upworkStandingSubmissionApproval: upworkStandingSubmissionApproval,
                upworkPreworkArtifactReady: upworkPreworkArtifactReady
            )
        case "str_replace_based_edit_tool":
            return classifyTextEditorCall(toolUseBlock.inputJSON)
        default:
            return .auto
        }
    }

    // MARK: - Bash

    private static func classifyBashCommand(_ command: String) -> AgentSafetyDecision {
        let lowercased = command.lowercased()
        let normalizedWhitespaceCommand = lowercased
            .replacingOccurrences(of: "[\\r\\n]+", with: ";", options: .regularExpression)
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        // Hard block — destructive system-wide operations.
        let hardBlockSubstrings = [
            "rm -rf /", "rm -fr /",
            "rm -rf ~", "rm -fr ~",
            "rm -rf $home", "rm -fr $home",
            "rm -rf ${home}", "rm -fr ${home}",
            ":(){ :|:& };:", "mkfs", "dd if=/dev/zero of=/dev/",
            "shutdown -h now", "halt", "diskutil erasedisk"
        ]
        for substring in hardBlockSubstrings {
            if normalizedWhitespaceCommand.contains(substring) {
                return .blocked(reason: "Destructive command detected: \(substring)")
            }
        }
        // Confirm required — risky but legitimate.
        let confirmSubstrings = [
            "rm -rf", "rm -fr", "git push --force", "git push -f",
            "git reset --hard", "git clean -fd", "drop table",
            "drop database", "truncate table", "kill -9", "pkill",
            "sudo ", "chmod 777", "git push ", "osascript ",
            "defaults write", "launchctl ", "networksetup ",
            "dscl ", "chsh ", "curl --request", "curl -x ",
            "wget --post-data", "wget --method"
        ]
        for substring in confirmSubstrings {
            if normalizedWhitespaceCommand.contains(substring) {
                return .confirmRequired(reason: "Risky shell op: \(substring)")
            }
        }
        if commandContainsStandaloneRmInvocation(normalizedWhitespaceCommand) {
            return .confirmRequired(reason: "Risky shell op: rm")
        }
        if commandContainsHTTPMutation(normalizedWhitespaceCommand) {
            return .confirmRequired(reason: "Risky shell op: outbound HTTP mutation")
        }
        return .auto
    }

    private static func commandContainsStandaloneRmInvocation(_ command: String) -> Bool {
        let pattern = "(^|[;&|])\\s*(sudo\\s+)?rm\\s+"
        return command.range(of: pattern, options: .regularExpression) != nil
    }

    private static func commandContainsHTTPMutation(_ command: String) -> Bool {
        let patterns = [
            #"(^|[;&|])\s*curl\b[^\n;|&]*(\s-x\s*|\s--request(=|\s+))(post|put|patch|delete)\b"#,
            #"(^|[;&|])\s*curl\b[^\n;|&]*\s-d\s+"#,
            #"(^|[;&|])\s*wget\b[^\n;|&]*(--post-data|--method=(post|put|patch|delete))"#
        ]
        return patterns.contains { pattern in
            command.range(of: pattern, options: .regularExpression) != nil
        }
    }

    // MARK: - Computer use

    private static func classifyComputerAction(
        _ inputJSON: [String: Any],
        previousInputJSON: [String: Any]?,
        missionRequiresConfirmation: Bool,
        upworkStandingSubmissionApproval: Bool,
        upworkPreworkArtifactReady: Bool
    ) -> AgentSafetyDecision {
        let action = ((inputJSON["action"] as? String) ?? "").lowercased()
        switch action {
        case "quit_app":
            return .confirmRequired(reason: "Quitting an app can lose unsaved work")
        case "close_window":
            return .confirmRequired(reason: "Closing a window can lose unsaved work")
        case "key":
            let combo = normalizedKeyCombo(inputJSON["text"] as? String ?? "")
            if returnLikeKeyCombos.contains(combo),
               previousInputJSON?["action"] as? String == "type" {
                return .confirmRequired(reason: "Typed content followed by a submit key")
            }
            if missionRequiresConfirmation, returnLikeKeyCombos.contains(combo) {
                return .confirmRequired(reason: "Mission requires approval before submit/return")
            }
            if riskyKeyCombos.contains(combo) {
                return .confirmRequired(reason: "Risky key combo: \(combo)")
            }
            return .auto
        case "ax_click":
            let target = ((inputJSON["text"] as? String) ?? "").lowercased()
            if upworkStandingSubmissionApproval,
               upworkSubmissionUITargetWords.contains(where: { target.contains($0) }) {
                return upworkPreworkArtifactReady
                    ? .auto
                    : .blocked(reason: "Upwork standing approval requires a verified pre-application proof artifact before Apply/Submit Proposal")
            }
            if destructiveUITargetWords.contains(where: { target.contains($0) }) {
                return .confirmRequired(reason: "Potentially destructive UI target: \(target)")
            }
            return .auto
        case "left_click", "right_click", "double_click", "drag":
            if missionRequiresConfirmation {
                return .confirmRequired(reason: "Mission requires approval before pixel-based final action")
            }
            return .auto
        default:
            return .auto
        }
    }

    static func yoloCanBypassConfirmation(
        toolUseBlock: ParsedToolUseBlock,
        decision: AgentSafetyDecision
    ) -> Bool {
        guard case .confirmRequired(let reason) = decision else { return false }
        if toolUseBlock.toolName == "bash" || toolUseBlock.toolName == "str_replace_based_edit_tool" {
            return false
        }
        let loweredReason = reason.lowercased()
        let neverBypassSignals = [
            "submit",
            "send",
            "typed content",
            "pixel-based final action",
            "external",
            "destructive",
            "system path",
            "risky shell"
        ]
        return !neverBypassSignals.contains { loweredReason.contains($0) }
    }

    private static func normalizedKeyCombo(_ combo: String) -> String {
        combo
            .lowercased()
            .split(separator: "+")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { part in
                switch part {
                case "command", "meta": return "cmd"
                case "control": return "ctrl"
                case "alt", "option": return "opt"
                case "esc": return "escape"
                case "enter": return "return"
                default: return part
                }
            }
            .joined(separator: "+")
    }

    private static let riskyKeyCombos: Set<String> = [
        "cmd+q",
        "cmd+w",
        "cmd+delete",
        "cmd+backspace",
        "shift+cmd+delete",
        "cmd+shift+delete",
        "cmd+opt+escape"
    ]

    private static let returnLikeKeyCombos: Set<String> = [
        "return",
        "cmd+return",
        "ctrl+return",
        "opt+return",
        "shift+return"
    ]

    private static let destructiveUITargetWords = [
        "accept",
        "apply",
        "apply now",
        "archive",
        "bid",
        "boost",
        "buy",
        "cancel",
        "checkout",
        "close account",
        "confirm",
        "delete",
        "decline",
        "deactivate",
        "discard",
        "erase",
        "log out",
        "logout",
        "pay",
        "post",
        "purchase",
        "remove",
        "reset password",
        "send",
        "send proposal",
        "share",
        "sign contract",
        "subscribe",
        "submit",
        "submit proposal",
        "trash"
    ]

    private static let upworkSubmissionUITargetWords = [
        "apply",
        "apply now",
        "send proposal",
        "submit proposal"
    ]

    // MARK: - Text editor

    private static func classifyTextEditorCall(_ inputJSON: [String: Any]) -> AgentSafetyDecision {
        let path = (inputJSON["path"] as? String) ?? ""
        // Edits to system paths require confirmation.
        let systemPathPrefixes = ["/System/", "/Library/", "/usr/", "/bin/", "/sbin/", "/etc/"]
        for prefix in systemPathPrefixes {
            if path.hasPrefix(prefix) {
                return .confirmRequired(reason: "System path edit: \(path)")
            }
        }
        return .auto
    }
}
