//
//  AgentSession.swift
//  leanring-buddy
//
//  Data model for a single running or completed Codex agent task.
//  AgentSessionManager owns a published array of these and the
//  AgentSiblingsOverlay renders them as "mini clicky siblings".
//

import Foundation
import SwiftUI

enum AgentSessionStatus {
    case running
    case completed
    case failed
}

struct AgentSession: Identifiable {
    let id: UUID
    let taskDescription: String
    let triangleColor: Color
    var status: AgentSessionStatus
    var result: String?
    /// Live streaming output from Codex while the agent runs. Updated as
    /// codex emits text deltas. Shown in the detail panel when the user
    /// clicks the sibling icon.
    var liveOutput: String
    /// Codex thread ID captured from the `thread.started` event. Required
    /// so the user can send follow-up messages via `codex exec resume`.
    var codexThreadID: String?
    let startedAt: Date

    // Cycles through these colors as new agents are spawned so each sibling
    // is visually distinct at a glance.
    static let palette: [Color] = [
        Color(hex: "#F5C518"), // yellow
        Color(hex: "#E74C3C"), // red
        Color(hex: "#3B82F6"), // blue
        Color(hex: "#22C55E"), // green
        Color(hex: "#A855F7"), // purple
        Color(hex: "#F97316"), // orange
    ]

    init(taskDescription: String, triangleColor: Color) {
        self.id = UUID()
        self.taskDescription = taskDescription
        self.triangleColor = triangleColor
        self.status = .running
        self.liveOutput = ""
        self.codexThreadID = nil
        self.startedAt = Date()
    }
}
