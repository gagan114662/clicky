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
    /// Primary trigger: "clicky agent" (as shown at heyclicky.com).
    /// Secondary triggers: explicit "codex" prefix or strong action phrases.
    static func isAgentTask(_ transcript: String) -> Bool {
        let lower = transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let agentTriggers = [
            // Primary trigger — the official way to invoke agent mode
            "clicky agent",
            "hey clicky agent",
            // Explicit codex invocations
            "codex ",
            "codex,",
            "hey codex",
            // Strong action phrases that imply an autonomous task
            "build me",
            "create a ",
            "make me a",
            "write a script",
            "write a program",
            "generate a ",
            "set up a",
            "browse to",
            "search the web",
        ]
        return agentTriggers.contains { lower.hasPrefix($0) }
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
        onProgressChunk: @escaping @MainActor @Sendable (String) -> Void
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

        var arguments = ["exec", "--json", "--skip-git-repo-check"]
        for screenshotPath in screenshotFilePaths {
            arguments += ["-i", screenshotPath]
        }
        // Working directory defaults to ~/Desktop so created files land somewhere visible
        let workspace = workingDirectory ?? "\(NSHomeDirectory())/Desktop"
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
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw CodexCLIError.processLaunchFailed(error)
        }

        print("🤖 Codex agent started for task: \(prompt.prefix(80))...")

        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            var accumulatedResponseText = ""
            var lineBuffer = ""

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

                    // Streaming text deltas — Codex streams partial output as it works
                    if (eventType == "output_text.delta" || eventType == "response.output_text.delta"),
                       let delta = event["delta"] as? String, !delta.isEmpty {
                        accumulatedResponseText += delta
                        let snapshot = accumulatedResponseText
                        Task { @MainActor in await onProgressChunk(snapshot) }
                    }

                    // Completed message item — the final text for a turn
                    if eventType == "item.completed",
                       let item = event["item"] as? [String: Any],
                       (item["type"] as? String) == "message",
                       let contentArray = item["content"] as? [[String: Any]] {
                        let completedText = contentArray.compactMap { block -> String? in
                            guard let blockType = block["type"] as? String,
                                  blockType == "output_text" || blockType == "text" else { return nil }
                            return block["text"] as? String
                        }.joined()
                        if !completedText.isEmpty {
                            accumulatedResponseText = completedText
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

            process.terminationHandler = { _ in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                guard !resumed else { return }
                resumed = true

                if accumulatedResponseText.isEmpty {
                    continuation.resume(throwing: CodexCLIError.noResponseReceived)
                } else {
                    continuation.resume(returning: accumulatedResponseText)
                }
            }
        }
    }
}
