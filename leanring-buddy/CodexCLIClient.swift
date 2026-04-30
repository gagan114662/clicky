//
//  CodexCLIClient.swift
//  leanring-buddy
//
//  Runs the Codex CLI (OpenAI's agent runtime, bundled inside /Applications/Clicky.app)
//  as a subprocess for agent tasks: "build me a website", "create a spreadsheet", etc.
//  Uses the user's existing Codex subscription — no API key required.
//
//  Routing: CompanionManager routes transcripts that start with "codex" here.
//  Everything else goes to ClaudeCodeCLIClient (voice responses).
//

import Foundation

enum CodexCLIError: Error, LocalizedError {
    case binaryNotFound
    case processLaunchFailed(Error)
    case noResponseReceived
    case agentError(String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "Codex CLI not found. Make sure /Applications/Clicky.app is installed."
        case .processLaunchFailed(let underlying):
            return "Failed to launch Codex CLI: \(underlying.localizedDescription)"
        case .noResponseReceived:
            return "Codex exited without producing a response."
        case .agentError(let message):
            return "Codex agent error: \(message)"
        }
    }
}

/// Runs agent tasks using the Codex CLI bundled in /Applications/Clicky.app.
/// Uses the Codex subscription stored at ~/.codex/auth.json — no API key needed.
final class CodexCLIClient {
    /// Saved copy of the newer Codex binary (v0.124.0, supports gpt-5.5 subscription mode).
    private static let savedCodexBinaryPath = "\(NSHomeDirectory())/.local/bin/codex-clicky"
    private static let homebrewCodexBinaryPath = "/opt/homebrew/bin/codex"

    static func findBinaryPath() -> String? {
        // Prefer the saved binary — it's v0.124.0 with gpt-5.5 subscription support.
        // Fall back to the Homebrew install.
        if FileManager.default.isExecutableFile(atPath: savedCodexBinaryPath) {
            return savedCodexBinaryPath
        }
        if FileManager.default.isExecutableFile(atPath: homebrewCodexBinaryPath) {
            return homebrewCodexBinaryPath
        }
        return nil
    }

    static func isAvailable() -> Bool {
        findBinaryPath() != nil
    }

    /// Returns true if the transcript looks like an agent task that Codex should handle.
    ///
    /// Detection is lenient because AssemblyAI sometimes mishears "Clicky" as
    /// "Learning Buddy" / "leaning buddy" / "clicker" / etc. Rules:
    ///   1. If the wake word "agent" appears in the first 6 words of the transcript,
    ///      it's an agent task (covers "Clicky agent ...", "Learning Buddy agent ...",
    ///      "Hey Clicky, agent build me ...", etc.).
    ///   2. Explicit "codex ..." invocations always route to the agent.
    ///   3. Strong autonomous-action prefixes ("build me a ...", "create a ...", etc.)
    ///      route to the agent.
    static func isAgentTask(_ transcript: String) -> Bool {
        let lower = transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Rule 1 — wake word "agent" / "agents" / "codex" near the start of
        // the transcript (broadened to first 8 words to tolerate filler like
        // "uh, start another...").
        let firstWords = lower
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .prefix(8)
        if firstWords.contains("agent") || firstWords.contains("agents") || firstWords.contains("codex") {
            return true
        }

        // Rule 1b — any-position phrases that clearly intend an agent task.
        // Catches "start another Codex session", "fork an agent", "spawn a
        // new session", etc., even when they don't begin the sentence.
        let agentContextPhrases = [
            "codex session", "codex agent", "codex sessions", "codex agents",
            "another codex", "another agent", "another session",
            "new codex", "new agent",
            "spawn an agent", "spawn agent",
            "fire up an agent", "fire up a codex",
            "launch an agent", "launch a codex",
            "start an agent", "start a codex",
            "fork an agent", "fork a codex",
        ]
        if agentContextPhrases.contains(where: { lower.contains($0) }) {
            return true
        }

        // Rules 2 & 3 — explicit invocations and action prefixes.
        let agentTriggers = [
            "codex ",
            "codex,",
            "hey codex",
            "build me",
            "create a ",
            "make me a",
            "write a script",
            "write a program",
            "generate a ",
            "set up a",
            "browse to",
            "search the web",
            "spawn ",
            "launch a codex",
        ]
        return agentTriggers.contains { lower.hasPrefix($0) }
    }

    /// Splits a transcript into N parallel task strings when the user explicitly
    /// asked for multiple sessions / agents. Returns [transcript] for single-task
    /// requests so existing single-agent flows are unchanged.
    ///
    /// Examples:
    ///   "agent, spawn two sessions, one for X and one for Y" → ["X", "Y"]
    ///   "build me three sessions, one for A, one for B, one for C" → ["A", "B", "C"]
    ///   "agent, build me a snake game"  → unchanged (single task)
    static func decomposeTaskIntoParallelTasks(_ transcript: String) -> [String] {
        let lower = transcript.lowercased()

        // Only consider splitting if the user explicitly mentioned multiple sessions / agents.
        // This avoids splitting "build me a calculator and a button" into two unrelated tasks.
        let multiSessionMarkers = [
            "spawn ",
            "parallel",
            "in parallel",
            "two sessions", "three sessions", "four sessions", "five sessions",
            "two agents", "three agents", "four agents", "five agents",
            "multiple agents", "multiple sessions",
            "siblings",
            "one for",
            "one to",
        ]
        let isMultiSession = multiSessionMarkers.contains { lower.contains($0) }
        guard isMultiSession else { return [transcript] }

        // Split on enumeration markers people say in natural English when
        // listing parallel tasks. Matches a marker followed by EITHER:
        //   • required "to" / "for"  ("one to X", "first for X")
        //   • OR explicit punctuation comma/period/colon/paren ("1,", "2.")
        // The punctuation case lets us split "2, how to go..." (where "how"
        // is between marker and "to") without false-matching "2 dogs".
        //
        // Markers (qualified-noun form requires a qualifier; plain "one"
        // and digits are allowed bare; "agent"/"session"/"task" alone are
        // NOT, to avoid matching "the agent" etc.):
        //   • one
        //   • the other (one|agent|session|task)
        //   • another (one|agent|session|task)
        //   • (first|second|third|fourth|fifth) [(one|agent|session|task)]
        //   • [1-9]
        //
        // After the marker, allow ONE optional helper verb between the
        // marker and "to"/"for". Catches:
        //   "the other one IS to make X"
        //   "another one WILL TO do X"
        //   "second one NEEDS to find X"
        let collapsedSplitPattern = #"\b(?:(?:(?:the\s+)?other\s+|another\s+)(?:one|agent|session|task)|one|(?:first|second|third|fourth|fifth)(?:\s+(?:one|agent|session|task))?|[1-9])\b(?:[,.):]\s*(?:(?:to|for)\b\s*)?|\s+(?:(?:is|was|are|were|will|would|should|shall|needs?|has|have|had|can|could|may|might|must|just)\s+)?(?:to|for)\b\s*)"#
        // Use a sentinel that won't appear in spoken transcripts.
        let splitSentinel = "\u{FFFC}"
        let normalized = transcript.replacingOccurrences(
            of: collapsedSplitPattern,
            with: splitSentinel,
            options: [.regularExpression, .caseInsensitive]
        )

        if normalized.contains(splitSentinel) {
            let parts = normalized
                .components(separatedBy: splitSentinel)
                .dropFirst() // discard preamble before the first "one for"
                .map { rawTask -> String in
                    var cleaned = rawTask.trimmingCharacters(in: CharacterSet(charactersIn: " ,.?;:!"))
                    // Strip trailing connectors like "and" or "and then"
                    let trailingConnectors = [" and then", " and"]
                    for connector in trailingConnectors {
                        if cleaned.lowercased().hasSuffix(connector) {
                            cleaned = String(cleaned.dropLast(connector.count))
                        }
                    }
                    // Strip leading filler like "um," / "uh,"
                    let leadingFillers = ["um,", "um ", "uh,", "uh "]
                    for filler in leadingFillers {
                        if cleaned.lowercased().hasPrefix(filler) {
                            cleaned = String(cleaned.dropFirst(filler.count))
                        }
                    }
                    return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                .filter { !$0.isEmpty }
            if parts.count >= 2 {
                return Array(parts)
            }
        }

        return [transcript]
    }

    /// Returns the parallel task list for a transcript. First tries the fast
    /// regex split. If that returns 1 task but the transcript clearly asked
    /// for multiple sessions, falls back to a Haiku call to decompose the
    /// natural-language list into N tasks. ~2-3s for the LLM fallback.
    static func decomposeTaskIntoParallelTasksWithLLMFallback(_ transcript: String) async -> [String] {
        // Fast path — regex
        let regexTasks = decomposeTaskIntoParallelTasks(transcript)
        if regexTasks.count >= 2 { return regexTasks }

        // Did the user explicitly ask for multiple sessions? If not, don't
        // bother burning an LLM call — single-task requests should stay fast.
        let lower = transcript.lowercased()
        let multiSessionMarkers = [
            "spawn ", "parallel", "in parallel",
            "two sessions", "three sessions", "two agents", "three agents",
            "multiple agents", "multiple sessions", "siblings",
            "second agent", "second session",
            "another agent", "another session",
            "two codex", "three codex",
        ]
        let isMultiSession = multiSessionMarkers.contains { lower.contains($0) }
        guard isMultiSession else { return regexTasks }

        // LLM fallback — only fires if regex couldn't split AND user clearly
        // asked for multiple agents. Reliable across any phrasing.
        guard ClaudeCodeCLIClient.isAvailable() else {
            print("🤖 Decompose: LLM fallback unavailable (no Claude CLI), keeping single task")
            return regexTasks
        }

        let client = ClaudeCodeCLIClient(model: "claude-haiku-4-5-20251001")
        let systemPrompt = "You decompose user requests into a list of parallel tasks. Reply with valid JSON only, no markdown fences, no prose."
        let prompt = """
        The user asked an AI assistant to spawn multiple parallel agents. Split this spoken transcript into the individual tasks each agent should do.

        Transcript:
        \(transcript)

        Rules:
        - Return ONLY the actions each agent should perform, in plain English.
        - Strip filler ("uh", "um", "you know"), wake words ("hey clicky", "agent"), meta instructions ("spawn two agents", "make sure they're separate sessions").
        - Each task is a standalone, complete instruction.
        - If the transcript actually only contains one task, return it as-is.

        Examples:
        Input: "spawn two agents, one to research market for Clicky, and the other one is to make a landing page"
        Output: {"tasks": ["research market for Clicky", "make a landing page"]}

        Input: "Start 2 Codex sessions, one to research the prospects for a product like Clicky. And the other one is to make a simple landing page."
        Output: {"tasks": ["research prospects for a product like Clicky", "make a simple landing page"]}

        Input: "agent, build me a snake game"
        Output: {"tasks": ["build me a snake game"]}

        Return ONLY the JSON object:
        """

        print("🤖 Decompose: regex returned 1 task, calling Haiku for LLM decomposition")
        do {
            let (response, _) = try await client.analyzeImageStreaming(
                images: [],
                systemPrompt: systemPrompt,
                conversationHistory: [],
                userPrompt: prompt,
                onTextChunk: { _ in }
            )

            // Strip any leading/trailing chatter — keep just the JSON object
            guard let jsonStart = response.firstIndex(of: "{"),
                  let jsonEnd = response.lastIndex(of: "}"),
                  jsonStart < jsonEnd else {
                print("🤖 Decompose: LLM response had no JSON, keeping regex result")
                return regexTasks
            }
            let jsonStr = String(response[jsonStart...jsonEnd])
            guard let data = jsonStr.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tasks = parsed["tasks"] as? [String], !tasks.isEmpty else {
                print("🤖 Decompose: LLM JSON parse failed, keeping regex result")
                return regexTasks
            }
            print("🤖 Decompose: LLM returned \(tasks.count) task(s)")
            return tasks
        } catch {
            print("🤖 Decompose: LLM call failed: \(error.localizedDescription)")
            return regexTasks
        }
    }

    /// Runs a Codex agent task non-interactively.
    ///
    /// - Parameters:
    ///   - prompt: The task description spoken by the user.
    ///   - screenshots: Screen captures to provide context to the agent.
    ///   - memoryContextBlock: Optional memory context to prepend to the prompt.
    ///   - workingDirectory: Directory the agent will use as its workspace. Defaults to ~/Desktop.
    ///   - onProgressChunk: Called on MainActor with accumulated text as the agent streams output.
    /// - Returns: The final agent response text.
    func runAgentTask(
        prompt: String,
        screenshots: [(data: Data, label: String)],
        memoryContextBlock: String = "",
        workingDirectory: String? = nil,
        onProgressChunk: @escaping @MainActor @Sendable (String) -> Void,
        onThreadStarted: @escaping @MainActor @Sendable (String) -> Void = { _ in },
        onProcessStarted: @escaping @MainActor @Sendable (Process) -> Void = { _ in }
    ) async throws -> String {
        guard let binaryPath = Self.findBinaryPath() else {
            throw CodexCLIError.binaryNotFound
        }

        // Write screenshots to temp files — codex exec takes image paths, not base64
        let tempDir = FileManager.default.temporaryDirectory
        var screenshotFilePaths: [String] = []
        defer {
            // Clean up temp screenshot files after the process exits
            for path in screenshotFilePaths {
                try? FileManager.default.removeItem(atPath: path)
            }
        }

        for (index, screenshot) in screenshots.enumerated() {
            let tempPath = tempDir
                .appendingPathComponent("clicky_codex_screen_\(index)_\(UUID().uuidString).jpg")
                .path
            try screenshot.data.write(to: URL(fileURLWithPath: tempPath))
            screenshotFilePaths.append(tempPath)
        }

        // Prepend memory context so the agent has session awareness
        let fullPrompt: String = {
            if memoryContextBlock.isEmpty { return prompt }
            return "\(memoryContextBlock)\n\n\(prompt)"
        }()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)

        // --full-auto: workspace-write sandbox + auto-approve. Without this
        // codex runs in read-only mode and can't create files, breaking any
        // "build me X" prompt. workspace-write scopes the agent's reads and
        // writes to the working directory, so a contained workspace below
        // keeps Codex out of the rest of the user's filesystem.
        var arguments = ["exec", "--json", "--skip-git-repo-check", "--full-auto"]
        for screenshotPath in screenshotFilePaths {
            arguments += ["-i", screenshotPath]
        }
        // PRIVACY: Default workspace is ~/Desktop/clicky-agents (not ~/Desktop
        // itself) so Codex's workspace-write sandbox can't list or read the
        // rest of the user's Desktop. Created files land in a clearly-labelled
        // subfolder the user can find and clean up.
        let defaultWorkspace = "\(NSHomeDirectory())/Desktop/clicky-agents"
        let workspace = workingDirectory ?? defaultWorkspace
        try? FileManager.default.createDirectory(
            atPath: workspace,
            withIntermediateDirectories: true
        )
        arguments += ["-C", workspace]
        arguments.append(fullPrompt)

        process.arguments = arguments

        // Ensure the binary finds its dependencies regardless of the macOS app sandbox PATH
        var env = ProcessInfo.processInfo.environment
        let extraPaths = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["PATH"] = extraPaths + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        // Use the standard CODEX_HOME so existing auth.json and memories are picked up
        env["CODEX_HOME"] = "\(NSHomeDirectory())/.codex"
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            try? stdinPipe.fileHandleForWriting.close()
        } catch {
            try? stdinPipe.fileHandleForWriting.close()
            throw CodexCLIError.processLaunchFailed(error)
        }

        print("🤖 Codex agent started for task: \(prompt.prefix(80))...")
        let runningProcess = process
        Task { @MainActor in onProcessStarted(runningProcess) }

        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            var accumulatedResponseText = ""
            var lineBuffer = ""
            var stderrBuffer = ""

            // Capture stderr so we can surface real codex error messages when
            // the subprocess exits without producing usable JSONL on stdout.
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
                stderrBuffer += chunk
                // Echo stderr to Xcode console too so the developer can see
                // codex errors live during a session.
                print("🟥 codex stderr: \(chunk.trimmingCharacters(in: .whitespacesAndNewlines))")
            }

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
                lineBuffer += chunk

                // Each JSONL event is newline-terminated
                while let newlineIndex = lineBuffer.firstIndex(of: "\n") {
                    let line = String(lineBuffer[lineBuffer.startIndex..<newlineIndex])
                    lineBuffer = String(lineBuffer[lineBuffer.index(after: newlineIndex)...])

                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty,
                          let eventData = trimmed.data(using: .utf8),
                          let event = try? JSONSerialization.jsonObject(with: eventData) as? [String: Any],
                          let eventType = event["type"] as? String
                    else { continue }

                    // thread.started — emit the codex thread/session ID so the
                    // session can be resumed later for follow-up messages.
                    if eventType == "thread.started",
                       let threadID = event["thread_id"] as? String, !threadID.isEmpty {
                        Task { @MainActor in await onThreadStarted(threadID) }
                    }

                    // Streaming text deltas — Codex streams partial output as it works
                    if (eventType == "output_text.delta" || eventType == "response.output_text.delta"),
                       let delta = event["delta"] as? String, !delta.isEmpty {
                        accumulatedResponseText += delta
                        let snapshot = accumulatedResponseText
                        Task { @MainActor in await onProgressChunk(snapshot) }
                    }

                    // Completed item — codex emits these for agent messages,
                    // tool calls (shell commands, file edits), and reasoning.
                    // We surface them all so the panel shows what the agent
                    // is doing in real time.
                    if eventType == "item.completed",
                       let item = event["item"] as? [String: Any] {
                        let itemType = item["type"] as? String ?? ""
                        var renderedText: String?

                        switch itemType {
                        case "agent_message", "message":
                            // New shape: item.text directly (codex >= 0.124).
                            // Old shape: item.content[].text (legacy).
                            if let text = item["text"] as? String, !text.isEmpty {
                                renderedText = text
                            } else if let contentArray = item["content"] as? [[String: Any]] {
                                let joined = contentArray.compactMap { block -> String? in
                                    guard let blockType = block["type"] as? String,
                                          blockType == "output_text" || blockType == "text" else { return nil }
                                    return block["text"] as? String
                                }.joined()
                                if !joined.isEmpty { renderedText = joined }
                            }

                        case "command_execution", "shell_command":
                            // Tool call running a shell command — show the
                            // command and any aggregated stdout so the user
                            // sees what codex is doing in real time.
                            let cmd: String? = {
                                if let s = item["command"] as? String { return s }
                                if let arr = item["command"] as? [String] { return arr.joined(separator: " ") }
                                return nil
                            }()
                            if let cmd {
                                var text = "$ \(cmd)"
                                if let output = item["aggregated_output"] as? String,
                                   !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    text += "\n" + output.trimmingCharacters(in: .whitespacesAndNewlines)
                                }
                                renderedText = text
                            }

                        case "file_change", "edit", "patch":
                            // Codex emits {path, kind} entries inside `changes`.
                            // Older builds emitted top-level `path`. Handle both.
                            if let changes = item["changes"] as? [[String: Any]] {
                                let lines = changes.compactMap { change -> String? in
                                    guard let path = change["path"] as? String else { return nil }
                                    let kind = (change["kind"] as? String) ?? "edit"
                                    let icon: String = {
                                        switch kind {
                                        case "add": return "+"
                                        case "delete": return "−"
                                        default: return "✎"
                                        }
                                    }()
                                    return "\(icon) \(path)"
                                }
                                if !lines.isEmpty {
                                    renderedText = lines.joined(separator: "\n")
                                }
                            } else if let path = item["path"] as? String {
                                renderedText = "✎ \(path)"
                            }

                        case "reasoning":
                            // Skip reasoning items — too noisy
                            renderedText = nil

                        default:
                            // Unknown item type — log and surface text if any
                            if let text = item["text"] as? String, !text.isEmpty {
                                renderedText = "[\(itemType)] \(text)"
                            }
                        }

                        if let text = renderedText {
                            if accumulatedResponseText.isEmpty {
                                accumulatedResponseText = text
                            } else {
                                accumulatedResponseText += "\n\n" + text
                            }
                            let snapshot = accumulatedResponseText
                            Task { @MainActor in await onProgressChunk(snapshot) }
                        }
                    }

                    // Error events — surface as thrown errors so CompanionManager can respond gracefully
                    if eventType == "error" || eventType == "turn.failed" {
                        let errorMessage: String = {
                            if let msg = event["message"] as? String { return msg }
                            if let errObj = event["error"] as? [String: Any],
                               let msg = errObj["message"] as? String { return msg }
                            return "Unknown Codex error"
                        }()
                        if !resumed {
                            resumed = true
                            stdoutPipe.fileHandleForReading.readabilityHandler = nil
                            continuation.resume(throwing: CodexCLIError.agentError(errorMessage))
                        }
                    }
                }
            }

            process.terminationHandler = { terminatedProcess in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                guard !resumed else { return }
                resumed = true

                if accumulatedResponseText.isEmpty {
                    let stderrSnippet = stderrBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                    let exitCode = terminatedProcess.terminationStatus
                    if !stderrSnippet.isEmpty {
                        let detail = String(stderrSnippet.suffix(500))
                        continuation.resume(throwing: CodexCLIError.agentError("codex exit \(exitCode): \(detail)"))
                    } else {
                        continuation.resume(throwing: CodexCLIError.noResponseReceived)
                    }
                } else {
                    continuation.resume(returning: accumulatedResponseText)
                }
            }
        }
    }

    /// Continues an existing Codex session by ID and sends a follow-up prompt.
    /// Used when the user types or speaks a follow-up in the detail panel.
    func runAgentFollowUp(
        threadID: String,
        prompt: String,
        workingDirectory: String? = nil,
        onProgressChunk: @escaping @MainActor @Sendable (String) -> Void,
        onProcessStarted: @escaping @MainActor @Sendable (Process) -> Void = { _ in }
    ) async throws -> String {
        guard let binaryPath = Self.findBinaryPath() else {
            throw CodexCLIError.binaryNotFound
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)

        var arguments = ["exec", "--json", "--skip-git-repo-check", "--full-auto", "resume", threadID]
        let defaultWorkspace = "\(NSHomeDirectory())/Desktop/clicky-agents"
        let workspace = workingDirectory ?? defaultWorkspace
        try? FileManager.default.createDirectory(
            atPath: workspace,
            withIntermediateDirectories: true
        )
        arguments += ["-C", workspace]
        arguments.append(prompt)
        process.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        let extraPaths = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["PATH"] = extraPaths + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        env["CODEX_HOME"] = "\(NSHomeDirectory())/.codex"
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            try? stdinPipe.fileHandleForWriting.close()
        } catch {
            try? stdinPipe.fileHandleForWriting.close()
            throw CodexCLIError.processLaunchFailed(error)
        }

        print("🔁 Codex follow-up resumed thread \(threadID.prefix(8))… for: \(prompt.prefix(60))")
        let runningProcess = process
        Task { @MainActor in onProcessStarted(runningProcess) }

        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            var accumulatedResponseText = ""
            var lineBuffer = ""
            var stderrBuffer = ""

            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
                stderrBuffer += chunk
                print("🟥 codex stderr (resume): \(chunk.trimmingCharacters(in: .whitespacesAndNewlines))")
            }

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
                lineBuffer += chunk

                while let newlineIndex = lineBuffer.firstIndex(of: "\n") {
                    let line = String(lineBuffer[lineBuffer.startIndex..<newlineIndex])
                    lineBuffer = String(lineBuffer[lineBuffer.index(after: newlineIndex)...])

                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty,
                          let eventData = trimmed.data(using: .utf8),
                          let event = try? JSONSerialization.jsonObject(with: eventData) as? [String: Any],
                          let eventType = event["type"] as? String
                    else { continue }

                    if (eventType == "output_text.delta" || eventType == "response.output_text.delta"),
                       let delta = event["delta"] as? String, !delta.isEmpty {
                        accumulatedResponseText += delta
                        let snapshot = accumulatedResponseText
                        Task { @MainActor in await onProgressChunk(snapshot) }
                    }

                    if eventType == "item.completed",
                       let item = event["item"] as? [String: Any] {
                        let itemType = item["type"] as? String ?? ""
                        var renderedText: String?
                        switch itemType {
                        case "agent_message", "message":
                            if let text = item["text"] as? String, !text.isEmpty {
                                renderedText = text
                            } else if let contentArray = item["content"] as? [[String: Any]] {
                                let joined = contentArray.compactMap { block -> String? in
                                    guard let blockType = block["type"] as? String,
                                          blockType == "output_text" || blockType == "text" else { return nil }
                                    return block["text"] as? String
                                }.joined()
                                if !joined.isEmpty { renderedText = joined }
                            }
                        case "command_execution", "shell_command":
                            let cmd: String? = {
                                if let s = item["command"] as? String { return s }
                                if let arr = item["command"] as? [String] { return arr.joined(separator: " ") }
                                return nil
                            }()
                            if let cmd {
                                var text = "$ \(cmd)"
                                if let output = item["aggregated_output"] as? String,
                                   !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    text += "\n" + output.trimmingCharacters(in: .whitespacesAndNewlines)
                                }
                                renderedText = text
                            }
                        case "file_change", "edit", "patch":
                            if let changes = item["changes"] as? [[String: Any]] {
                                let lines = changes.compactMap { change -> String? in
                                    guard let path = change["path"] as? String else { return nil }
                                    let kind = (change["kind"] as? String) ?? "edit"
                                    let icon: String = kind == "add" ? "+" : (kind == "delete" ? "−" : "✎")
                                    return "\(icon) \(path)"
                                }
                                if !lines.isEmpty { renderedText = lines.joined(separator: "\n") }
                            } else if let path = item["path"] as? String {
                                renderedText = "✎ \(path)"
                            }
                        case "reasoning":
                            renderedText = nil
                        default:
                            if let text = item["text"] as? String, !text.isEmpty {
                                renderedText = "[\(itemType)] \(text)"
                            }
                        }
                        if let text = renderedText {
                            if accumulatedResponseText.isEmpty {
                                accumulatedResponseText = text
                            } else {
                                accumulatedResponseText += "\n\n" + text
                            }
                            let snapshot = accumulatedResponseText
                            Task { @MainActor in await onProgressChunk(snapshot) }
                        }
                    }

                    if eventType == "error" || eventType == "turn.failed" {
                        let errorMessage: String = {
                            if let msg = event["message"] as? String { return msg }
                            if let errObj = event["error"] as? [String: Any],
                               let msg = errObj["message"] as? String { return msg }
                            return "Unknown Codex error"
                        }()
                        if !resumed {
                            resumed = true
                            stdoutPipe.fileHandleForReading.readabilityHandler = nil
                            stderrPipe.fileHandleForReading.readabilityHandler = nil
                            continuation.resume(throwing: CodexCLIError.agentError(errorMessage))
                        }
                    }
                }
            }

            process.terminationHandler = { terminatedProcess in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                guard !resumed else { return }
                resumed = true
                if accumulatedResponseText.isEmpty {
                    let stderrSnippet = stderrBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                    let exitCode = terminatedProcess.terminationStatus
                    if !stderrSnippet.isEmpty {
                        let detail = String(stderrSnippet.suffix(500))
                        continuation.resume(throwing: CodexCLIError.agentError("codex exit \(exitCode): \(detail)"))
                    } else {
                        continuation.resume(throwing: CodexCLIError.noResponseReceived)
                    }
                } else {
                    continuation.resume(returning: accumulatedResponseText)
                }
            }
        }
    }
}
