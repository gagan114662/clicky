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

    @Test func cortexMishearingStillRoutesToTwoCodexSessions() async throws {
        let transcript = "Can you launch two parallel cortex sessions one to find people who might be looking for a solution like this and to the latest spicy companies that have been funded with a similar concept?"

        #expect(CodexCLIClient.isAgentTask(transcript))
        #expect(LocalIntentRouter.route(transcript: transcript) == .unmatched)

        let tasks = CodexCLIClient.decomposeTaskIntoParallelTasks(transcript)
        #expect(tasks.count == 2)
        #expect(tasks[0] == "find people who might be looking for a solution like this")
        #expect(tasks[1] == "find the latest spicy companies that have been funded with a similar concept")
    }

    @Test func localIntentCleansCutOffAppLaunchSpeech() async throws {
        let intent = LocalIntentRouter.route(transcript: "Can you open up Google for me and—")

        #expect(intent == .launchOrActivateApp(name: "google"))
    }

    @Test func localIntentDropsInlineSpeechFillerFromAppName() async throws {
        let intent = LocalIntentRouter.route(transcript: "Open, uh, Freeform.")

        #expect(intent == .launchOrActivateApp(name: "freeform"))
    }

    @Test func localIntentRoutesBareContinuationToClickTarget() async throws {
        let intent = LocalIntentRouter.route(transcript: "to the Apple icon.")

        #expect(intent == .clickByName(targetName: "apple"))
    }

    @Test func actionOnlyResponseHasNoSpokenWhitespace() async throws {
        let parsed = ActionTagParser.parseAllActionTags(
            from: "[OPEN_APP:Notes] [KEY:cmd+n] [TYPE:pasta tonight]"
        )

        #expect(parsed.actions.count == 3)
        #expect(parsed.spokenText == "")
    }

}
