//
//  leanring_buddyTests.swift
//  leanring-buddyTests
//
//  Created by thorfinn on 3/2/26.
//

import Testing
@testable import leanring_buddy

struct leanring_buddyTests {

    @Test func firstPermissionRequestUsesSystemPromptOnly() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: false
        )

        #expect(presentationDestination == .systemPrompt)
    }

    @Test func repeatedPermissionRequestOpensSystemSettings() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: true
        )

        #expect(presentationDestination == .systemSettings)
    }

    @Test func knownGrantedScreenRecordingPermissionSkipsTheGate() async throws {
        let shouldTreatPermissionAsGranted = WindowPositionManager.shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch(
            hasScreenRecordingPermissionNow: false,
            hasPreviouslyConfirmedScreenRecordingPermission: true
        )

        #expect(shouldTreatPermissionAsGranted)
    }

    @Test func enumeratedSessionFollowUpRoutesToCodexAgents() async throws {
        let transcript = "Mission 1: Find people who might be interested in Clikki. And session 2, um, find me a list of YC startups doing something similar to Clicky."

        #expect(CodexCLIClient.isAgentTask(transcript))

        let tasks = CodexCLIClient.decomposeTaskIntoParallelTasks(transcript)
        #expect(tasks.count == 2)
        #expect(tasks[0] == "Find people who might be interested in Clikki")
        #expect(tasks[1] == "find me a list of YC startups doing something similar to Clicky")
    }

    @Test func explicitTwoCodexSessionsCreatesTwoDemoTasks() async throws {
        let transcript = "Can you run 2 sessions for me? 2 parallel Codex sessions"

        #expect(CodexCLIClient.isAgentTask(transcript))

        let tasks = CodexCLIClient.decomposeTaskIntoParallelTasks(transcript)
        #expect(tasks.count == 2)
        #expect(tasks[0].contains("Parallel Codex session 1"))
        #expect(tasks[1].contains("Parallel Codex session 2"))
    }

}
