//
//  ComputerUseAgent.swift
//  leanring-buddy
//
//  Multi-turn agent loop that uses the existing free Claude Code chat path
//  (ClaudeCodeCLIClient subprocess, falling back to the Cloudflare Worker
//  proxy) and a custom action-tag protocol instead of Anthropic's tool_use
//  API. Anthropic's Messages API rejects the Claude Code OAuth token with
//  "OAuth authentication is currently not supported" when `tools` is sent,
//  so we do tool dispatch on top of plain chat: Claude responds with text
//  containing tags like [CLICK x,y] / [TYPE "text"] / [BASH "cmd"] / [DONE
//  message]; we parse, execute, screenshot again, and feed results back as
//  the next user message until [DONE] or max iterations.
//

import AppKit
import Combine
import Foundation

@MainActor
final class ComputerUseAgent: ObservableObject {

    @Published private(set) var runState: AgentRunState = .idle
    /// Pending confirmation that the panel UI must resolve before the loop continues.
    @Published var pendingConfirmation: PendingConfirmation?

    /// Wraps a single agent action that is awaiting user approval.
    struct PendingConfirmation: Identifiable, Equatable {
        let id = UUID()
        let turnID: UUID
        let pendingAction: AgentAction
        let humanReadableSummary: String
    }

    enum ConfirmationResolution: Equatable {
        case approved
        case denied
        case edited(String)
    }

    private let chatClient: any AnthropicChatClient
    private let cursorFlightCoordinator: AgentCursorFlightCoordinator
    private let maxLoopIterations = 30

    init(chatClient: any AnthropicChatClient,
         cursorFlightCoordinator: AgentCursorFlightCoordinator) {
        self.chatClient = chatClient
        self.cursorFlightCoordinator = cursorFlightCoordinator
    }

    /// Resolves a pending confirmation. Called by the panel UI.
    /// `approved=true` means execute the action; `false` means skip and tell Claude.
    var confirmationResolver: ((Bool) -> Void)?
    private var activeTurnID: UUID?
    private var resolvedConfirmationResults: [UUID: ConfirmationResolution] = [:]

    // MARK: - Public entry point

    /// Runs the agent loop for one user instruction. Returns the final text
    /// response (the [DONE] tag's body, or the last assistant text if the model
    /// stops emitting tags before saying [DONE]).
    func runAgentTurn(
        userInstruction: String,
        yoloMode: Bool,
        cuaDriverEnabled: Bool = false,
        missionRequiresConfirmation: Bool = false,
        upworkStandingSubmissionApproval: Bool = false,
        missionContext: String? = nil
    ) async throws -> String {
        try ComputerUsePreflight.assertReadyForAgentRun()

        let turnID = UUID()
        activeTurnID = turnID
        resolvedConfirmationResults.removeAll()
        defer {
            if activeTurnID == turnID {
                clearPendingConfirmation()
                resolvedConfirmationResults.removeAll()
                activeTurnID = nil
                cursorFlightCoordinator.clearAfterTurn()
                runState = .idle
            }
        }

        var conversationHistoryPairs: [(userPlaceholder: String, assistantResponse: String)] = []
        var previousIterationActionResultsMessage: String? = nil
        let upworkPreworkProofRequired = upworkStandingSubmissionApproval &&
            (missionContext?.contains("UPWORK_PREWORK_ARTIFACT_REQUIRED=true") == true)
        var upworkPreworkArtifactReady = !upworkPreworkProofRequired

        for iterationIndex in 0..<maxLoopIterations {
            try Task.checkCancellation()
            guard activeTurnID == turnID else { throw CancellationError() }

            // Re-resolve target screen each iteration so the user can switch
            // monitors mid-turn just by moving the mouse.
            runState = .capturingScreenshot
            let targetScreenForThisIteration = AgentTargetScreenResolver.currentTargetScreen()
            let screenshotCapture = try await captureScreenshot(
                forScreen: targetScreenForThisIteration)
            let claudeViewportSize = CGSize(
                width: screenshotCapture.screenshotWidthInPixels,
                height: screenshotCapture.screenshotHeightInPixels
            )

            let userPromptForThisIteration: String
            if iterationIndex == 0 {
                userPromptForThisIteration = userInstruction
            } else {
                userPromptForThisIteration = (previousIterationActionResultsMessage
                    ?? "Continue. The screenshot shows the result of your previous actions.")
            }

            runState = .waitingForClaude
            FileLogger.log("🤖 Agent iteration \(iterationIndex + 1)/\(maxLoopIterations) — sending to Claude (model=\(chatClient.model)). User prompt: \"\(userPromptForThisIteration.prefix(200))\"")
            let claudeResponseText = try await sendOneChatTurn(
                screenshotData: screenshotCapture.imageData,
                claudeViewportSize: claudeViewportSize,
                conversationHistoryPairs: conversationHistoryPairs,
                userPrompt: userPromptForThisIteration,
                missionContext: missionContext)

            FileLogger.log("🤖 Agent Claude response (\(claudeResponseText.count) chars):\n----\n\(claudeResponseText.prefix(2000))\n----")
            let parsedActions = AgentActionTagParser.parse(claudeResponseText)
            FileLogger.log("🤖 Agent parsed \(parsedActions.count) action tag(s): \(parsedActions.map { describe($0) }.joined(separator: " → "))")
            conversationHistoryPairs.append((userPromptForThisIteration, claudeResponseText))

            if parsedActions.isEmpty {
                // Claude responded with no actionable tags. Treat its text as
                // the final answer and stop. (The conversational fallback path
                // handles this case too — Claude may have answered the question
                // directly, e.g. "the answer is 13".)
                runState = .finishedWithText(claudeResponseText)
                return claudeResponseText
            }

            let executableActions = parsedActions.filter { action in
                if case .done = action { return false }
                return true
            }
            let doneMessageFromThisTurn = parsedActions.compactMap { action -> String? in
                if case .done(let finalMessage) = action { return finalMessage }
                return nil
            }.first

            if executableActions.isEmpty, let doneMessageFromThisTurn {
                let messageOrFallback = doneMessageFromThisTurn.isEmpty
                    ? claudeResponseText
                    : doneMessageFromThisTurn
                FileLogger.log("🤖 Agent final DONE — \(messageOrFallback)")
                runState = .finishedWithText(messageOrFallback)
                return messageOrFallback
            }

            // Build the executor for this iteration with the freshly-resolved screen.
            let executor = ComputerUseToolExecutor(
                claudeViewportSize: claudeViewportSize,
                targetScreen: targetScreenForThisIteration,
                cursorFlightCoordinator: cursorFlightCoordinator,
                cuaDriverBackend: CuaDriverBackend(isEnabled: cuaDriverEnabled))

            var actionResultLines: [String] = []
            var previousToolUseBlockForSafety: ParsedToolUseBlock?
            var shouldStopCurrentActionBatch = false
            for action in executableActions {
                if case .upworkPreworkProof(let summary) = action {
                    if Self.isCredibleUpworkPreworkProof(summary) {
                        upworkPreworkArtifactReady = true
                        actionResultLines.append("• \(describe(action)) → ok: pre-application proof accepted for the next Upwork Apply/Submit Proposal action")
                    } else {
                        actionResultLines.append("• \(describe(action)) → BLOCKED (proof must name visible job material and the concrete diagnostic/work completed before applying)")
                    }
                    continue
                }

                let synthesizedToolUseBlock = synthesizeToolUseBlock(for: action)
                let safetyDecision = AgentSafetyClassifier.classify(
                    toolUseBlock: synthesizedToolUseBlock,
                    previousToolUseBlock: previousToolUseBlockForSafety,
                    missionRequiresConfirmation: missionRequiresConfirmation,
                    upworkStandingSubmissionApproval: upworkStandingSubmissionApproval,
                    upworkPreworkArtifactReady: upworkPreworkArtifactReady)
                let confirmationResolution: ConfirmationResolution
                switch safetyDecision {
                case .auto:
                    confirmationResolution = .approved
                case .blocked(let reason):
                    actionResultLines.append("• \(describe(action)) → BLOCKED (\(reason))")
                    continue
                case .confirmRequired(let reason):
                    if yoloMode,
                       AgentSafetyClassifier.yoloCanBypassConfirmation(
                        toolUseBlock: synthesizedToolUseBlock,
                        decision: safetyDecision
                       ) {
                        confirmationResolution = .approved
                    } else {
                        confirmationResolution = await waitForUserConfirmation(action: action,
                                                                              reason: reason,
                                                                              turnID: turnID)
                    }
                }
                switch confirmationResolution {
                case .approved:
                    break
                case .denied:
                    actionResultLines.append("• \(describe(action)) → user declined")
                    continue
                case .edited(let instruction):
                    actionResultLines.append(
                        "• \(describe(action)) → user edited the approval request. Follow this instead: \(instruction)")
                    shouldStopCurrentActionBatch = true
                    break
                }

                if shouldStopCurrentActionBatch {
                    break
                }

                try Task.checkCancellation()
                guard activeTurnID == turnID else { throw CancellationError() }
                runState = .executingToolUse(toolName: synthesizedToolUseBlock.toolName)
                FileLogger.log("🤖 Agent executing \(describe(action))")
                let executionResult = await executor.execute(toolUseBlock: synthesizedToolUseBlock)
                if Self.shouldRememberForSubmitSafety(synthesizedToolUseBlock) {
                    previousToolUseBlockForSafety = synthesizedToolUseBlock
                }
                if upworkPreworkProofRequired,
                   Self.isUpworkSubmissionClick(synthesizedToolUseBlock),
                   !executionResult.isError {
                    upworkPreworkArtifactReady = false
                }
                let outcomeWord = executionResult.isError ? "ERROR" : "ok"
                let truncatedOutput = executionResult.textContent.count > 600
                    ? String(executionResult.textContent.prefix(600)) + "…"
                    : executionResult.textContent
                FileLogger.log("🤖 Agent action result: \(describe(action)) → \(outcomeWord)\(truncatedOutput.isEmpty ? "" : ": \(truncatedOutput)")")
                actionResultLines.append(
                    "• \(describe(action)) → \(outcomeWord)\(truncatedOutput.isEmpty ? "" : ": \(truncatedOutput)")")
            }

            if let doneMessageFromThisTurn {
                let deferredMessage = doneMessageFromThisTurn.isEmpty
                    ? "model emitted [DONE] in the same turn as actions"
                    : doneMessageFromThisTurn
                actionResultLines.append("• [DONE] deferred until after screenshot verification: \(deferredMessage)")
            }

            previousIterationActionResultsMessage = """
            Action results from your previous tags:
            \(actionResultLines.joined(separator: "\n"))

            A fresh screenshot is attached. Continue with more action tags, or end with [DONE <short summary>].
            """
        }

        runState = .failedWithError("Max iterations reached")
        return "Stopped after \(maxLoopIterations) iterations without [DONE]."
    }

    private static func shouldRememberForSubmitSafety(_ toolUseBlock: ParsedToolUseBlock) -> Bool {
        guard toolUseBlock.toolName == "computer" else { return false }
        let action = ((toolUseBlock.inputJSON["action"] as? String) ?? "").lowercased()
        return action == "type"
    }

    private static func isUpworkSubmissionClick(_ toolUseBlock: ParsedToolUseBlock) -> Bool {
        guard toolUseBlock.toolName == "computer" else { return false }
        let action = ((toolUseBlock.inputJSON["action"] as? String) ?? "").lowercased()
        let target = ((toolUseBlock.inputJSON["text"] as? String) ?? "").lowercased()
        return action == "ax_click" &&
            ["apply", "send proposal", "submit proposal"].contains { target.contains($0) }
    }

    private static func isCredibleUpworkPreworkProof(_ summary: String) -> Bool {
        let cleaned = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count >= 80 else { return false }
        let lowercased = cleaned.lowercased()
        let artifactSignals = [
            "public url", "url", "github", "repo", "repository", "gist",
            "log", "logs", "stack trace", "screenshot", "repro",
            "steps to reproduce", "error", "xcode", "app store rejection",
            "code snippet", "visible"
        ]
        let workSignals = [
            "diagnosed", "diagnosis", "reproduced", "identified", "tested",
            "inspected", "audit", "proof", "fix path", "likely failure",
            "handoff", "patch", "smallest safe fix"
        ]
        return artifactSignals.contains { lowercased.contains($0) } &&
            workSignals.contains { lowercased.contains($0) }
    }

    // MARK: - One chat turn

    private func sendOneChatTurn(
        screenshotData: Data,
        claudeViewportSize: CGSize,
        conversationHistoryPairs: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        missionContext: String?
    ) async throws -> String {
        let screenshotLabel = """
        Current macOS screenshot. Coordinate space is \(Int(claudeViewportSize.width))×\(Int(claudeViewportSize.height)) \
        pixels with origin top-left (x→right, y→down). Use these pixel coordinates for any [CLICK]/[DOUBLECLICK]/[RIGHTCLICK] tags.
        """
        let systemPrompt = [Self.actionTagSystemPrompt, missionContext]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        let (responseText, _) = try await chatClient.analyzeImageStreaming(
            images: [(data: screenshotData, label: screenshotLabel)],
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistoryPairs,
            userPrompt: userPrompt,
            onTextChunk: { _ in
                // We don't need progressive UI for the agent — only the final
                // text matters for tag parsing. Streaming is still used so
                // we honor the protocol.
            }
        )
        return responseText
    }

    // MARK: - Screenshot

    private func captureScreenshot(forScreen targetScreen: NSScreen) async throws -> CompanionScreenCapture {
        let allCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
        let matchingCapture = allCaptures.first(where: { capture in
            abs(capture.displayFrame.origin.x - targetScreen.frame.origin.x) < 1 &&
            abs(capture.displayFrame.origin.y - targetScreen.frame.origin.y) < 1
        }) ?? allCaptures.first
        guard let capture = matchingCapture else {
            throw NSError(domain: "ComputerUseAgent", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No screen captured"])
        }
        return capture
    }

    // MARK: - Confirmation

    func resolvePendingConfirmation(id: UUID, approved: Bool) {
        resolvePendingConfirmation(
            id: id,
            resolution: approved ? .approved : .denied
        )
    }

    func resolvePendingConfirmation(id: UUID, editInstruction: String) {
        let trimmedInstruction = editInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInstruction.isEmpty else {
            FileLogger.log("⚠️ Agent ignoring empty edited confirmation \(id)")
            return
        }
        resolvePendingConfirmation(id: id, resolution: .edited(trimmedInstruction))
    }

    private func resolvePendingConfirmation(
        id: UUID,
        resolution: ConfirmationResolution
    ) {
        guard pendingConfirmation?.id == id else {
            FileLogger.log("⚠️ Agent ignoring stale confirmation \(id)")
            return
        }
        resolvedConfirmationResults[id] = resolution
        clearPendingConfirmation(id: id)
    }

    private func waitForUserConfirmation(action: AgentAction,
                                         reason: String,
                                         turnID: UUID) async -> ConfirmationResolution {
        guard activeTurnID == turnID, !Task.isCancelled else { return .denied }

        let summary = "\(describe(action)) — \(reason)"
        runState = .awaitingUserConfirmation(toolName: synthesizeToolUseBlock(for: action).toolName,
                                             humanReadableSummary: summary)
        FileLogger.log("🛑 Agent confirmation needed: \(summary)")
        let pending = PendingConfirmation(turnID: turnID,
                                          pendingAction: action,
                                          humanReadableSummary: summary)
        pendingConfirmation = pending
        confirmationResolver = { [weak self] approved in
            self?.resolvePendingConfirmation(id: pending.id, approved: approved)
        }
        NotificationCenter.default.post(name: .agentPendingConfirmationChanged, object: nil)

        while activeTurnID == turnID {
            if Task.isCancelled {
                clearPendingConfirmation(id: pending.id)
                return .denied
            }
            if let resolution = resolvedConfirmationResults.removeValue(forKey: pending.id) {
                return resolution
            }
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch {
                clearPendingConfirmation(id: pending.id)
                return .denied
            }
        }
        clearPendingConfirmation(id: pending.id)
        return .denied
    }

    private func clearPendingConfirmation(id: UUID? = nil) {
        if let id, pendingConfirmation?.id != id {
            return
        }
        let hadPendingConfirmation = pendingConfirmation != nil || confirmationResolver != nil
        pendingConfirmation = nil
        confirmationResolver = nil
        if hadPendingConfirmation {
            NotificationCenter.default.post(name: .agentPendingConfirmationChanged, object: nil)
        }
    }

    // MARK: - AgentAction → ParsedToolUseBlock adapter

    /// Translates an `AgentAction` into the `ParsedToolUseBlock` the existing
    /// executor + safety classifier already understand. This lets us reuse all
    /// the tool-use plumbing (cursor flight, coord mapping, undo stack, etc.)
    /// without forking a parallel execution path.
    private func synthesizeToolUseBlock(for action: AgentAction) -> ParsedToolUseBlock {
        let stableId = "tag-\(UUID().uuidString)"
        switch action {
        case .mouseMove(let x, let y):
            return ParsedToolUseBlock(toolUseId: stableId, toolName: "computer",
                                      inputJSON: ["action": "mouse_move", "coordinate": [x, y]])
        case .click(let x, let y):
            return ParsedToolUseBlock(toolUseId: stableId, toolName: "computer",
                                      inputJSON: ["action": "left_click", "coordinate": [x, y]])
        case .doubleClick(let x, let y):
            return ParsedToolUseBlock(toolUseId: stableId, toolName: "computer",
                                      inputJSON: ["action": "double_click", "coordinate": [x, y]])
        case .rightClick(let x, let y):
            return ParsedToolUseBlock(toolUseId: stableId, toolName: "computer",
                                      inputJSON: ["action": "right_click", "coordinate": [x, y]])
        case .drag(let startX, let startY, let endX, let endY):
            return ParsedToolUseBlock(toolUseId: stableId, toolName: "computer",
                                      inputJSON: ["action": "drag",
                                                  "coordinate": [startX, startY],
                                                  "end_coordinate": [endX, endY]])
        case .type(let text):
            return ParsedToolUseBlock(toolUseId: stableId, toolName: "computer",
                                      inputJSON: ["action": "type", "text": text])
        case .key(let combo):
            return ParsedToolUseBlock(toolUseId: stableId, toolName: "computer",
                                      inputJSON: ["action": "key", "text": combo])
        case .scroll(let direction, let amount):
            return ParsedToolUseBlock(toolUseId: stableId, toolName: "computer",
                                      inputJSON: ["action": "scroll",
                                                  "scroll_direction": direction.rawValue,
                                                  "scroll_amount": amount])
        case .accessibilityClick(let name):
            return ParsedToolUseBlock(toolUseId: stableId, toolName: "computer",
                                      inputJSON: ["action": "ax_click", "text": name])
        case .openApp(let name):
            return ParsedToolUseBlock(toolUseId: stableId, toolName: "computer",
                                      inputJSON: ["action": "open_app", "text": name])
        case .quitApp(let name):
            return ParsedToolUseBlock(toolUseId: stableId, toolName: "computer",
                                      inputJSON: ["action": "quit_app", "text": name])
        case .closeWindow:
            return ParsedToolUseBlock(toolUseId: stableId, toolName: "computer",
                                      inputJSON: ["action": "close_window"])
        case .bash(let command):
            return ParsedToolUseBlock(toolUseId: stableId, toolName: "bash",
                                      inputJSON: ["command": command])
        case .fileView(let path):
            return ParsedToolUseBlock(toolUseId: stableId, toolName: "str_replace_based_edit_tool",
                                      inputJSON: ["command": "view", "path": path])
        case .fileCreate(let path, let contents):
            return ParsedToolUseBlock(toolUseId: stableId, toolName: "str_replace_based_edit_tool",
                                      inputJSON: ["command": "create", "path": path, "file_text": contents])
        case .fileReplace(let path, let oldString, let newString):
            return ParsedToolUseBlock(toolUseId: stableId, toolName: "str_replace_based_edit_tool",
                                      inputJSON: ["command": "str_replace",
                                                  "path": path,
                                                  "old_str": oldString,
                                                  "new_str": newString])
        case .upworkPreworkProof:
            return ParsedToolUseBlock(toolUseId: stableId, toolName: "noop", inputJSON: [:])
        case .wait(let milliseconds):
            return ParsedToolUseBlock(toolUseId: stableId, toolName: "computer",
                                      inputJSON: ["action": "wait", "duration": milliseconds])
        case .screenshot:
            return ParsedToolUseBlock(toolUseId: stableId, toolName: "computer",
                                      inputJSON: ["action": "screenshot"])
        case .done:
            // Done is intercepted in the loop and never executed via a tool block.
            return ParsedToolUseBlock(toolUseId: stableId, toolName: "noop", inputJSON: [:])
        }
    }

    /// Short human-readable description used in confirmation prompts and result lines.
    private func describe(_ action: AgentAction) -> String {
        switch action {
        case .mouseMove(let x, let y): return "move mouse to (\(x),\(y))"
        case .click(let x, let y): return "click at (\(x),\(y))"
        case .doubleClick(let x, let y): return "double-click at (\(x),\(y))"
        case .rightClick(let x, let y): return "right-click at (\(x),\(y))"
        case .drag(let startX, let startY, let endX, let endY):
            return "drag from (\(startX),\(startY)) to (\(endX),\(endY))"
        case .type(let text):
            let preview = text.count > 40 ? String(text.prefix(40)) + "…" : text
            return "type \"\(preview)\""
        case .key(let combo): return "press \(combo)"
        case .scroll(let direction, let amount): return "scroll \(direction.rawValue) \(amount)"
        case .accessibilityClick(let name): return "click named UI element \"\(name)\""
        case .openApp(let name): return "open \(name)"
        case .quitApp(let name): return "quit \(name)"
        case .closeWindow: return "close frontmost window"
        case .bash(let command):
            let preview = command.count > 60 ? String(command.prefix(60)) + "…" : command
            return "bash: \(preview)"
        case .fileView(let path): return "view file \(path)"
        case .fileCreate(let path, _): return "create file \(path)"
        case .fileReplace(let path, _, _): return "edit file \(path)"
        case .upworkPreworkProof(let summary):
            let preview = summary.count > 80 ? String(summary.prefix(80)) + "…" : summary
            return "record Upwork prework proof \"\(preview)\""
        case .wait(let ms): return "wait \(ms)ms"
        case .screenshot: return "screenshot"
        case .done: return "done"
        }
    }

    // MARK: - System prompt

    private static let actionTagSystemPrompt: String = """
    You are iPOP, an autonomous macOS computer-use agent. You are NOT a chatbot. You are NOT a coding assistant. You do NOT explain things to the user. You do NOT give instructions. You do NOT ask the user to click anything. The user has authorized you to act on their Mac and will see the result of your actions directly.

    YOUR ENTIRE OUTPUT MUST BE ACTION TAGS, OPTIONALLY PRECEDED BY ONE BRIEF LINE OF PLAN.

    You will receive a screenshot of the user's macOS screen. You control the mouse, keyboard, shell, and file system by emitting these tags inline in your reply. Multiple tags in one reply execute in order. After each reply you will receive a fresh screenshot plus a result line per tag, then you continue with more tags until the task is finished — at which point you MUST end with [DONE <one-sentence summary>].

    Important completion rule: if your reply contains any screen-changing action tag such as [CLICK], [TYPE], [KEY], [OPEN_APP], [AX_CLICK], [SCROLL], [DRAG], [BASH], or file edit tags, do NOT include [DONE] in that same reply. Wait for the next screenshot/result turn, verify the outcome, then emit [DONE ...] by itself.

    Action tag syntax — case-insensitive, always inside square brackets:

      [CLICK x,y]                       Left-click at (x,y) in the screenshot's pixel space (top-left origin).
      [MOUSE_MOVE x,y]                  Move the pointer without clicking.
      [DOUBLECLICK x,y]                 Double left-click at (x,y).
      [RIGHTCLICK x,y]                  Right-click at (x,y).
      [DRAG x1,y1 x2,y2]                Drag from one screenshot coordinate to another.
      [AX_CLICK "name"]                 Press a named macOS Accessibility element in the frontmost app. Prefer this for menus, buttons, tabs, and links with visible names.
      [OPEN_APP "AppName"]              Launch or activate an app through native macOS APIs. Prefer this over Spotlight.
      [QUIT_APP "AppName"]              Quit an app through native macOS APIs. This may require confirmation.
      [CLOSE_WINDOW]                    Close the frontmost window. This may require confirmation.
      [TYPE "text"]                     Type the literal text. Use \\" for a literal quote.
      [KEY combo]                       Press a keyboard combo. e.g. [KEY cmd+space] [KEY return] [KEY escape] [KEY cmd+t] [KEY tab]. Modifiers: cmd / ctrl / shift / option.
      [SCROLL up 3]                     Scroll up/down N "clicks" (default 3).
      [BASH "command"]                  Run a shell command (stdout/stderr/exit returned next turn).
      [FILE_VIEW path]                  Read file contents.
      [FILE_CREATE path "contents"]     Create or overwrite a file.
      [FILE_REPLACE path "old" "new"]   Replace 'old' (must be unique in file) with 'new'.
      [UPWORK_PREWORK_PROOF "summary"]  Use only after inspecting visible Upwork job material and doing concrete pre-application diagnostic work. The summary must name the visible artifact and the proof/work completed.
      [WAIT ms]                         Sleep N milliseconds (use after launching an app so it can render).
      [DONE summary]                    REQUIRED final tag. Marks the task complete with a short summary.

    Output rules — read carefully, these are NOT suggestions:

    1. NEVER respond with prose like "I'll click the button" or "First, you should…" or "Click the calculator icon". Those words DO NOTHING. Only tags do something.
    2. NEVER describe what's on the screenshot in prose. Just act.
    3. NEVER tell the user to do anything themselves. You are the one acting.
    4. Prefer native semantic actions before pixels: use [OPEN_APP "AppName"] to open apps, [AX_CLICK "Name"] for visible named buttons/menus/tabs, and coordinates only when no reliable name exists.
    5. Coordinates are in the attached screenshot's pixel space. Look at the screenshot, identify the target, estimate (x, y). Never use coordinates outside the screenshot dimensions. If a target may have moved, take one more verified step instead of clicking from memory.
    6. macOS-specific shortcuts you may use:
         - [OPEN_APP "AppName"] is the most reliable way to launch apps.
         - [KEY cmd+space] opens Spotlight as a fallback. Then [TYPE "AppName"] then [KEY return] launches the app.
         - The runtime auto-pauses ~400ms after Spotlight, return, cmd+t, cmd+n, etc., so you usually do NOT need an explicit [WAIT] between cmd+space → type → return.
         - DO add [WAIT 800] right AFTER an app finishes launching (after the [KEY return] that submits Spotlight) so the app has time to render its window before you start clicking inside it.
         - [KEY cmd+w] closes a tab; [KEY cmd+t] opens a new tab; [KEY cmd+l] focuses the address bar.

    7. Delegating substantial coding work to Codex: when the user asks for a non-trivial software-engineering task — e.g. "build me a React landing page", "refactor this module", "write a Python script that scrapes X", "fix the failing tests in this repo" — DO NOT try to type code into an editor by hand. Shell out to Codex via the bash tool:

       [BASH "codex-clicky exec --skip-git-repo-check --sandbox workspace-write -C ~/Desktop \\"<task description>\\""]

       Codex will run autonomously (it has its own model, sandbox, and file-write permissions), often for 1–5 minutes, and return its result text on stdout. Keep the prompt to Codex tight and self-contained — Codex won't see your screenshot or our conversation. After Codex returns, summarize for the user with [DONE].

       If the task is small enough to do directly via [TYPE] / [KEY] / [BASH] yourself (open an app, fill a form, run a one-liner), do it yourself — Codex is overhead for trivial work.
    8. For third-party messages, applications, payments, deletes, account changes, or anything external/irreversible: prepare the draft/form when useful, then let the confirmation system gate the final Send/Submit/Pay/Delete/Apply action. Exception: if the internal mission context explicitly says STANDING_UPWORK_SUBMISSION_APPROVAL=granted, you may use named Upwork Apply/Submit Proposal buttons only after the same run has emitted an accepted [UPWORK_PREWORK_PROOF "..."] for that job. The proof must come from visible code, logs, screenshots, public URLs, repro steps, code snippets, public repos, or equivalent public artifacts. Still stop on login, 2FA, captcha, billing, boost/bid-extra-connects, buying connects, accepting offers/contracts, off-platform contact, calls/meetings, no-artifact jobs, or unverifiable claims. Never bypass confirmation by using keyboard shortcuts or vague buttons.
    9. For broad tasks, follow the internal mission plan. Verify each step from the live app state and recover by using app-specific controls, search, address bars, sidebars, or named buttons.
    10. If you're truly stuck (target not visible after a few iterations, ambiguous request), end with [DONE <short reason>] rather than thrashing.

    EXAMPLE — user says: "open Calculator and compute 7+6"

    Your first reply:

    [OPEN_APP "Calculator"][WAIT 800][TYPE "7+6"][KEY return]

    Your next reply after the fresh screenshot verifies the result:

    [DONE Calculator shows 13]

    EXAMPLE — user says: "click the maximize button on the foreground window"

    Your first reply (after looking at the screenshot to find the green "+" traffic-light at the top-left of the foreground window, e.g. at (62, 18)):

    [CLICK 62,18]

    Your next reply after verification:

    [DONE maximized foreground window]

    EXAMPLE — user says: "delete /tmp/old-notes.txt"

    Your first reply:

    [BASH "rm /tmp/old-notes.txt"]

    Your next reply after confirmation/execution result:

    [DONE removed /tmp/old-notes.txt]

    Now begin. The user's instruction follows.
    """
}

// Defined here so this file compiles standalone.
extension Notification.Name {
    static let agentPendingConfirmationChanged = Notification.Name("agentPendingConfirmationChanged")
}
