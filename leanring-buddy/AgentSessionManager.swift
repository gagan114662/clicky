//
//  AgentSessionManager.swift
//  leanring-buddy
//
//  Manages multiple concurrent Codex agent sessions — the "siblings".
//  Each call to launchAgent() spawns a new background Task that runs
//  Codex independently, so several agents can work simultaneously
//  without blocking each other or the voice UI.
//

import Foundation
import SwiftUI

@MainActor
final class AgentSessionManager: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []

    private var colorCycleIndex = 0

    // How long a completed/failed session lingers before being removed from the list.
    private static let completedSessionLingerSeconds: Double = 8

    // MARK: - Launch

    /// Spawns a new agent for the given prompt and returns immediately.
    /// The agent runs in the background; onComplete is called (on MainActor) when it finishes.
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

        Task {
            do {
                let result = try await codexClient.runAgentTask(
                    prompt: prompt,
                    screenshots: screenshots,
                    memoryContextBlock: memoryContextBlock,
                    onProgressChunk: { _ in }
                )
                markSession(id: sessionID, status: .completed, result: result)
                onComplete(result)
            } catch {
                markSession(id: sessionID, status: .failed, result: error.localizedDescription)
            }
            scheduleRemoval(of: sessionID, after: Self.completedSessionLingerSeconds)
        }
    }

    // MARK: - State updates

    private func markSession(id: UUID, status: AgentSessionStatus, result: String?) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].status = status
        sessions[index].result = result
    }

    private func scheduleRemoval(of id: UUID, after seconds: Double) {
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            sessions.removeAll { $0.id == id }
        }
    }

    func removeSession(id: UUID) {
        sessions.removeAll { $0.id == id }
    }

    // MARK: - Helpers

    var hasAnySessions: Bool { !sessions.isEmpty }

    var runningSessionCount: Int { sessions.filter { $0.status == .running }.count }
}
