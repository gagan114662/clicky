//
//  AgentSessionManager.swift
//  leanring-buddy
//
//  Manages multiple concurrent Codex agent sessions — the "siblings".
//  Each call to launchAgent() opens a new thread on the long-lived
//  `codex app-server` process, so several agents can work simultaneously
//  without blocking each other or the voice UI. (Used to spawn one
//  `codex exec` subprocess per task — replaced with thread-on-server.)
//

import Combine
import Foundation
import SwiftUI

@MainActor
final class AgentSessionManager: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []

    private var colorCycleIndex = 0
    private var sessionTasks: [UUID: Task<Void, Never>] = [:]
    private var cancelledSessionIDs: Set<UUID> = []

    // How long a completed/failed session lingers before being removed from
    // the list. Long enough for the user to inspect the agent's work and
    // send follow-up messages without the icon disappearing on them.
    // Long-press the icon to dismiss earlier.
    private static let completedSessionLingerSeconds: Double = 600

    private static let workspaceRoot = "\(NSHomeDirectory())/Desktop/ipop-ai-agents"

    // MARK: - Launch

    /// Spawns a new agent for the given prompt and returns immediately.
    /// The agent runs on its own thread inside the shared codex app-server;
    /// `onComplete` is called (on MainActor) when it finishes.
    /// `codexClient` is no longer used (kept for source-compat with callers
    /// that still pass it). Migration uses CodexAppServerClient.shared.
    func launchAgent(
        prompt: String,
        screenshots: [(data: Data, label: String)],
        memoryContextBlock: String,
        codexClient: CodexCLIClient,
        onComplete: @escaping @MainActor (String) -> Void
    ) {
        let color = AgentSession.palette[colorCycleIndex % AgentSession.palette.count]
        colorCycleIndex += 1

        let session = AgentSession(taskDescription: prompt, triangleColor: color)
        sessions.append(session)
        let sessionID = session.id
        cancelledSessionIDs.remove(sessionID)

        // Compose the prompt with memory context; codex app-server has no
        // built-in memory injection, so we prepend it ourselves.
        let composedPrompt: String = {
            if memoryContextBlock.isEmpty { return prompt }
            return memoryContextBlock + "\n\n" + prompt
        }()

        let task = Task {
            defer {
                sessionTasks.removeValue(forKey: sessionID)
                if !sessions.contains(where: { $0.id == sessionID }) {
                    cancelledSessionIDs.remove(sessionID)
                }
            }

            var threadID: String?
            do {
                Self.ensureWorkspaceExists()
                try Task.checkCancellation()
                guard isSessionActive(id: sessionID) else { return }

                threadID = try await CodexAppServerClient.shared.startThread(
                    cwd: Self.workspaceRoot
                )
                guard let threadID else { return }

                guard isSessionActive(id: sessionID) else {
                    print("🛑 Session dismissed before thread registration — archiving \(threadID.prefix(8))")
                    await CodexAppServerClient.shared.archiveThread(threadID: threadID)
                    return
                }

                setThreadID(id: sessionID, threadID: threadID)
                try Task.checkCancellation()
                guard isSessionActive(id: sessionID) else {
                    await CodexAppServerClient.shared.archiveThread(threadID: threadID)
                    return
                }

                let result = try await CodexAppServerClient.shared.startTurn(
                    threadID: threadID,
                    prompt: composedPrompt,
                    onEvent: { [weak self] event in
                        self?.handleThreadEvent(sessionID: sessionID, event: event)
                    }
                )

                if isSessionActive(id: sessionID) {
                    markSession(id: sessionID, status: .completed, result: result)
                    onComplete(result)
                } else {
                    print("🛑 Session was dismissed mid-run — skipping completion TTS")
                }
            } catch is CancellationError {
                if let threadID {
                    await CodexAppServerClient.shared.interruptTurn(threadID: threadID)
                    await CodexAppServerClient.shared.archiveThread(threadID: threadID)
                }
                print("🛑 Session \(sessionID.uuidString.prefix(8)) task cancelled")
            } catch {
                if let threadID, !isSessionActive(id: sessionID) {
                    await CodexAppServerClient.shared.archiveThread(threadID: threadID)
                    return
                }

                if isSessionActive(id: sessionID) {
                    markSession(id: sessionID, status: .failed, result: error.localizedDescription)
                }
            }
            if isSessionActive(id: sessionID) {
                scheduleRemoval(of: sessionID, after: Self.completedSessionLingerSeconds)
            }
        }
        sessionTasks[sessionID] = task
    }

    /// Sends a follow-up prompt to an existing thread on the codex app-server.
    /// The session goes back to .running while the new turn streams in;
    /// new output is appended below the prior transcript so the conversation
    /// history stays visible in the panel.
    func sendFollowUp(
        sessionID: UUID,
        prompt: String,
        codexClient: CodexCLIClient
    ) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        guard let threadID = sessions[index].codexThreadID else {
            sessions[index].liveOutput += "\n\n[follow-up failed: no Codex thread id captured]"
            return
        }

        let header = "\n\n--- you ---\n\(prompt)\n\n--- codex ---\n"
        sessions[index].liveOutput += header
        sessions[index].status = .running
        sessions[index].result = nil

        let task = Task {
            defer {
                sessionTasks.removeValue(forKey: sessionID)
                if !sessions.contains(where: { $0.id == sessionID }) {
                    cancelledSessionIDs.remove(sessionID)
                }
            }

            do {
                try Task.checkCancellation()
                guard isSessionActive(id: sessionID) else { return }

                let result = try await CodexAppServerClient.shared.startTurn(
                    threadID: threadID,
                    prompt: prompt,
                    onEvent: { [weak self] event in
                        // For follow-ups we keep the prior content + header
                        // intact, then replace the post-header tail with
                        // the latest streamed text.
                        self?.handleFollowUpEvent(sessionID: sessionID, header: header, event: event)
                    }
                )
                if isSessionActive(id: sessionID) {
                    markSession(id: sessionID, status: .completed, result: result)
                }
            } catch is CancellationError {
                await CodexAppServerClient.shared.interruptTurn(threadID: threadID)
                await CodexAppServerClient.shared.archiveThread(threadID: threadID)
                print("🛑 Follow-up \(sessionID.uuidString.prefix(8)) task cancelled")
            } catch {
                if isSessionActive(id: sessionID) {
                    markSession(id: sessionID, status: .failed, result: error.localizedDescription)
                }
            }
            if isSessionActive(id: sessionID) {
                scheduleRemoval(of: sessionID, after: Self.completedSessionLingerSeconds)
            }
        }
        sessionTasks[sessionID] = task
    }

    // MARK: - Stream → liveOutput

    /// Translate a CodexThreadEvent into a panel-render-friendly text update.
    /// Format mirrors what the old codex exec parser produced:
    ///   - agent_message → prose
    ///   - command_execution → "$ <cmd>\n<output>"
    ///   - file_change → "+ /path" / "✎ /path"
    private func handleThreadEvent(sessionID: UUID, event: CodexThreadEvent) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        switch event {
        case .agentMessageDelta(let delta):
            appendToLiveOutput(at: index, sessionID: sessionID, text: delta, separator: nil)
        case .agentMessageComplete(let text):
            // Some servers send a final complete message instead of deltas.
            // If we never saw deltas, replace; otherwise leave the deltas alone.
            if sessions[index].liveOutput.isEmpty {
                sessions[index].liveOutput = text
            }
        case .shellCommand(let command, let output):
            let trimmedOut = output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let line = trimmedOut.isEmpty ? "$ \(command)" : "$ \(command)\n\(trimmedOut)"
            appendToLiveOutput(at: index, sessionID: sessionID, text: line, separator: "\n\n")
        case .fileChange(let paths, let kinds):
            let lines = zip(paths, kinds + Array(repeating: "edit", count: max(0, paths.count - kinds.count))).map { path, kind -> String in
                let icon = kind == "add" ? "+" : (kind == "delete" ? "−" : "✎")
                return "\(icon) \(path)"
            }
            appendToLiveOutput(at: index, sessionID: sessionID, text: lines.joined(separator: "\n"), separator: "\n\n")
        case .turnCompleted, .turnFailed:
            // Terminal events are handled by the awaiting startTurn caller.
            break
        case .info(let msg):
            print("ℹ️ codex info (\(sessionID.uuidString.prefix(8))): \(msg)")
        }
    }

    /// Variant for follow-up turns — preserves prior output + header marker
    /// and replaces only the trailing chunk so the user sees the new turn
    /// growing under the "--- codex ---" divider.
    private func handleFollowUpEvent(sessionID: UUID, header: String, event: CodexThreadEvent) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        let current = sessions[index].liveOutput
        guard let markerRange = current.range(of: header) else {
            // Header missing (shouldn't happen) — fall back to standard append
            handleThreadEvent(sessionID: sessionID, event: event)
            return
        }
        let prefix = String(current[..<markerRange.upperBound])

        switch event {
        case .agentMessageDelta(let delta):
            sessions[index].liveOutput = prefix + (current[markerRange.upperBound...] + delta)
        case .agentMessageComplete(let text):
            sessions[index].liveOutput = prefix + text
        case .shellCommand(let command, let output):
            let trimmedOut = output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let line = trimmedOut.isEmpty ? "$ \(command)" : "$ \(command)\n\(trimmedOut)"
            let suffix = String(current[markerRange.upperBound...])
            let separator = suffix.isEmpty ? "" : "\n\n"
            sessions[index].liveOutput = prefix + suffix + separator + line
        case .fileChange(let paths, let kinds):
            let lines = zip(paths, kinds + Array(repeating: "edit", count: max(0, paths.count - kinds.count))).map { path, kind -> String in
                let icon = kind == "add" ? "+" : (kind == "delete" ? "−" : "✎")
                return "\(icon) \(path)"
            }
            let suffix = String(current[markerRange.upperBound...])
            let separator = suffix.isEmpty ? "" : "\n\n"
            sessions[index].liveOutput = prefix + suffix + separator + lines.joined(separator: "\n")
        case .turnCompleted, .turnFailed, .info:
            break
        }
    }

    private func appendToLiveOutput(at index: Int, sessionID: UUID, text: String, separator: String?) {
        let prev = sessions[index].liveOutput
        let prevLength = prev.count
        let glued: String
        if prev.isEmpty {
            glued = text
        } else if let sep = separator {
            glued = prev + sep + text
        } else {
            glued = prev + text
        }
        if prevLength == 0 && !glued.isEmpty {
            print("📝 Session \(sessionID.uuidString.prefix(8)): first output chunk (\(glued.count) chars)")
        } else if (glued.count - prevLength) > 500 {
            print("📝 Session \(sessionID.uuidString.prefix(8)): now \(glued.count) chars")
        }
        sessions[index].liveOutput = glued
    }

    // MARK: - State updates

    private func markSession(id: UUID, status: AgentSessionStatus, result: String?) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].status = status
        sessions[index].result = result
        let outputLen = sessions[index].liveOutput.count
        let resultLen = result?.count ?? 0
        print("✅ Session \(id.uuidString.prefix(8)) → \(status) (liveOutput: \(outputLen) chars, result: \(resultLen) chars)")
    }

    private func setThreadID(id: UUID, threadID: String) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        guard !cancelledSessionIDs.contains(id) else { return }
        sessions[index].codexThreadID = threadID
        print("🧵 Session \(id.uuidString.prefix(8)) → thread \(threadID.prefix(8))")
    }

    private func isSessionActive(id: UUID) -> Bool {
        sessions.contains(where: { $0.id == id }) && !cancelledSessionIDs.contains(id)
    }

    private func scheduleRemoval(of id: UUID, after seconds: Double) {
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            // If the session has been re-engaged (e.g. user is sending a
            // follow-up turn), leave it alone.
            guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
            if sessions[index].status == .running { return }
            removeSession(id: id)
        }
    }

    /// Removes a session AND fully tears down its codex thread so the
    /// agent doesn't keep running invisibly after the icon disappears:
    ///   1. turn/interrupt — stops the in-flight turn (no-op if already done)
    ///   2. thread/archive — closes the thread server-side so codex frees
    ///      its resources and stops emitting notifications
    func removeSession(id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let threadID = sessions[index].codexThreadID
        let wasRunning = sessions[index].status == .running
        cancelledSessionIDs.insert(id)
        let task = sessionTasks[id]
        task?.cancel()
        sessionTasks.removeValue(forKey: id)

        if let threadID {
            print("🛑 Tearing down codex thread \(threadID.prefix(8)) for session \(id.uuidString.prefix(8)) (running=\(wasRunning))")
            Task {
                if wasRunning {
                    await CodexAppServerClient.shared.interruptTurn(threadID: threadID)
                }
                await CodexAppServerClient.shared.archiveThread(threadID: threadID)
            }
        } else {
            print("🛑 Session \(id.uuidString.prefix(8)) dismissed before Codex thread was ready")
        }
        sessions.removeAll { $0.id == id }
        if task == nil {
            cancelledSessionIDs.remove(id)
        }
    }

    // MARK: - Helpers

    var hasAnySessions: Bool { !sessions.isEmpty }
    var runningSessionCount: Int { sessions.filter { $0.status == .running }.count }

    private static func ensureWorkspaceExists() {
        try? FileManager.default.createDirectory(
            atPath: workspaceRoot,
            withIntermediateDirectories: true
        )
    }
}
