//
//  leanring_buddyTests.swift
//  leanring-buddyTests
//
//  Created by thorfinn on 3/2/26.
//

import Foundation
import Testing
@testable import ipop_ai

@MainActor
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
        let transcript = "Mission 1: Find people who might be interested in ipop.ai. And session 2, um, find me a list of YC startups doing something similar to ipop.ai."

        #expect(CodexCLIClient.isAgentTask(transcript))

        let tasks = CodexCLIClient.decomposeTaskIntoParallelTasks(transcript)
        #expect(tasks.count == 2)
        #expect(tasks[0] == "Find people who might be interested in ipop.ai")
        #expect(tasks[1] == "find me a list of YC startups doing something similar to ipop.ai")
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

    @Test func zaiProviderMapsClaudeModelSelectionToZAIModels() async throws {
        #expect(
            ZAIChatClient.resolvedModel(
                selectedModel: "claude-haiku-4-5-20251001",
                hasImages: false
            ) == "glm-4.5"
        )
        #expect(
            ZAIChatClient.resolvedModel(
                selectedModel: "claude-haiku-4-5-20251001",
                hasImages: true
            ) == "glm-4.5v"
        )
        #expect(
            ZAIChatClient.resolvedModel(
                selectedModel: "glm-4.6v",
                hasImages: true
            ) == "glm-4.6v"
        )
    }

    @Test func retryPolicyRetriesRateLimitsTimeoutsAndParseFailures() async throws {
        let rateLimitDecision = ChatProviderRetryPolicy.decision(
            for: ProviderPipelineError.apiError(
                provider: "Z.ai",
                statusCode: 429,
                retryAfterSeconds: 0.25,
                body: "rate limited"
            ),
            attempt: 1
        )
        #expect(rateLimitDecision?.reason == "rate limited")
        #expect(rateLimitDecision?.delaySeconds == 0.25)

        let timeoutDecision = ChatProviderRetryPolicy.decision(
            for: URLError(.timedOut),
            attempt: 1
        )
        #expect(timeoutDecision?.reason == "network timeout/interruption")

        let parseDecision = ChatProviderRetryPolicy.decision(
            for: ProviderPipelineError.invalidResponse(provider: "Z.ai"),
            attempt: 1
        )
        #expect(parseDecision?.reason == "provider response parse failure")

        let authDecision = ChatProviderRetryPolicy.decision(
            for: ProviderPipelineError.apiError(
                provider: "Z.ai",
                statusCode: 401,
                retryAfterSeconds: nil,
                body: "bad key"
            ),
            attempt: 1
        )
        #expect(authDecision == nil)
    }

    @Test func localIntentCleansCutOffAppLaunchSpeech() async throws {
        let intent = LocalIntentRouter.route(transcript: "Can you open up Google for me and—")

        #expect(intent == .launchOrActivateApp(name: "google"))
    }

    @Test func localIntentDropsInlineSpeechFillerFromAppName() async throws {
        let intent = LocalIntentRouter.route(transcript: "Open, uh, Freeform.")

        #expect(intent == .launchOrActivateApp(name: "freeform"))
    }

    @Test func localIntentDoesNotSilentlyCreateNotes() async throws {
        let intent = LocalIntentRouter.route(transcript: "Um, go on my Notes app and make a note for me to make pasta tonight.")

        #expect(intent == .unmatched)
    }

    @Test func calendarCreationDoesNotRouteToCodexSibling() async throws {
        #expect(!CodexCLIClient.isAgentTask("Create a calendar event tomorrow at 3 PM called iPOP live eval."))
    }

    @Test func xcodeFixStillRoutesToCodexSibling() async throws {
        #expect(CodexCLIClient.isAgentTask("Fix this Xcode error in the project and rerun the relevant checks."))
    }

    @Test func localIntentRoutesBareContinuationToClickTarget() async throws {
        let intent = LocalIntentRouter.route(transcript: "to the Apple icon.")

        #expect(intent == .clickByName(targetName: "apple"))
    }

    @Test func generalQuestionsSkipScreenshotCapture() async throws {
        #expect(!CompanionManager.shouldCaptureScreenForTranscript("What is HTML?"))
        #expect(!CompanionManager.shouldCaptureScreenForTranscript("Brainstorm pricing ideas for ipop."))
    }

    @Test func screenQuestionsKeepScreenshotCapture() async throws {
        #expect(CompanionManager.shouldCaptureScreenForTranscript("What is on my screen?"))
        #expect(CompanionManager.shouldCaptureScreenForTranscript("How do I fix this error in Xcode?"))
    }

    @Test func actionOnlyResponseHasNoSpokenWhitespace() async throws {
        let parsed = ActionTagParser.parseAllActionTags(
            from: "[OPEN_APP:Notes] [KEY:cmd+n] [TYPE:pasta tonight]"
        )

        #expect(parsed.actions.count == 3)
        #expect(parsed.spokenText == "")
    }

}
