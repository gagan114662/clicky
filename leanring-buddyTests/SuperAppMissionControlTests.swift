import XCTest
@testable import ipop_ai

final class SuperAppMissionControlTests: XCTestCase {
    func testUpworkApplicationRequiresConfirmationAndUsesAdapter() {
        let missionControl = makeMissionControl()

        let plan = missionControl.plan(for: "Apply to this Upwork job with a short proposal")

        XCTAssertTrue(plan.targetApps.contains(.upwork))
        XCTAssertTrue(plan.requiresConfirmation)
        XCTAssertTrue(plan.steps.contains(where: { $0.capabilityID == "upwork.apply" }))
        XCTAssertTrue(plan.steps.contains(where: { $0.needsUserConfirmation }))
        XCTAssertTrue(plan.agentSystemContext.contains("Confirmation gate"))
    }

    func testDeleteSelectedFilesRequiresConfirmation() {
        let missionControl = makeMissionControl()

        let plan = missionControl.plan(for: "Delete the selected files in Finder")

        XCTAssertTrue(plan.targetApps.contains(.finder))
        XCTAssertTrue(plan.requiresConfirmation)
        XCTAssertTrue(plan.steps.contains(where: { $0.riskLevel == .confirmationRequired }))
    }

    func testWatchPageCreatesAutomationDraft() {
        let automationURL = temporaryJSONURL()
        let automationStore = SuperAppAutomationStore(fileURL: automationURL)
        let missionControl = SuperAppMissionControl(
            memoryStore: SuperAppTaskMemoryStore(fileURL: temporaryJSONURL()),
            automationStore: automationStore
        )

        let plan = missionControl.plan(for: "Watch this page in Chrome and tell me when it changes")

        XCTAssertEqual(plan.automationIntent?.kind, .watch)
        XCTAssertTrue(plan.requiresConfirmation)
        XCTAssertEqual(automationStore.loadDrafts().count, 1)
        XCTAssertTrue(plan.steps.contains(where: { $0.capabilityID == "automation.watch" }))
    }

    func testPreviewPDFPlanIncludesVisibleVerification() {
        let missionControl = makeMissionControl()

        let plan = missionControl.plan(for: "Summarize this PDF in Preview")

        XCTAssertTrue(plan.targetApps.contains(.preview))
        XCTAssertTrue(plan.steps.contains(where: { $0.capabilityID == "preview.pdf" }))
        XCTAssertTrue(plan.verificationChecklist.contains(where: { $0.lowercased().contains("visible page") }))
    }

    func testDashboardShowsNeedsConfirmationBlocker() {
        let missionControl = makeMissionControl()
        let plan = missionControl.plan(for: "Send this Slack message")

        let snapshot = missionControl.dashboardSnapshot(for: plan, status: .needsConfirmation)

        XCTAssertEqual(snapshot.status, .needsConfirmation)
        XCTAssertNotNil(snapshot.blockedReason)
        XCTAssertEqual(snapshot.nextAction, "Waiting for user approval.")
    }

    func testMessageRiskTriggerMatchesInsideNaturalSentence() {
        let missionControl = makeMissionControl()

        let plan = missionControl.plan(for: "Can you send a DM to Priya saying I am five minutes late?")

        XCTAssertTrue(plan.requiresConfirmation)
        XCTAssertTrue(
            plan.confirmationReason?.lowercased().contains("third-party message") == true,
            "Expected a third-party-message risk reason, got \(String(describing: plan.confirmationReason))"
        )
    }

    func testTellRiskTriggerMatchesInsideNaturalSentence() {
        let missionControl = makeMissionControl()

        let plan = missionControl.plan(for: "In Slack, tell John I am running late")

        XCTAssertTrue(plan.requiresConfirmation)
        XCTAssertTrue(
            plan.confirmationReason?.lowercased().contains("third-party message") == true,
            "Expected a third-party-message risk reason, got \(String(describing: plan.confirmationReason))"
        )
    }

    func testTaskMemoryPersistsCompletedMissions() {
        let memoryStore = SuperAppTaskMemoryStore(fileURL: temporaryJSONURL())
        let missionControl = SuperAppMissionControl(
            memoryStore: memoryStore,
            automationStore: SuperAppAutomationStore(fileURL: temporaryJSONURL())
        )
        let plan = missionControl.plan(for: "Open Notes and create a scratch note")

        missionControl.record(plan: plan, status: .done, resultSummary: "Created note")

        let entries = memoryStore.loadEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.objective, plan.objective)
        XCTAssertEqual(entries.first?.status, .done)
    }

    func testLiveEvalCatalogCoversHighValueApps() {
        let apps = Set(SuperAppAppAdapterRegistry.liveEvalCatalog.map(\.app))

        XCTAssertTrue(apps.isSuperset(of: [
            .safari,
            .chrome,
            .finder,
            .mail,
            .calendar,
            .preview,
            .notes,
            .slack,
            .upwork,
            .googleDocs
        ]))
    }

    func testTinyfishWebAgentPlanUsesRemoteWebAdapter() {
        let missionControl = makeMissionControl()

        let plan = missionControl.plan(for: "Search the web for Tinyfish browser automation docs")

        XCTAssertEqual(plan.targetApps.first, .webAgent)
        XCTAssertTrue(plan.steps.contains(where: { $0.capabilityID == "tinyfish.research" }))
        XCTAssertTrue(plan.agentSystemContext.contains("Tinyfish Web"))
    }

    func testTinyfishWebsiteSubmitPlanRequiresConfirmation() {
        let missionControl = makeMissionControl()

        let plan = missionControl.plan(for: "On this website, apply with my proposal and submit it")

        XCTAssertEqual(plan.targetApps.first, .webAgent)
        XCTAssertTrue(plan.requiresConfirmation)
        XCTAssertTrue(plan.steps.contains(where: { $0.capabilityID == "tinyfish.workflow" }))
    }

    func testUpworkMoneyMissionShowsOutcomeJourney() {
        let missionControl = makeMissionControl()

        let plan = missionControl.plan(for: "Help me make real money on Upwork by finding good Swift jobs")

        XCTAssertEqual(plan.kind, .earn)
        XCTAssertTrue(plan.impactPromise.lowercased().contains("urgent async upwork jobs"))
        XCTAssertTrue(plan.targetApps.contains(.upwork))
        XCTAssertTrue(plan.steps.contains(where: { $0.capabilityID == "upwork.verifySession" }))
        XCTAssertTrue(plan.steps.contains(where: { $0.capabilityID == "upwork.fastCashSearch" }))
        XCTAssertTrue(plan.steps.contains(where: { $0.capabilityID == "upwork.fastCashEvidence" }))
        XCTAssertTrue(plan.steps.contains(where: { $0.capabilityID == "upwork.fastCashRank" }))
        XCTAssertTrue(plan.steps.contains(where: { $0.capabilityID == "upwork.fastCashProposal" }))
        XCTAssertTrue(plan.proofLog.contains(where: { $0.title == "Session check" }))
        XCTAssertTrue(plan.proofLog.contains(where: { $0.title == "Fast Cash searches" }))
        XCTAssertTrue(plan.proofLog.contains(where: { $0.title == "Speed-to-cash matrix" }))
        XCTAssertTrue(plan.proofLog.contains(where: { $0.id == "proof-first-preview" }))
        XCTAssertTrue(plan.outcomeMetrics.contains(where: { $0.id == "mode" && $0.value == "Fast Cash" }))
        XCTAssertTrue(plan.outcomeMetrics.contains(where: { $0.id == "target" && $0.value == "$50-$250" }))
        XCTAssertTrue(plan.outcomeMetrics.contains(where: { $0.id == "proofFirst" && $0.value == "Prework first" }))
        XCTAssertTrue(plan.approvalChips.contains(where: { $0.title == "Apply / Submit" }))
        XCTAssertTrue(plan.guardrails.contains(where: { $0.lowercased().contains("submit applications") }))
        XCTAssertTrue(plan.agentSystemContext.contains("Mission kind: Earn"))
        XCTAssertTrue(plan.agentSystemContext.contains("UPWORK MONEY WORKFLOW"))
        XCTAssertTrue(plan.agentSystemContext.contains("Money mode: Fast Cash"))
        XCTAssertTrue(plan.agentSystemContext.contains("First verify Safari or Chrome"))
        XCTAssertTrue(plan.agentSystemContext.contains("Start URL: https://www.upwork.com/nx/search/jobs/"))
        XCTAssertTrue(plan.agentSystemContext.contains("do not merely describe a plan"))
    }

    func testUpworkFastCashStandingApprovalSubmitsOnlyCappedMicroContracts() {
        let missionControl = makeMissionControl()

        let plan = missionControl.plan(
            for: "Find the fastest Upwork money with Fast Cash mode on Upwork; submit proposals under my full approval."
        )

        XCTAssertFalse(plan.requiresConfirmation)
        XCTAssertTrue(plan.steps.contains(where: {
            $0.capabilityID == "upwork.submitApprovedApplications" &&
                $0.title == "Submit up to 5 async Fast Cash applications" &&
                $0.verification.contains("at most 5")
        }))
        XCTAssertTrue(plan.agentSystemContext.contains("STANDING_UPWORK_SUBMISSION_APPROVAL=granted"))
        XCTAssertTrue(plan.agentSystemContext.contains("UPWORK_PREWORK_ARTIFACT_REQUIRED=true"))
        XCTAssertTrue(plan.agentSystemContext.contains("SwiftUI bug fix | iOS app bug | macOS Swift"))
        XCTAssertTrue(plan.agentSystemContext.contains("$50-$250"))
        XCTAssertTrue(plan.agentSystemContext.contains("paid diagnostic/fix"))
        XCTAssertTrue(plan.agentSystemContext.contains("Reject Zoom/call/meeting/live-session-only jobs"))
        XCTAssertTrue(plan.agentSystemContext.contains("Reject jobs with no visible upfront artifact"))
        XCTAssertTrue(plan.agentSystemContext.contains("only after that proof exists"))
        XCTAssertTrue(plan.agentSystemContext.contains("Do not deliver final private work"))
        XCTAssertTrue(plan.proofLog.contains(where: { $0.id == "earnings-proof" }))
        XCTAssertTrue(plan.approvalChips.contains(where: { $0.id == "boost-billing-contract" && $0.isBlocking }))
        XCTAssertTrue(plan.approvalChips.contains(where: { $0.id == "calls-meetings" && $0.isBlocking }))
        XCTAssertTrue(plan.approvalChips.contains(where: { $0.id == "upfront-artifacts" && $0.isBlocking }))
    }

    func testFastCashProofFirstModeRejectsMeetingsAndKeepsFullWorkBehindMilestone() {
        let missionControl = makeMissionControl()

        let plan = missionControl.plan(
            for: "Use Upwork Fast Cash proof-first: do the work from public details and ask for payment with proof; you have full approval."
        )

        XCTAssertFalse(plan.requiresConfirmation)
        XCTAssertTrue(plan.steps.contains(where: {
            $0.capabilityID == "upwork.fastCashEvidence" &&
                $0.verification.lowercased().contains("visible code/log/screenshot")
        }))
        XCTAssertTrue(plan.steps.contains(where: {
            $0.capabilityID == "upwork.fastCashProposal" &&
                $0.verification.lowercased().contains("real proof artifact")
        }))
        XCTAssertTrue(plan.proofOfWork.contains(where: { $0.lowercased().contains("prework-first") }))
        XCTAssertTrue(plan.agentSystemContext.contains("Do not submit proposals for jobs where the posting does not provide enough public material"))
        XCTAssertTrue(plan.agentSystemContext.contains("funded or a contract is active"))
        XCTAssertTrue(plan.approvalChips.contains(where: { $0.id == "calls-meetings" && $0.riskLevel == .blocked }))
        XCTAssertTrue(plan.approvalChips.contains(where: { $0.id == "upfront-artifacts" && $0.riskLevel == .blocked }))
    }

    func testUpworkSearchWorkflowDoesNotRequireApprovalUntilApply() {
        let missionControl = makeMissionControl()

        let plan = missionControl.plan(for: "Find Upwork jobs that match iOS SwiftUI macOS app work and rank the best ones")

        XCTAssertFalse(plan.requiresConfirmation)
        XCTAssertTrue(plan.steps.contains(where: { $0.capabilityID == "upwork.verifySession" }))
        XCTAssertFalse(plan.steps.contains(where: { $0.capabilityID == "upwork.apply" }))
        XCTAssertTrue(plan.agentSystemContext.contains("STANDING_UPWORK_SUBMISSION_APPROVAL=not_granted"))
        XCTAssertTrue(plan.agentSystemContext.contains("Unless standing approval above is granted, do not click Apply"))
        XCTAssertTrue(plan.approvalChips.contains(where: {
            $0.id == "spend-connects" && $0.isBlocking
        }))
    }

    func testUpworkApplyWorkflowAddsApplicationDraftAndConfirmationGate() {
        let missionControl = makeMissionControl()

        let plan = missionControl.plan(for: "Apply to this Upwork job with a short proposal")

        XCTAssertTrue(plan.requiresConfirmation)
        XCTAssertTrue(plan.steps.contains(where: { $0.capabilityID == "upwork.apply" }))
        XCTAssertTrue(plan.steps.contains(where: { $0.capabilityID == "safety.confirmation" }))
        XCTAssertTrue(plan.approvalChips.contains(where: {
            $0.id == "apply-submit" && $0.isBlocking
        }))
    }

    func testUpworkStandingApprovalPermitsTruthfulSubmissions() {
        let missionControl = makeMissionControl()

        let plan = missionControl.plan(for: "Submit Upwork applications on my behalf; you have full approval")

        XCTAssertTrue(plan.targetApps.contains(.upwork))
        XCTAssertFalse(plan.requiresConfirmation)
        XCTAssertNil(plan.confirmationReason)
        XCTAssertTrue(plan.steps.contains(where: { $0.capabilityID == "upwork.apply" }))
        XCTAssertTrue(plan.steps.contains(where: { $0.capabilityID == "upwork.submitApprovedApplications" }))
        XCTAssertTrue(plan.steps.contains(where: { $0.capabilityID == "upwork.trackSubmissions" }))
        XCTAssertFalse(plan.steps.contains(where: { $0.capabilityID == "safety.confirmation" }))
        XCTAssertTrue(plan.proofLog.contains(where: { $0.id == "submission-receipts" }))
        XCTAssertTrue(plan.proofLog.contains(where: { $0.id == "follow-up-tracker" }))
        XCTAssertTrue(plan.outcomeMetrics.contains(where: { $0.id == "submitted" && $0.isPrimary }))
        XCTAssertTrue(plan.approvalChips.contains(where: {
            $0.id == "apply-submit" && !$0.isBlocking && $0.detail.lowercased().contains("standing")
        }))
        XCTAssertTrue(plan.approvalChips.contains(where: {
            $0.id == "spend-connects" && !$0.isBlocking
        }))
        XCTAssertTrue(plan.agentSystemContext.contains("STANDING_UPWORK_SUBMISSION_APPROVAL=granted"))
        XCTAssertTrue(plan.guardrails.contains(where: { $0.lowercased().contains("standing upwork") }))
    }

    func testUpworkApplicationTrackerCreatesFollowUpRecordAndScoreboard() {
        let candidate = UpworkOpportunityCandidate(
            id: "audit",
            title: "Mac App Security and Performance Audit",
            clientSummary: "Payment verified, 4.9 rating, spent $84k",
            budgetText: "$30-$50/hr hourly",
            skills: ["Swift", "Apple Xcode", "macOS"],
            descriptionSnippet: "Review an existing Mac app for security risks, performance bottlenecks, and production readiness.",
            urlString: "https://www.upwork.com/jobs/~audit"
        )
        let ranked = RankedUpworkOpportunity(
            candidate: candidate,
            score: UpworkOpportunityRanker.score(candidate)
        )
        let draft = UpworkProposalDraftFactory.draft(for: ranked)
        let submittedAt = Date(timeIntervalSince1970: 1_778_006_000)

        let record = UpworkApplicationTracker.submissionRecord(
            for: ranked,
            proposalDraft: draft,
            submittedAt: submittedAt,
            connectsSpentText: "12 connects"
        )
        let scoreboard = UpworkApplicationTracker.scoreboard(for: [record])

        XCTAssertEqual(record.status, .submitted)
        XCTAssertEqual(record.connectsSpentText, "12 connects")
        XCTAssertEqual(record.jobURL, "https://www.upwork.com/jobs/~audit")
        XCTAssertNotNil(record.nextFollowUpAt)
        XCTAssertTrue(record.successMetric.lowercased().contains("reply"))
        XCTAssertTrue(scoreboard.contains(where: { $0.id == "submitted" && $0.value == "1" }))
    }

    func testUpworkApplicationRecordStorePersistsFollowUps() {
        let store = UpworkApplicationRecordStore(fileURL: temporaryJSONURL())
        let candidate = UpworkOpportunityCandidate(
            id: "repair",
            title: "SwiftUI Crash Repair",
            clientSummary: "Payment verified, 5.0 rating",
            budgetText: "$95/hr hourly",
            skills: ["SwiftUI", "iOS"],
            descriptionSnippet: "Fix a production crash in an existing SwiftUI app."
        )
        let ranked = RankedUpworkOpportunity(
            candidate: candidate,
            score: UpworkOpportunityRanker.score(candidate)
        )
        let submittedAt = Date(timeIntervalSince1970: 1_778_006_000)
        let record = UpworkApplicationTracker.submissionRecord(
            for: ranked,
            proposalDraft: UpworkProposalDraftFactory.draft(for: ranked),
            submittedAt: submittedAt
        )

        store.append(record)

        XCTAssertEqual(store.loadRecords(), [record])
        XCTAssertEqual(
            store.recordsNeedingFollowUp(asOf: submittedAt.addingTimeInterval(4 * 24 * 60 * 60)),
            [record]
        )
    }

    func testUpworkSubmissionTrackerMissionUsesStoredRecords() {
        let upworkStore = UpworkApplicationRecordStore(fileURL: temporaryJSONURL())
        let candidate = UpworkOpportunityCandidate(
            id: "dashboard",
            title: "macOS Dashboard Build",
            clientSummary: "Payment verified, spent $20k",
            budgetText: "$4,000 fixed-price",
            skills: ["SwiftUI", "macOS"],
            descriptionSnippet: "Build a native macOS dashboard with app integrations."
        )
        let ranked = RankedUpworkOpportunity(
            candidate: candidate,
            score: UpworkOpportunityRanker.score(candidate)
        )
        upworkStore.append(
            UpworkApplicationTracker.submissionRecord(
                for: ranked,
                proposalDraft: UpworkProposalDraftFactory.draft(for: ranked),
                submittedAt: Date(timeIntervalSince1970: 1_778_006_000)
            )
        )
        let missionControl = SuperAppMissionControl(
            memoryStore: SuperAppTaskMemoryStore(fileURL: temporaryJSONURL()),
            automationStore: SuperAppAutomationStore(fileURL: temporaryJSONURL()),
            upworkApplicationStore: upworkStore
        )

        let plan = missionControl.plan(
            for: "Show my Upwork submission tracker: applications submitted, replies, interviews, offers, blockers, and dollars won."
        )

        XCTAssertTrue(plan.steps.contains(where: { $0.capabilityID == "upwork.openProposals" }))
        XCTAssertTrue(plan.steps.contains(where: { $0.capabilityID == "upwork.trackSubmissions" }))
        XCTAssertTrue(plan.outcomeMetrics.contains(where: { $0.id == "submitted" && $0.value == "1" }))
        XCTAssertTrue(plan.outcomeMetrics.contains(where: { $0.id == "dollarsWon" }))
        XCTAssertTrue(plan.proofLog.contains(where: { $0.id == "submission-receipts" && $0.status == .captured }))
        XCTAssertTrue(plan.workflowContext?.contains("review submitted applications") == true)
    }

    func testDashboardShowsUpworkProofLogAndApprovalGates() {
        let missionControl = makeMissionControl()
        let plan = missionControl.plan(for: "Find good Upwork SwiftUI jobs, rank them, draft proposals, stop before applying")

        let snapshot = missionControl.dashboardSnapshot(for: plan, status: .executing, currentStepIndex: 2)

        XCTAssertEqual(snapshot.missionKind, .earn)
        XCTAssertTrue(snapshot.outcomeMetrics.contains(where: { $0.label == "Drafts" }))
        XCTAssertTrue(snapshot.proofLog.contains(where: {
            $0.title == "Session check" && $0.status == .captured
        }))
        XCTAssertTrue(snapshot.proofLog.contains(where: {
            $0.title == "Search URL" && $0.status == .captured
        }))
        XCTAssertTrue(snapshot.proofLog.contains(where: {
            $0.title == "Ranking matrix" && $0.status == .planned
        }))
        XCTAssertTrue(snapshot.approvalChips.contains(where: { $0.title == "Apply / Submit" }))
    }

    func testUpworkRankerPrefersStrongNativeMacJobOverCheapGenericWork() {
        let strongJob = UpworkOpportunityCandidate(
            id: "strong",
            title: "SwiftUI macOS menu bar app polish and AppKit integration",
            clientSummary: "Payment verified, 4.9 rating, spent $100k",
            budgetText: "$4,500 fixed-price",
            skills: ["Swift", "SwiftUI", "macOS", "AppKit"],
            descriptionSnippet: "Existing macOS app needs a shippable menu bar workflow, accessibility permissions, App Store cleanup, milestones, and a TestFlight-style handoff.",
            postedTimeText: "Posted 1 hour ago",
            connectsText: "12 connects"
        )
        let weakJob = UpworkOpportunityCandidate(
            id: "weak",
            title: "Need cheap app developer",
            clientSummary: "New client",
            budgetText: "$20 fixed-price low budget",
            skills: ["mobile"],
            descriptionSnippet: "Make an app asap. Message me on Telegram outside Upwork.",
            postedTimeText: "Posted 2 weeks ago",
            connectsText: "16 connects",
            redFlags: ["Off-platform contact", "Tiny budget"]
        )

        let ranked = UpworkOpportunityRanker.rank([weakJob, strongJob])

        XCTAssertEqual(ranked.first?.candidate.id, "strong")
        XCTAssertGreaterThan(ranked.first?.score.total ?? 0, ranked.last?.score.total ?? 0)
        XCTAssertGreaterThan(ranked.last?.score.riskPenalty ?? 0, 10)
    }

    func testFastCashRankerPrefersSmallUrgentPaidBugOverLargeVagueBuild() {
        let fastJob = UpworkOpportunityCandidate(
            id: "fast",
            title: "SwiftUI Xcode error fix needed today",
            clientSummary: "Payment verified, 5.0 rating, spent $12k, less than 5 proposals",
            budgetText: "$150 fixed-price",
            skills: ["SwiftUI", "iOS", "Xcode"],
            descriptionSnippet: "Existing app has a build error after a small dependency update. Attached logs and screenshots show the failing Xcode error. Need a same-day diagnostic and patch handoff.",
            postedTimeText: "Posted 20 minutes ago",
            connectsText: "8 connects"
        )
        let slowJob = UpworkOpportunityCandidate(
            id: "slow",
            title: "Build a complete AI cofounder app from scratch",
            clientSummary: "Payment verified, 50+ proposals",
            budgetText: "$5,000 fixed-price",
            skills: ["AI", "mobile"],
            descriptionSnippet: "Need someone to discover requirements and build a full app over several months. Scope is vague.",
            postedTimeText: "Posted 3 weeks ago",
            connectsText: "18 connects",
            redFlags: ["Vague scope", "50+ proposals"]
        )

        let ranked = UpworkOpportunityRanker.rank([slowJob, fastJob], mode: .fastCash)

        XCTAssertEqual(ranked.first?.candidate.id, "fast")
        XCTAssertGreaterThan(ranked.first?.score.speedToCash ?? 0, ranked.last?.score.speedToCash ?? 0)
        XCTAssertTrue(ranked.first?.score.reasons.contains("Likely same-day micro-contract path.") == true)
    }

    func testFastCashRankerPrefersAsyncProofWorkOverZoomCall() {
        let asyncJob = UpworkOpportunityCandidate(
            id: "async",
            title: "Fix Xcode compile error from attached logs",
            clientSummary: "Payment verified, 5.0 rating, spent $4k, less than 5 proposals",
            budgetText: "$125 fixed-price",
            skills: ["Swift", "Xcode", "iOS"],
            descriptionSnippet: "Existing project has a compile error with attached logs, attached screenshots, and a public repo link for an async diagnostic and patch.",
            postedTimeText: "Posted 30 minutes ago",
            connectsText: "8 connects"
        )
        let zoomJob = UpworkOpportunityCandidate(
            id: "zoom",
            title: "App Store Connect analytics dashboard help",
            clientSummary: "Payment verified, 5.0 rating, spent $20k, less than 5 proposals",
            budgetText: "$60 fixed-price",
            skills: ["iOS", "App Store Connect"],
            descriptionSnippet: "Need a Zoom meeting and screen share so someone can walk me through analytics live.",
            postedTimeText: "Posted 10 minutes ago",
            connectsText: "8 connects"
        )

        let ranked = UpworkOpportunityRanker.rank([zoomJob, asyncJob], mode: .fastCash)

        XCTAssertEqual(ranked.first?.candidate.id, "async")
        XCTAssertGreaterThanOrEqual(ranked.first?.score.upfrontArtifacts ?? 0, UpworkMissionWorkflow.fastCashMinimumPreworkArtifactScore)
        XCTAssertGreaterThan(ranked.first?.score.proofFirst ?? 0, ranked.last?.score.proofFirst ?? 0)
        XCTAssertGreaterThan(ranked.last?.score.riskPenalty ?? 0, 10)
    }

    func testFastCashRankerBlocksNoArtifactJobsEvenWhenScopeIsClear() {
        let noArtifactJob = UpworkOpportunityCandidate(
            id: "no-artifact",
            title: "Senior engineer for fast code audit",
            clientSummary: "Payment verified, 5.0 rating, less than 5 proposals",
            budgetText: "$15 fixed-price",
            skills: ["TypeScript", "Node.js"],
            descriptionSnippet: "Audit up to 500 lines for security, performance, and code quality. Code will be shared after hiring.",
            postedTimeText: "Posted 20 minutes ago",
            connectsText: "11 connects"
        )
        let artifactJob = UpworkOpportunityCandidate(
            id: "artifact",
            title: "Review public Node.js auth snippet for security bug",
            clientSummary: "Payment verified, 5.0 rating, less than 5 proposals",
            budgetText: "$75 fixed-price",
            skills: ["TypeScript", "Node.js"],
            descriptionSnippet: "The post includes a code snippet, public repo, error message, and repro steps for an async security diagnostic.",
            postedTimeText: "Posted 25 minutes ago",
            connectsText: "8 connects"
        )

        let ranked = UpworkOpportunityRanker.rank([noArtifactJob, artifactJob], mode: .fastCash)
        let noArtifactScore = UpworkOpportunityRanker.score(noArtifactJob, mode: .fastCash)

        XCTAssertEqual(ranked.first?.candidate.id, "artifact")
        XCTAssertEqual(noArtifactScore.upfrontArtifacts, 0)
        XCTAssertGreaterThanOrEqual(noArtifactScore.riskPenalty, 14)
        XCTAssertTrue(noArtifactScore.reasons.contains(where: { $0.contains("No upfront code") }))
    }

    func testUpworkProposalDraftIsSpecificAndNeverSubmits() {
        let candidate = UpworkOpportunityCandidate(
            id: "native-app",
            title: "Fix SwiftUI iOS app onboarding bug",
            clientSummary: "Payment verified, 5.0 rating, spent $10k",
            budgetText: "$85/hr hourly",
            skills: ["SwiftUI", "iOS", "Xcode"],
            descriptionSnippet: "Our existing iOS app has an onboarding state bug after sign-in and needs a small verified fix."
        )
        let ranked = RankedUpworkOpportunity(
            candidate: candidate,
            score: UpworkOpportunityRanker.score(candidate)
        )

        let draft = UpworkProposalDraftFactory.draft(for: ranked)

        XCTAssertTrue(draft.openingHook.contains("onboarding"))
        XCTAssertTrue(draft.body.contains("SwiftUI"))
        XCTAssertTrue(draft.body.contains("smallest shippable"))
        XCTAssertTrue(draft.approvalReminder.contains("Draft only"))
        XCTAssertTrue(draft.approvalReminder.contains("Submit Proposal"))
    }

    func testFastCashProposalOffersTinyPaidMilestone() {
        let candidate = UpworkOpportunityCandidate(
            id: "xcode-error",
            title: "Fix Xcode compile error in SwiftUI app",
            clientSummary: "Payment verified, 5.0 rating",
            budgetText: "$120 fixed-price",
            skills: ["SwiftUI", "Xcode"],
            descriptionSnippet: "After an update, the app no longer compiles. The post includes attached logs, attached screenshots, and the exact Xcode error."
        )
        let ranked = RankedUpworkOpportunity(
            candidate: candidate,
            score: UpworkOpportunityRanker.score(candidate, mode: .fastCash)
        )

        let draft = UpworkProposalDraftFactory.draft(for: ranked, mode: .fastCash)

        XCTAssertTrue(draft.openingHook.contains("today"))
        XCTAssertTrue(draft.body.contains("$50-$250"))
        XCTAssertTrue(draft.body.lowercased().contains("proof-first"))
        XCTAssertTrue(draft.body.lowercased().contains("funded in upwork"))
        XCTAssertTrue(draft.body.lowercased().contains("pre-application proof artifact"))
        XCTAssertTrue(draft.body.contains("small fixed-price diagnostic/fix milestone"))
        XCTAssertEqual(draft.questions.count, 1)
        XCTAssertTrue(draft.questions.first?.contains("Xcode project/repo") == true)
        XCTAssertTrue(draft.approvalReminder.contains("Fast Cash prework proposal"))
        XCTAssertTrue(draft.approvalReminder.contains("reject no-artifact"))
    }

    func testFastCashProposalDraftBlocksWhenNoPreworkArtifactExists() {
        let candidate = UpworkOpportunityCandidate(
            id: "blind-audit",
            title: "Audit my backend code",
            clientSummary: "Payment verified, 5.0 rating",
            budgetText: "$80 fixed-price",
            skills: ["Node.js"],
            descriptionSnippet: "I need a code audit. I will share the repository after hiring."
        )
        let ranked = RankedUpworkOpportunity(
            candidate: candidate,
            score: UpworkOpportunityRanker.score(candidate, mode: .fastCash)
        )

        let draft = UpworkProposalDraftFactory.draft(for: ranked, mode: .fastCash)

        XCTAssertTrue(draft.openingHook.contains("Skip"))
        XCTAssertTrue(draft.body.contains("does not provide enough public code"))
        XCTAssertTrue(draft.questions.isEmpty)
        XCTAssertTrue(draft.approvalReminder.contains("Blocked Fast Cash draft"))
    }

    func testUpworkScoreboardCountsOfferContractAndPaidProof() {
        let offered = UpworkApplicationRecord(
            id: "offered",
            candidateID: "one",
            jobTitle: "SwiftUI fix",
            jobURL: nil,
            status: .offered,
            submittedAt: Date(timeIntervalSince1970: 1_778_006_000),
            connectsSpentText: "8 connects",
            proposalSummary: "Fast fix proposal",
            nextFollowUpAt: nil,
            successMetric: "Offer received",
            contractURL: nil,
            earningsProofText: "Offer visible in Upwork",
            updatedAt: Date(timeIntervalSince1970: 1_778_006_100)
        )
        let paid = UpworkApplicationRecord(
            id: "paid",
            candidateID: "two",
            jobTitle: "Xcode diagnostic",
            jobURL: nil,
            status: .paid,
            submittedAt: Date(timeIntervalSince1970: 1_778_006_000),
            connectsSpentText: "6 connects",
            proposalSummary: "Diagnostic proposal",
            nextFollowUpAt: nil,
            successMetric: "Milestone paid",
            contractURL: "https://www.upwork.com/contracts/paid",
            earningsProofText: "Approved milestone visible",
            updatedAt: Date(timeIntervalSince1970: 1_778_006_200)
        )

        let scoreboard = UpworkApplicationTracker.scoreboard(for: [offered, paid])

        XCTAssertTrue(scoreboard.contains(where: { $0.id == "offers" && $0.value == "2" }))
        XCTAssertTrue(scoreboard.contains(where: { $0.id == "dollarsWon" && $0.value == "1 paid" }))
    }

    func testDashboardCarriesFullMissionProgress() {
        let missionControl = makeMissionControl()
        let plan = missionControl.plan(for: "Watch this Upwork search and keep checking for strong macOS jobs")

        let snapshot = missionControl.dashboardSnapshot(for: plan, status: .executing, currentStepIndex: 2)

        XCTAssertEqual(snapshot.missionKind, .automate)
        XCTAssertFalse(snapshot.stepTitles.isEmpty)
        XCTAssertEqual(snapshot.completedStepCount, 2)
        XCTAssertTrue(snapshot.impactPromise.lowercased().contains("durable"))
        XCTAssertNotNil(snapshot.proofLine)
        XCTAssertTrue(snapshot.guardrailLine?.lowercased().contains("approval") == true)
    }

    func testSafetyClassifierRequiresConfirmationForApplicationSubmitTargets() {
        let block = ParsedToolUseBlock(
            toolUseId: "x",
            toolName: "computer",
            inputJSON: ["action": "ax_click", "text": "Apply now"]
        )

        let decision = AgentSafetyClassifier.classify(toolUseBlock: block)
        if case .confirmRequired = decision { return }
        XCTFail("Expected .confirmRequired, got \(decision)")
    }

    private func makeMissionControl() -> SuperAppMissionControl {
        SuperAppMissionControl(
            memoryStore: SuperAppTaskMemoryStore(fileURL: temporaryJSONURL()),
            automationStore: SuperAppAutomationStore(fileURL: temporaryJSONURL()),
            upworkApplicationStore: UpworkApplicationRecordStore(fileURL: temporaryJSONURL())
        )
    }

    private func temporaryJSONURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("clicky-superapp-\(UUID().uuidString)")
            .appendingPathExtension("json")
    }
}
