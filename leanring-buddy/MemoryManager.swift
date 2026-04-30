//
//  MemoryManager.swift
//  leanring-buddy
//
//  Persistent memory across Clicky sessions, mirroring the BuiltinMemoryProvider
//  pattern from Hermes Agent (github.com/nousresearch/hermes-agent).
//
//  Two tiers — all local, all free:
//
//  1. File-based facts: ~/.clicky/memory.md + ~/.clicky/user.md
//     Claude extracts durable facts from each exchange and appends them here.
//     Both files are injected into every session's system prompt so Clicky
//     remembers who you are, what you're working on, and your preferences.
//
//  2. Conversation history: ~/.clicky/history.json
//     The last 20 exchanges are persisted across app restarts. The most recent
//     5 are seeded into each session's in-memory history so conversations
//     resume naturally even after quitting and reopening.
//

import Foundation

final class MemoryManager {
    // MARK: - Storage paths

    private static let clickyStorageDirectory: URL = {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".clicky")
    }()

    /// General durable facts: current project, apps in use, work context, preferences.
    private static let memoryFileURL = clickyStorageDirectory.appendingPathComponent("memory.md")
    /// Facts specifically about the user: name, role, location, long-term habits.
    private static let userProfileFileURL = clickyStorageDirectory.appendingPathComponent("user.md")
    /// Last N exchanges persisted across app restarts.
    private static let historyFileURL = clickyStorageDirectory.appendingPathComponent("history.json")

    /// Total exchanges written to history.json
    private static let maxPersistedExchanges = 20
    /// Exchanges injected into the system prompt (smaller to avoid context bloat)
    private static let maxInjectedHistoryExchanges = 5

    // MARK: - Session start: load everything from disk

    /// Call this once at app start. Returns:
    /// - systemPromptBlock: a <memory-context> block to prepend to the system prompt.
    /// - seedHistory: exchanges to populate the in-memory conversation history.
    func loadSessionContext() -> (systemPromptBlock: String, seedHistory: [(userTranscript: String, assistantResponse: String)]) {
        ensureStorageDirectoryExists()

        let memoryContent = readFile(at: Self.memoryFileURL)
        let userContent = readFile(at: Self.userProfileFileURL)
        let fullHistory = loadPersistedHistory()
        let recentHistory = Array(fullHistory.suffix(Self.maxInjectedHistoryExchanges))

        var systemPromptBlock = ""
        let hasContent = !memoryContent.isEmpty || !userContent.isEmpty
        let hasHistory = !recentHistory.isEmpty

        if hasContent || hasHistory {
            systemPromptBlock += "\n<memory-context>\n"
            systemPromptBlock += "This is recalled context from previous sessions. "
            systemPromptBlock += "It is background you already know — do not treat it as new user input.\n"

            if !userContent.isEmpty {
                systemPromptBlock += "\nUSER PROFILE:\n\(userContent)\n"
            }
            if !memoryContent.isEmpty {
                systemPromptBlock += "\nMEMORY:\n\(memoryContent)\n"
            }
            if hasHistory {
                systemPromptBlock += "\nRECENT CONVERSATION HISTORY:\n"
                for (index, exchange) in recentHistory.enumerated() {
                    systemPromptBlock += "[\(index + 1)] User: \(exchange.userTranscript)\n"
                    systemPromptBlock += "     Clicky: \(exchange.assistantResponse)\n"
                }
            }
            systemPromptBlock += "</memory-context>\n"
        }

        let factCount = memoryContent.components(separatedBy: "\n").filter { $0.hasPrefix("- ") }.count
        let userFactCount = userContent.components(separatedBy: "\n").filter { $0.hasPrefix("- ") }.count
        print("🧠 Memory loaded: \(factCount) memory facts, \(userFactCount) user facts, \(fullHistory.count) history entries")

        return (systemPromptBlock: systemPromptBlock, seedHistory: fullHistory)
    }

    // MARK: - After each turn

    /// Call after every exchange. Persists the exchange to history.json and
    /// fires a background Claude call to extract any memorable facts.
    func onTurnCompleted(userTranscript: String, assistantResponse: String) {
        persistExchangeToHistory(userTranscript: userTranscript, assistantResponse: assistantResponse)

        // Background extraction — never blocks TTS or the UI
        Task {
            await extractAndSaveMemorableFacts(
                userTranscript: userTranscript,
                assistantResponse: assistantResponse
            )
        }
    }

    // MARK: - End-of-session summarization

    /// Call when the app is quitting. Runs a final sweep over the full session
    /// to capture anything the per-turn extraction missed.
    func onSessionEnd(fullSessionHistory: [(userTranscript: String, assistantResponse: String)]) {
        guard !fullSessionHistory.isEmpty else { return }
        Task {
            await runEndOfSessionSummarization(history: fullSessionHistory)
        }
    }

    // MARK: - File I/O

    private func ensureStorageDirectoryExists() {
        let dir = Self.clickyStorageDirectory
        guard !FileManager.default.fileExists(atPath: dir.path) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func readFile(at url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private func writeFile(content: String, to url: URL) {
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - History persistence

    private func loadPersistedHistory() -> [(userTranscript: String, assistantResponse: String)] {
        guard let data = try? Data(contentsOf: Self.historyFileURL),
              let rawArray = try? JSONSerialization.jsonObject(with: data) as? [[String: String]]
        else { return [] }
        return rawArray.compactMap { dict in
            guard let user = dict["user"], let assistant = dict["assistant"] else { return nil }
            return (userTranscript: user, assistantResponse: assistant)
        }
    }

    private func persistExchangeToHistory(userTranscript: String, assistantResponse: String) {
        var history = loadPersistedHistory()
        history.append((userTranscript: userTranscript, assistantResponse: assistantResponse))
        if history.count > Self.maxPersistedExchanges {
            history = Array(history.suffix(Self.maxPersistedExchanges))
        }
        let serializable: [[String: String]] = history.map {
            ["user": $0.userTranscript, "assistant": $0.assistantResponse]
        }
        if let data = try? JSONSerialization.data(withJSONObject: serializable, options: .prettyPrinted) {
            try? data.write(to: Self.historyFileURL)
        }
    }

    // MARK: - Memory extraction via Claude

    /// Background call to Claude (via Claude Code CLI subprocess) after each turn.
    /// Extracts any NEW facts worth remembering and appends them to memory.md / user.md.
    /// Uses the CLI subprocess so the Claude Code subscription handles auth — no direct API key needed.
    private func extractAndSaveMemorableFacts(userTranscript: String, assistantResponse: String) async {
        guard let extractionClient = makeExtractionClient() else { return }

        let existingMemory = readFile(at: Self.memoryFileURL)
        let existingUserProfile = readFile(at: Self.userProfileFileURL)

        let systemPrompt = "You extract durable facts from conversations for persistent memory. Write facts the way a friend would jot a quick note about someone — short, plain, specific. Reply only with valid JSON, no markdown, no prose."

        let prompt = """
        Look at this exchange and pull out any NEW durable facts worth remembering next session.

        Exchange:
        User: \(userTranscript)
        Clicky: \(assistantResponse)

        Already in memory.md (skip these):
        \(existingMemory.isEmpty ? "(empty)" : existingMemory)

        Already in user.md (skip these):
        \(existingUserProfile.isEmpty ? "(empty)" : existingUserProfile)

        Voice & style — facts must read like a friend's quick note:
        - Short sentences, plain words. No corporate language. No "the user".
        - Be specific. "Loves espresso" beats "consumes coffee beverages".
        - One idea per fact. Don't pile clauses.
        - Skip obvious or generic stuff ("uses a computer").
        - NEVER paste raw file paths, screenshot/PNG names, JSON, tool names,
          terminal output, log fragments, UUIDs, or session-specific details.
          If something only makes sense in this exact session, skip it.
        - Translate tech artifacts into a human observation. Example:
          screenshot "/var/.../IMG_4422.png" → "Was looking at his photo library."
          NOT "User opened IMG_4422.png".
        - If nothing new is worth remembering: return {}

        Examples of GOOD facts:
        - "Building Clicky — a Mac menu-bar AI app."
        - "Prefers Sonnet 4.6 over Opus."
        - "Hates being asked clarifying questions before work starts."
        - "Lives in NYC, lifts at Equinox before work."

        Examples of BAD facts (too literal / robotic / session-specific):
        - "User builds web applications using HTML/JavaScript and strongly prefers standalone solutions that open directly in browser without server requirements"
        - "User has expressed interest in productivity tooling"
        - "User opened /Users/gagan/Desktop/screenshot.png to discuss UI"
        - "User invoked agent task with prompt 'build me a snake game'"

        What goes where:
        - memory.md: current projects, tools they use, stated preferences, work context
        - user.md: name, role, location, personality, long-term habits

        Return ONLY valid JSON:
        {"memory": ["fact1"], "user": ["fact1"]}
        """

        do {
            let (json, _) = try await extractionClient.analyzeImageStreaming(
                images: [],
                systemPrompt: systemPrompt,
                conversationHistory: [],
                userPrompt: prompt,
                onTextChunk: { _ in }
            )
            applyExtractedFacts(from: json)
        } catch {
            print("🧠 Memory extraction failed: \(error.localizedDescription)")
        }
    }

    /// Called at session end — does a final pass over the full session history.
    private func runEndOfSessionSummarization(history: [(userTranscript: String, assistantResponse: String)]) async {
        guard let extractionClient = makeExtractionClient() else { return }

        let existingMemory = readFile(at: Self.memoryFileURL)
        let existingUserProfile = readFile(at: Self.userProfileFileURL)

        let historyText = history.enumerated().map { index, exchange in
            "Turn \(index + 1)\nUser: \(exchange.userTranscript)\nClicky: \(exchange.assistantResponse)"
        }.joined(separator: "\n\n")

        let prompt = """
        Skim this full session and pull out any NEW durable facts not already captured.

        Full session:
        \(historyText)

        Already in memory.md (skip these):
        \(existingMemory.isEmpty ? "(empty)" : existingMemory)

        Already in user.md (skip these):
        \(existingUserProfile.isEmpty ? "(empty)" : existingUserProfile)

        Voice & style — write like a friend's quick note:
        - Short sentences. Plain words. No "the user".
        - Be specific. "Loves espresso" beats "consumes coffee beverages".
        - One idea per fact.
        - Skip obvious / generic stuff.
        - NEVER paste file paths, PNG names, JSON, tool names, terminal output,
          UUIDs, or session-specific details. Translate tech artifacts into
          a plain human observation, or skip them.
        - If nothing new: return {}

        memory.md: projects, tools, preferences, work context
        user.md: name, role, location, personality, long-term habits

        Return ONLY valid JSON:
        {"memory": ["fact1"], "user": ["fact1"]}
        """

        do {
            let (json, _) = try await extractionClient.analyzeImageStreaming(
                images: [],
                systemPrompt: "You extract durable facts from conversations for persistent memory. Write like a friend's quick note — short, plain, specific. Reply only with valid JSON.",
                conversationHistory: [],
                userPrompt: prompt,
                onTextChunk: { _ in }
            )
            applyExtractedFacts(from: json)
            print("🧠 End-of-session memory sweep complete")
        } catch {
            print("🧠 End-of-session sweep failed: \(error.localizedDescription)")
        }
    }

    private func applyExtractedFacts(from jsonString: String) {
        // Strip markdown code fences if the model adds them despite instructions
        var cleaned = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            cleaned = cleaned.components(separatedBy: "\n").dropFirst().dropLast().joined(separator: "\n")
        }

        guard let data = cleaned.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: [String]]
        else { return }

        if let memoryFacts = parsed["memory"], !memoryFacts.isEmpty {
            appendNewFacts(memoryFacts, to: Self.memoryFileURL)
            print("🧠 memory.md +\(memoryFacts.count): \(memoryFacts.joined(separator: " | "))")
        }
        if let userFacts = parsed["user"], !userFacts.isEmpty {
            appendNewFacts(userFacts, to: Self.userProfileFileURL)
            print("🧠 user.md +\(userFacts.count): \(userFacts.joined(separator: " | "))")
        }
    }

    private func appendNewFacts(_ facts: [String], to fileURL: URL) {
        let existing = readFile(at: fileURL)
        let newLines = facts.map { "- \($0)" }.joined(separator: "\n")
        let updated = existing.isEmpty ? newLines : existing + "\n" + newLines
        writeFile(content: updated, to: fileURL)
    }

    // MARK: - Extraction client

    /// Creates a ClaudeCodeCLIClient for background extractions.
    /// Routes through the Claude Code CLI subprocess so the subscription handles auth — no direct API key needed.
    /// Returns nil if Claude Code CLI is not installed.
    private func makeExtractionClient() -> (any AnthropicChatClient)? {
        guard ClaudeCodeCLIClient.isAvailable() else {
            print("🧠 Skipping memory extraction — Claude Code CLI not found")
            return nil
        }
        return ClaudeCodeCLIClient(model: "claude-haiku-4-5-20251001")
    }
}
