import Foundation

/// A single tool definition sent to Claude in the `tools` array.
enum AgentToolDefinition {
    case computer(displayWidthPx: Int, displayHeightPx: Int, displayNumber: Int)
    case bash
    case textEditor

    var jsonDictionary: [String: Any] {
        switch self {
        case .computer(let widthPx, let heightPx, let displayNumber):
            return [
                "type": "computer_20250124",
                "name": "computer",
                "display_width_px": widthPx,
                "display_height_px": heightPx,
                "display_number": displayNumber
            ]
        case .bash:
            return ["type": "bash_20250124", "name": "bash"]
        case .textEditor:
            return ["type": "text_editor_20250429", "name": "str_replace_based_edit_tool"]
        }
    }
}

/// A `tool_use` content block parsed from a Claude response.
struct ParsedToolUseBlock: Equatable {
    let toolUseId: String
    let toolName: String
    let inputJSON: [String: Any]

    static func == (left: ParsedToolUseBlock, right: ParsedToolUseBlock) -> Bool {
        left.toolUseId == right.toolUseId &&
        left.toolName == right.toolName &&
        NSDictionary(dictionary: left.inputJSON).isEqual(to: right.inputJSON)
    }
}

/// Result of executing one tool call. Sent back to Claude as a `tool_result` block.
struct ToolExecutionResult {
    let toolUseId: String
    let isError: Bool
    /// Either text-only output, or text plus an image (e.g., screenshot result).
    let textContent: String
    let imageDataIfAny: Data?
}

/// One assistant message returned by the loop. May contain text + zero or more tool_use blocks.
struct ParsedAssistantMessage {
    let textBlocks: [String]
    let toolUseBlocks: [ParsedToolUseBlock]
    let stopReason: String  // "end_turn", "tool_use", "max_tokens", etc.
}

/// Public state of the running agent — observable by the panel UI.
enum AgentRunState: Equatable {
    case idle
    case classifyingRequest
    case capturingScreenshot
    case waitingForClaude
    case executingToolUse(toolName: String)
    case awaitingUserConfirmation(toolName: String, humanReadableSummary: String)
    case finishedWithText(String)
    case failedWithError(String)
}
