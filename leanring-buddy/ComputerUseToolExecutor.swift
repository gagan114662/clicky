import AppKit
import Foundation

/// Executes a single Claude tool_use block by dispatching to the right primitive.
/// All callers must check `AgentSafetyClassifier` first; this executor itself is unsafe.
/// Click actions fly the blue companion cursor to the target via
/// `AgentCursorFlightCoordinator` *before* posting the CGEvent click, so the user
/// sees what is about to happen on the right monitor.
@MainActor
final class ComputerUseToolExecutor {
    private enum CoordinateValidationResult {
        case success(CGPoint)
        case failure(String)
    }

    private let textEditorExecutor = TextEditorToolExecutor()
    /// 10-minute timeout for the agent's bash calls. Most shell ops finish in
    /// well under a second, but the agent is allowed to delegate substantial
    /// coding tasks to Codex via `codex-clicky exec ...`, which can run for
    /// minutes. The default 60-second timeout would kill those mid-run.
    private let bashExecutor = BashToolExecutor(timeoutSeconds: 600)
    private let claudeViewportSize: CGSize
    /// The NSScreen this executor is currently targeting. The agent loop
    /// re-resolves this once per turn so multi-monitor users can switch
    /// screens by moving their mouse between turns.
    private let targetScreen: NSScreen
    private let cursorFlightCoordinator: AgentCursorFlightCoordinator
    private let cuaDriverBackend: CuaDriverBackend

    init(claudeViewportSize: CGSize,
         targetScreen: NSScreen,
         cursorFlightCoordinator: AgentCursorFlightCoordinator,
         cuaDriverBackend: CuaDriverBackend = CuaDriverBackend(isEnabled: false)) {
        self.claudeViewportSize = claudeViewportSize
        self.targetScreen = targetScreen
        self.cursorFlightCoordinator = cursorFlightCoordinator
        self.cuaDriverBackend = cuaDriverBackend
    }

    private var targetScreenFrame: CGRect { targetScreen.frame }

    func execute(toolUseBlock: ParsedToolUseBlock) async -> ToolExecutionResult {
        switch toolUseBlock.toolName {
        case "computer":
            return await executeComputerAction(toolUseBlock: toolUseBlock)
        case "bash":
            let cmd = (toolUseBlock.inputJSON["command"] as? String) ?? ""
            var result = await bashExecutor.runShellCommand(cmd)
            result = ToolExecutionResult(toolUseId: toolUseBlock.toolUseId,
                                         isError: result.isError,
                                         textContent: result.textContent,
                                         imageDataIfAny: nil)
            return result
        case "str_replace_based_edit_tool":
            return await executeTextEditorCall(toolUseBlock: toolUseBlock)
        default:
            return ToolExecutionResult(toolUseId: toolUseBlock.toolUseId,
                                       isError: true,
                                       textContent: "Unknown tool: \(toolUseBlock.toolName)",
                                       imageDataIfAny: nil)
        }
    }

    // MARK: - Computer

    private func executeComputerAction(toolUseBlock: ParsedToolUseBlock) async -> ToolExecutionResult {
        let action = (toolUseBlock.inputJSON["action"] as? String) ?? ""
        let coordinatePair = toolUseBlock.inputJSON["coordinate"] as? [Int]
        let endCoordinatePair = toolUseBlock.inputJSON["end_coordinate"] as? [Int]
        let textArgument = toolUseBlock.inputJSON["text"] as? String

        switch action {
        case "screenshot":
            return await captureScreenshotResult(toolUseId: toolUseBlock.toolUseId)
        case "open_app":
            guard let appName = nonEmpty(textArgument) else {
                return errorResult(toolUseId: toolUseBlock.toolUseId, message: "Missing app name")
            }
            return await executeLocalIntent(.launchOrActivateApp(name: appName), toolUseId: toolUseBlock.toolUseId)
        case "quit_app":
            guard let appName = nonEmpty(textArgument) else {
                return errorResult(toolUseId: toolUseBlock.toolUseId, message: "Missing app name")
            }
            return await executeLocalIntent(.quitApp(name: appName), toolUseId: toolUseBlock.toolUseId)
        case "close_window":
            return await executeLocalIntent(.closeFrontmostWindow, toolUseId: toolUseBlock.toolUseId)
        case "ax_click":
            guard let targetName = nonEmpty(textArgument) else {
                return errorResult(toolUseId: toolUseBlock.toolUseId, message: "Missing accessibility target name")
            }
            return await executeLocalIntent(.clickByName(targetName: targetName), toolUseId: toolUseBlock.toolUseId)
        case "mouse_move":
            switch validatedClaudePoint(coordinatePair, actionName: "mouse_move") {
            case .success(let point):
                let cgPoint = mapToCGHID(point)
                CGEventActions.moveMouse(toGlobalPoint: cgPoint)
                return successResult(toolUseId: toolUseBlock.toolUseId, message: "moved mouse to \(Int(point.x)),\(Int(point.y))")
            case .failure(let message):
                return errorResult(toolUseId: toolUseBlock.toolUseId, message: message)
            }
        case "left_click":
            switch validatedClaudePoint(coordinatePair, actionName: "left_click") {
            case .success(let point):
                let cgHIDPoint = mapToCGHID(point)
                let appKitGlobalPoint = mapToAppKit(point)
                await cursorFlightCoordinator.flyCursor(
                    toGlobalPoint: appKitGlobalPoint,
                    onScreen: targetScreen,
                    speechBubbleText: "click")
                CGEventActions.leftClick(atGlobalPoint: cgHIDPoint)
                try? await Task.sleep(nanoseconds: 120_000_000)
                return successResult(toolUseId: toolUseBlock.toolUseId, message: "clicked \(Int(point.x)),\(Int(point.y))")
            case .failure(let message):
                return errorResult(toolUseId: toolUseBlock.toolUseId, message: message)
            }
        case "right_click":
            switch validatedClaudePoint(coordinatePair, actionName: "right_click") {
            case .success(let point):
                let cgHIDPoint = mapToCGHID(point)
                let appKitGlobalPoint = mapToAppKit(point)
                await cursorFlightCoordinator.flyCursor(
                    toGlobalPoint: appKitGlobalPoint,
                    onScreen: targetScreen,
                    speechBubbleText: "right-click")
                CGEventActions.rightClick(atGlobalPoint: cgHIDPoint)
                try? await Task.sleep(nanoseconds: 120_000_000)
                return successResult(toolUseId: toolUseBlock.toolUseId, message: "right-clicked \(Int(point.x)),\(Int(point.y))")
            case .failure(let message):
                return errorResult(toolUseId: toolUseBlock.toolUseId, message: message)
            }
        case "double_click":
            switch validatedClaudePoint(coordinatePair, actionName: "double_click") {
            case .success(let point):
                let cgHIDPoint = mapToCGHID(point)
                let appKitGlobalPoint = mapToAppKit(point)
                await cursorFlightCoordinator.flyCursor(
                    toGlobalPoint: appKitGlobalPoint,
                    onScreen: targetScreen,
                    speechBubbleText: "double-click")
                CGEventActions.doubleLeftClick(atGlobalPoint: cgHIDPoint)
                try? await Task.sleep(nanoseconds: 160_000_000)
                return successResult(toolUseId: toolUseBlock.toolUseId, message: "double-clicked \(Int(point.x)),\(Int(point.y))")
            case .failure(let message):
                return errorResult(toolUseId: toolUseBlock.toolUseId, message: message)
            }
        case "drag":
            switch (validatedClaudePoint(coordinatePair, actionName: "drag start"),
                    validatedClaudePoint(endCoordinatePair, actionName: "drag end")) {
            case (.success(let startPoint), .success(let endPoint)):
                let appKitStartPoint = mapToAppKit(startPoint)
                let cgStartPoint = mapToCGHID(startPoint)
                let cgEndPoint = mapToCGHID(endPoint)
                await cursorFlightCoordinator.flyCursor(
                    toGlobalPoint: appKitStartPoint,
                    onScreen: targetScreen,
                    speechBubbleText: "drag")
                CGEventActions.leftClickDrag(fromGlobalPoint: cgStartPoint, toGlobalPoint: cgEndPoint)
                try? await Task.sleep(nanoseconds: 180_000_000)
                return successResult(toolUseId: toolUseBlock.toolUseId,
                                     message: "dragged \(Int(startPoint.x)),\(Int(startPoint.y)) to \(Int(endPoint.x)),\(Int(endPoint.y))")
            case (.failure(let message), _), (_, .failure(let message)):
                return errorResult(toolUseId: toolUseBlock.toolUseId, message: message)
            }
        case "type":
            let usedAccessibilityTextInsertion: Bool
            if let text = textArgument {
                switch await cuaDriverBackend.typeText(text) {
                case .handled(let message):
                    try? await Task.sleep(nanoseconds: 140 * 1_000_000)
                    return successResult(toolUseId: toolUseBlock.toolUseId, message: message)
                case .failed(let message):
                    print("⚠️ Cua Driver type_text failed, falling back to local typing: \(message)")
                case .unavailable:
                    break
                }
                usedAccessibilityTextInsertion = CGEventActions.typeText(text)
            } else {
                usedAccessibilityTextInsertion = false
            }
            // Tiny pause after typing so the next [KEY return]/[KEY tab] doesn't
            // race the input field while the framework is still committing chars.
            try? await Task.sleep(nanoseconds: 140 * 1_000_000)
            return successResult(
                toolUseId: toolUseBlock.toolUseId,
                message: usedAccessibilityTextInsertion ? "ok (set focused text field)" : "ok"
            )
        case "key":
            guard let combo = nonEmpty(textArgument) else {
                return errorResult(toolUseId: toolUseBlock.toolUseId, message: "Missing key combo")
            }
            if !CGEventActions.canPressKeyCombo(combo),
               CuaDriverBackend.keyCommand(from: combo) == nil {
                return errorResult(toolUseId: toolUseBlock.toolUseId, message: "Unknown key combo: \(combo)")
            }
            switch await cuaDriverBackend.pressKeyCombo(combo) {
            case .handled(let message):
                try? await Task.sleep(nanoseconds: 80 * 1_000_000)
                return successResult(toolUseId: toolUseBlock.toolUseId, message: message)
            case .failed(let message):
                print("⚠️ Cua Driver key failed, falling back to local key event: \(message)")
            case .unavailable:
                break
            }
            guard CGEventActions.canPressKeyCombo(combo) else {
                return errorResult(toolUseId: toolUseBlock.toolUseId, message: "Unknown key combo: \(combo)")
            }
            CGEventActions.pressKeyCombo(combo)
            // Defensive auto-wait after every key combo. macOS has to settle
            // focus changes (Spotlight opens, dialogs dismiss, return submits
            // forms, app launches transition) before the next [TYPE]/[KEY] can
            // safely fire. Bigger pause for combos that typically open or
            // launch something so Claude doesn't have to remember [WAIT].
            let normalizedCombo = (textArgument ?? "").lowercased()
            let combosThatOpenOrLaunchSomething: Set<String> = [
                "cmd+space",      // Spotlight
                "ctrl+space",     // alternative bindings
                "cmd+option+space",
                "return", "enter",
                "cmd+t",          // new tab — usually triggers focus shift
                "cmd+n",          // new window
                "cmd+o"           // open dialog
            ]
            let postKeyDelayMilliseconds = combosThatOpenOrLaunchSomething.contains(normalizedCombo)
                ? 400
                : 80
            try? await Task.sleep(nanoseconds: UInt64(postKeyDelayMilliseconds) * 1_000_000)
            return successResult(toolUseId: toolUseBlock.toolUseId, message: "ok")
        case "scroll":
            let direction = (toolUseBlock.inputJSON["scroll_direction"] as? String) ?? "down"
            let rawAmount = (toolUseBlock.inputJSON["scroll_amount"] as? Int) ?? 3
            let amount = min(max(rawAmount, 1), 20)
            let unitsPerStep: Int32 = 60
            let totalUnits = Int32(amount) * unitsPerStep * (direction == "up" ? 1 : -1)
            CGEventActions.scrollVertical(byUnits: totalUnits)
            return successResult(toolUseId: toolUseBlock.toolUseId, message: "ok")
        case "wait":
            let rawDurationMs = (toolUseBlock.inputJSON["duration"] as? Int) ?? 500
            let durationMs = min(max(rawDurationMs, 0), 10_000)
            try? await Task.sleep(nanoseconds: UInt64(durationMs) * 1_000_000)
            return successResult(toolUseId: toolUseBlock.toolUseId, message: "ok")
        case "cursor_position":
            let position = NSEvent.mouseLocation
            return successResult(toolUseId: toolUseBlock.toolUseId,
                                 message: "x=\(Int(position.x)),y=\(Int(position.y))")
        default:
            return ToolExecutionResult(toolUseId: toolUseBlock.toolUseId,
                                       isError: true,
                                       textContent: "Unknown computer action: \(action)",
                                       imageDataIfAny: nil)
        }
    }

    private func captureScreenshotResult(toolUseId: String) async -> ToolExecutionResult {
        do {
            // CompanionScreenCaptureUtility already downscales to max 1280 in the
            // longer dimension and returns one entry per connected display.
            let allCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
            // Pick the capture matching this executor's target screen. Match by
            // origin equality (within 1 point tolerance) on displayFrame.
            let matching = allCaptures.first(where: { capture in
                abs(capture.displayFrame.origin.x - targetScreenFrame.origin.x) < 1 &&
                abs(capture.displayFrame.origin.y - targetScreenFrame.origin.y) < 1
            }) ?? allCaptures.first
            guard let chosenCapture = matching else {
                return ToolExecutionResult(toolUseId: toolUseId, isError: true,
                                           textContent: "No screen captured",
                                           imageDataIfAny: nil)
            }
            return ToolExecutionResult(toolUseId: toolUseId, isError: false,
                                       textContent: "screenshot",
                                       imageDataIfAny: chosenCapture.imageData)
        } catch {
            return ToolExecutionResult(toolUseId: toolUseId, isError: true,
                                       textContent: "Screenshot failed: \(error)",
                                       imageDataIfAny: nil)
        }
    }

    // MARK: - Text editor

    private func executeTextEditorCall(toolUseBlock: ParsedToolUseBlock) async -> ToolExecutionResult {
        let command = (toolUseBlock.inputJSON["command"] as? String) ?? ""
        let path = (toolUseBlock.inputJSON["path"] as? String) ?? ""
        switch command {
        case "view":
            let viewRange = toolUseBlock.inputJSON["view_range"] as? [Int]
            let rangeOrNil: (Int, Int)? = (viewRange?.count == 2) ? (viewRange![0], viewRange![1]) : nil
            var result = await textEditorExecutor.executeView(atPath: path, lineRangeIfAny: rangeOrNil)
            result = ToolExecutionResult(toolUseId: toolUseBlock.toolUseId,
                                         isError: result.isError,
                                         textContent: result.textContent,
                                         imageDataIfAny: nil)
            return result
        case "create":
            let fileText = (toolUseBlock.inputJSON["file_text"] as? String) ?? ""
            var result = await textEditorExecutor.executeCreate(atPath: path, contents: fileText)
            result = ToolExecutionResult(toolUseId: toolUseBlock.toolUseId,
                                         isError: result.isError,
                                         textContent: result.textContent,
                                         imageDataIfAny: nil)
            return result
        case "str_replace":
            let oldString = (toolUseBlock.inputJSON["old_str"] as? String) ?? ""
            let newString = (toolUseBlock.inputJSON["new_str"] as? String) ?? ""
            var result = await textEditorExecutor.executeStrReplace(atPath: path,
                                                                    oldString: oldString,
                                                                    newString: newString)
            result = ToolExecutionResult(toolUseId: toolUseBlock.toolUseId,
                                         isError: result.isError,
                                         textContent: result.textContent,
                                         imageDataIfAny: nil)
            return result
        case "insert":
            let lineNumber = (toolUseBlock.inputJSON["insert_line"] as? Int) ?? 0
            let insertedText = (toolUseBlock.inputJSON["new_str"] as? String) ?? ""
            var result = await textEditorExecutor.executeInsert(atPath: path,
                                                                lineNumber: lineNumber,
                                                                insertedText: insertedText)
            result = ToolExecutionResult(toolUseId: toolUseBlock.toolUseId,
                                         isError: result.isError,
                                         textContent: result.textContent,
                                         imageDataIfAny: nil)
            return result
        case "undo_edit":
            var result = await textEditorExecutor.executeUndoEdit(atPath: path)
            result = ToolExecutionResult(toolUseId: toolUseBlock.toolUseId,
                                         isError: result.isError,
                                         textContent: result.textContent,
                                         imageDataIfAny: nil)
            return result
        default:
            return ToolExecutionResult(toolUseId: toolUseBlock.toolUseId,
                                       isError: true,
                                       textContent: "Unknown text editor command: \(command)",
                                       imageDataIfAny: nil)
        }
    }

    // MARK: - Helpers

    private func executeLocalIntent(_ intent: LocalIntent, toolUseId: String) async -> ToolExecutionResult {
        let result = await LocalIntentExecutor.execute(intent)
        switch result {
        case .succeeded(let spokenAcknowledgement):
            return successResult(
                toolUseId: toolUseId,
                message: spokenAcknowledgement.isEmpty ? "ok" : spokenAcknowledgement
            )
        case .failed(let reason):
            return errorResult(toolUseId: toolUseId, message: reason)
        }
    }

    private func validatedClaudePoint(_ pair: [Int]?, actionName: String) -> CoordinateValidationResult {
        guard let pair, pair.count >= 2 else {
            return .failure("Missing coordinate for \(actionName)")
        }

        let point = CGPoint(x: pair[0], y: pair[1])
        guard ScreenCoordinateMapper.isClaudePointInsideViewport(
            point,
            claudeViewportSize: claudeViewportSize
        ) else {
            let maxX = max(Int(claudeViewportSize.width) - 1, 0)
            let maxY = max(Int(claudeViewportSize.height) - 1, 0)
            return .failure("Coordinate \(pair[0]),\(pair[1]) is outside the screenshot viewport. Use x 0...\(maxX), y 0...\(maxY).")
        }

        return .success(point)
    }

    private func mapToCGHID(_ point: CGPoint) -> CGPoint {
        ScreenCoordinateMapper.mapClaudePointToCGHIDPoint(
            claudePoint: point,
            claudeViewportSize: claudeViewportSize,
            targetScreenFrame: targetScreenFrame
        )
    }

    private func mapToAppKit(_ point: CGPoint) -> CGPoint {
        ScreenCoordinateMapper.mapClaudePointToGlobalScreenPoint(
            claudePoint: point,
            claudeViewportSize: claudeViewportSize,
            targetScreenFrame: targetScreenFrame
        )
    }

    private func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func successResult(toolUseId: String, message: String) -> ToolExecutionResult {
        ToolExecutionResult(toolUseId: toolUseId, isError: false,
                            textContent: message, imageDataIfAny: nil)
    }

    private func errorResult(toolUseId: String, message: String) -> ToolExecutionResult {
        ToolExecutionResult(toolUseId: toolUseId, isError: true,
                            textContent: message, imageDataIfAny: nil)
    }
}

// Note: `CompanionScreenCaptureUtility.captureAllScreensAsJPEG()` already
// downscales to max 1280 in the longer dimension, so no separate downscaler
// is needed here. If you find yourself wanting one, you are duplicating that
// utility — go fix the capture path instead.
