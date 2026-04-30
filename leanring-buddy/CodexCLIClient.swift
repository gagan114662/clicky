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

private struct CodexCLIStreamUpdate {
    var threadIDs: [String] = []
    var progressSnapshots: [String] = []
    var errorMessage: String?
}

private final class CodexCLIStreamState: @unchecked Sendable {
    private let lock = NSLock()
    private var hasResumed = false
    private var accumulatedResponseText = ""
    private var lineBuffer = ""
    private var stderrBuffer = ""

    func appendStderrChunk(_ chunk: String) {
        lock.lock()
        stderrBuffer += chunk
        lock.unlock()
    }

    func appendStdoutChunk(_ chunk: String) -> CodexCLIStreamUpdate {
        lock.lock()
        defer { lock.unlock() }

        guard !hasResumed else { return CodexCLIStreamUpdate() }

        lineBuffer += chunk
        var update = CodexCLIStreamUpdate()

        while let newlineIndex = lineBuffer.firstIndex(of: "\n") {
            let line = String(lineBuffer[lineBuffer.startIndex..<newlineIndex])
            lineBuffer = String(lineBuffer[lineBuffer.index(after: newlineIndex)...])

            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let eventData = trimmed.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: eventData) as? [String: Any],
                  let eventType = event["type"] as? String
            else { continue }

            if eventType == "thread.started",
               let threadID = event["thread_id"] as? String, !threadID.isEmpty {
                update.threadIDs.append(threadID)
            }

            if (eventType == "output_text.delta" || eventType == "response.output_text.delta"),
               let delta = event["delta"] as? String, !delta.isEmpty {
                accumulatedResponseText += delta
                update.progressSnapshots.append(accumulatedResponseText)
            }

            if eventType == "item.completed",
               let item = event["item"] as? [String: Any],
               let renderedText = renderCompletedItem(item) {
                appendRenderedText(renderedText)
                update.progressSnapshots.append(accumulatedResponseText)
            }

            if eventType == "error" || eventType == "turn.failed" {
                hasResumed = true
                update.errorMessage = Self.errorMessage(from: event)
                break
            }
        }

        return update
    }

    func finishIfNeeded(exitCode: Int32) -> Result<String, CodexCLIError>? {
        lock.lock()
        defer { lock.unlock() }

        guard !hasResumed else { return nil }
        hasResumed = true

        if accumulatedResponseText.isEmpty {
            let stderrSnippet = stderrBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !stderrSnippet.isEmpty {
                let detail = String(stderrSnippet.suffix(500))
                return .failure(.agentError("codex exit \(exitCode): \(detail)"))
            }
            return .failure(.noResponseReceived)
        }

        return .success(accumulatedResponseText)
    }

    private func appendRenderedText(_ text: String) {
        if accumulatedResponseText.isEmpty {
            accumulatedResponseText = text
        } else {
            accumulatedResponseText += "\n\n" + text
        }
    }

    private func renderCompletedItem(_ item: [String: Any]) -> String? {
        let itemType = item["type"] as? String ?? ""

        switch itemType {
        case "agent_message", "message":
            if let text = item["text"] as? String, !text.isEmpty {
                return text
            }
            if let contentArray = item["content"] as? [[String: Any]] {
                let joined = contentArray.compactMap { block -> String? in
                    guard let blockType = block["type"] as? String,
                          blockType == "output_text" || blockType == "text" else { return nil }
                    return block["text"] as? String
                }.joined()
                return joined.isEmpty ? nil : joined
            }
            return nil

        case "command_execution", "shell_command":
            let commandText: String? = {
                if let command = item["command"] as? String { return command }
                if let command = item["command"] as? [String] { return command.joined(separator: " ") }
                return nil
            }()
            guard let commandText else { return nil }

            var text = "$ \(commandText)"
            if let output = item["aggregated_output"] as? String,
               !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                text += "\n" + output.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return text

        case "file_change", "edit", "patch":
            if let changes = item["changes"] as? [[String: Any]] {
                let lines = changes.compactMap { change -> String? in
                    guard let path = change["path"] as? String else { return nil }
                    let kind = (change["kind"] as? String) ?? "edit"
                    let icon: String = {
                        switch kind {
                        case "add": return "+"
                        case "delete": return "-"
                        default: return "edit"
                        }
                    }()
                    return "\(icon) \(path)"
                }
                return lines.isEmpty ? nil : lines.joined(separator: "\n")
            }
            if let path = item["path"] as? String {
                return "edit \(path)"
            }
            return nil

        case "reasoning":
            return nil

        default:
            if let text = item["text"] as? String, !text.isEmpty {
                return "[\(itemType)] \(text)"
            }
            return nil
        }
    }

    private static func errorMessage(from event: [String: Any]) -> String {
        if let message = event["message"] as? String { return message }
        if let error = event["error"] as? [String: Any],
           let message = error["message"] as? String { return message }
        return "Unknown Codex error"
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
        let lower = normalizedAgentRoutingText(transcript)

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
            "parallel codex", "parallel agent", "parallel session",
            "run 2 sessions", "run two sessions",
            "start 2 sessions", "start two sessions",
            "session 1", "session one", "mission 1", "mission one",
            "task 1", "task one",
            "two codex sessions", "two codex agents",
            "spawn an agent", "spawn agent",
            "fire up an agent", "fire up a codex",
            "launch an agent", "launch a codex",
            "launch two codex", "launch 2 codex",
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
        let lower = normalizedAgentRoutingText(transcript)
        let requestedCount = requestedParallelSessionCount(in: lower)

        // Only consider splitting if the user explicitly mentioned multiple sessions / agents.
        // This avoids splitting "build me a calculator and a button" into two unrelated tasks.
        let multiSessionMarkers = [
            "spawn ",
            "parallel",
            "in parallel",
            "2 sessions", "3 sessions", "4 sessions", "5 sessions",
            "2 agents", "3 agents", "4 agents", "5 agents",
            "2 codex", "3 codex", "4 codex", "5 codex",
            "codex sessions", "codex agents",
            "two sessions", "three sessions", "four sessions", "five sessions",
            "two agents", "three agents", "four agents", "five agents",
            "multiple agents", "multiple sessions",
            "siblings",
            "one for",
            "one to",
            "session 1", "session one", "session 2", "session two",
            "mission 1", "mission one", "mission 2", "mission two",
            "task 1", "task one", "task 2", "task two",
        ]
        let isMultiSession = requestedCount != nil || multiSessionMarkers.contains { lower.contains($0) }
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
        //   • (mission|session|task|agent) (1|2|3|...|one|two|three|...)
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
        let collapsedSplitPattern = #"\b(?:(?:(?:mission|session|task|agent)\s+)(?:[1-9]|one|two|three|four|five|six|seven|eight|nine)|(?:(?:the\s+)?other\s+|another\s+)(?:one|agent|session|task)|one|(?:first|second|third|fourth|fifth)(?:\s+(?:one|agent|session|task))?|[1-9])\b(?:[,.):]\s*(?:(?:to|for)\b\s*)?|\s+(?:(?:is|was|are|were|will|would|should|shall|needs?|has|have|had|can|could|may|might|must|just)\s+)?(?:to|for)\b\s*)"#
        // Use a sentinel that won't appear in spoken transcripts.
        let splitSentinel = "\u{FFFC}"
        var normalized = transcript.replacingOccurrences(
            of: collapsedSplitPattern,
            with: splitSentinel,
            options: [.regularExpression, .caseInsensitive]
        )
        if requestedCount == 2 {
            // Speech often drops the second "one": "two Codex sessions,
            // one to research users and to find funded competitors."
            // In a two-session context, treat that second "and to/for" as
            // the boundary for the other task.
            normalized = normalized.replacingOccurrences(
                of: #"\b(?:and|then)\s+(?:to|for)\b\s*"#,
                with: splitSentinel,
                options: [.regularExpression, .caseInsensitive]
            )
        }

        if normalized.contains(splitSentinel) {
            let taskBoundaryTrimmingCharacters = CharacterSet(charactersIn: " ,.?;:!\n\t")
            let parts = normalized
                .components(separatedBy: splitSentinel)
                .dropFirst() // discard preamble before the first "one for"
                .map { rawTask -> String in
                    var cleaned = rawTask.trimmingCharacters(in: taskBoundaryTrimmingCharacters)
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
                    return cleaned.trimmingCharacters(in: taskBoundaryTrimmingCharacters)
                }
                .filter { !$0.isEmpty }
            if parts.count >= 2 {
                return carryForwardLeadingActionVerbIfNeeded(Array(parts))
            }
        }

        if let requestedCount, requestedCount >= 2 {
            return (1...requestedCount).map { index in
                "Parallel Codex session \(index): confirm this independent Codex session is running and briefly state that it is ready for a follow-up task."
            }
        }

        return [transcript]
    }

    private static func normalizedAgentRoutingText(_ transcript: String) -> String {
        var lower = transcript
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let codexSpeechAliases = [
            #"\bcortex\b"#,
            #"\bcode\s*x\b"#,
            #"\bcodecs\b"#,
            #"\bcodec\b"#,
            #"\bcode\s+exchange\b"#,
        ]
        for alias in codexSpeechAliases {
            lower = lower.replacingOccurrences(
                of: alias,
                with: "codex",
                options: [.regularExpression]
            )
        }
        return lower
    }

    private static func carryForwardLeadingActionVerbIfNeeded(_ parts: [String]) -> [String] {
        guard let firstTask = parts.first,
              let inheritedVerb = leadingActionVerb(in: firstTask)
        else {
            return parts
        }

        return parts.enumerated().map { index, part in
            guard index > 0, leadingActionVerb(in: part) == nil else {
                return part
            }
            return "\(inheritedVerb) \(part)"
        }
    }

    private static func leadingActionVerb(in task: String) -> String? {
        let firstToken = task
            .lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .first
            .map(String.init)
        guard let firstToken else { return nil }

        let actionVerbs: Set<String> = [
            "audit", "build", "check", "compare", "create", "debug",
            "design", "draft", "find", "fix", "generate", "inspect",
            "investigate", "list", "make", "research", "review",
            "search", "summarize", "test", "update", "write",
        ]
        return actionVerbs.contains(firstToken) ? firstToken : nil
    }

    private static func requestedParallelSessionCount(in lower: String) -> Int? {
        let numberWords = [
            "two": 2, "three": 3, "four": 4, "five": 5,
            "six": 6, "seven": 7, "eight": 8, "nine": 9,
        ]
        let numberPattern = #"([2-9]|two|three|four|five|six|seven|eight|nine)"#
        let nounPattern = #"(?:parallel\s+)?(?:codex\s+)?(?:sessions?|agents?|siblings)"#
        let patterns = [
            #"\#(numberPattern)\s+\#(nounPattern)"#,
            #"\#(nounPattern)\s+\#(numberPattern)"#,
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(lower.startIndex..<lower.endIndex, in: lower)
            guard let match = regex.firstMatch(in: lower, range: range), match.numberOfRanges >= 2 else { continue }
            for groupIndex in 1..<match.numberOfRanges {
                guard let groupRange = Range(match.range(at: groupIndex), in: lower) else { continue }
                let token = String(lower[groupRange])
                if let digit = Int(token) {
                    return min(max(digit, 2), 9)
                }
                if let wordValue = numberWords[token] {
                    return wordValue
                }
            }
        }
        return nil
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
        let lower = normalizedAgentRoutingText(transcript)
        let multiSessionMarkers = [
            "spawn ", "parallel", "in parallel",
            "2 sessions", "3 sessions", "2 agents", "3 agents",
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
            let streamState = CodexCLIStreamState()

            // Capture stderr so we can surface real codex error messages when
            // the subprocess exits without producing usable JSONL on stdout.
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
                streamState.appendStderrChunk(chunk)
                // Echo stderr to Xcode console too so the developer can see
                // codex errors live during a session.
                print("🟥 codex stderr: \(chunk.trimmingCharacters(in: .whitespacesAndNewlines))")
            }

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }

                let update = streamState.appendStdoutChunk(chunk)
                for threadID in update.threadIDs {
                    Task { @MainActor in onThreadStarted(threadID) }
                }
                for snapshot in update.progressSnapshots {
                    Task { @MainActor in onProgressChunk(snapshot) }
                }
                if let errorMessage = update.errorMessage {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: CodexCLIError.agentError(errorMessage))
                }
            }

            process.terminationHandler = { terminatedProcess in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                guard let result = streamState.finishIfNeeded(exitCode: terminatedProcess.terminationStatus) else {
                    return
                }
                switch result {
                case .success(let accumulatedResponseText):
                    continuation.resume(returning: accumulatedResponseText)
                case .failure(let error):
                    continuation.resume(throwing: error)
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
            let streamState = CodexCLIStreamState()

            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
                streamState.appendStderrChunk(chunk)
                print("🟥 codex stderr (resume): \(chunk.trimmingCharacters(in: .whitespacesAndNewlines))")
            }

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }

                let update = streamState.appendStdoutChunk(chunk)
                for snapshot in update.progressSnapshots {
                    Task { @MainActor in onProgressChunk(snapshot) }
                }
                if let errorMessage = update.errorMessage {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: CodexCLIError.agentError(errorMessage))
                }
            }

            process.terminationHandler = { terminatedProcess in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                guard let result = streamState.finishIfNeeded(exitCode: terminatedProcess.terminationStatus) else {
                    return
                }
                switch result {
                case .success(let accumulatedResponseText):
                    continuation.resume(returning: accumulatedResponseText)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
