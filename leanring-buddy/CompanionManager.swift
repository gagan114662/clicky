//
//  CompanionManager.swift
//  leanring-buddy
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

@preconcurrency import AVFoundation
import Combine
import Foundation
import ScreenCaptureKit
import SwiftUI

private extension Notification.Name {
    static let ipopDebugSubmitTranscript = Notification.Name("ipopDebugSubmitTranscript")
}

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from Claude's response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?

    // MARK: - Onboarding Video State (shared across all screen overlays)

    @Published var onboardingVideoPlayer: AVPlayer?
    @Published var showOnboardingVideo: Bool = false
    @Published var onboardingVideoOpacity: Double = 0.0
    private var onboardingVideoEndObserver: NSObjectProtocol?
    private var onboardingDemoTimeObserver: Any?

    // MARK: - Onboarding Prompt Bubble

    /// Text streamed character-by-character on the cursor after the onboarding video ends.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false
    private var onboardingPromptStreamTask: Task<Void, Never>?

    // MARK: - Onboarding Music

    private var onboardingMusicPlayer: AVAudioPlayer?
    private var onboardingMusicFadeTask: Task<Void, Never>?
    /// Process running `/usr/bin/say` for TTS fallback. Kept so we can
    /// terminate it when a new response starts before the old one finishes.
    private var macOSSpeechProcess: Process?
    private var elevenLabsSpeechTask: Task<Void, Never>?
    private static let defaultMacOSVoiceName = "Samantha"
    private static let defaultMacOSVoiceRate = 178

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    // Response text is now displayed inline on the cursor overlay via
    // streamingResponseText, so no separate response overlay manager is needed.

    private lazy var claudeAPI: any AnthropicChatClient = {
        if let zaiClient = ZAIChatClient.configuredIfEnabled(selectedModel: selectedModel) {
            activeChatProviderName = "Z.ai"
            FileLogger.log("✅ Using Z.ai direct API for responses")
            return RetryingChatClient(zaiClient, providerName: "Z.ai")
        }

        if let proxyURL = Self.configuredClaudeProxyURL() {
            activeChatProviderName = "Claude proxy"
            FileLogger.log("✅ Using Claude API Worker proxy for responses")
            return RetryingChatClient(
                ClaudeAPI(authMode: .proxyURL(proxyURL), model: selectedModel),
                providerName: "Claude proxy"
            )
        }

        if ClaudeCodeOAuthProvider.isAvailable() {
            activeChatProviderName = "Claude OAuth"
            FileLogger.log("✅ Using Claude Code OAuth direct API for responses")
            return RetryingChatClient(
                ClaudeAPI(authMode: .claudeCodeOAuth, model: selectedModel),
                providerName: "Claude OAuth"
            )
        }

        if ClaudeCodeCLIClient.isAvailable() {
            activeChatProviderName = "Claude CLI"
            FileLogger.log("⚠️ Claude API credentials unavailable — using Claude Code CLI subprocess fallback")
            return RetryingChatClient(
                ClaudeCodeCLIClient(model: selectedModel),
                providerName: "Claude CLI"
            )
        }

        activeChatProviderName = "Claude OAuth"
        FileLogger.log("⚠️ No Claude API proxy, OAuth token, or CLI found — using Claude Code OAuth direct API and surfacing auth errors")
        return RetryingChatClient(
            ClaudeAPI(authMode: .claudeCodeOAuth, model: selectedModel),
            providerName: "Claude OAuth"
        )
    }()

    private static func configuredClaudeProxyURL() -> String? {
        for key in ["ClaudeProxyURL"] {
            if let urlString = AppBundleConfiguration.stringValue(forKey: key) {
                return urlString
            }
        }
        let environment = ProcessInfo.processInfo.environment
        let urlString = (environment["IPOP_CLAUDE_PROXY_URL"] ?? environment["CLAUDE_PROXY_URL"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return urlString?.isEmpty == false ? urlString : nil
    }

    /// Codex CLI client for agent tasks ("build me a website", "create a spreadsheet", etc.)
    /// Uses the Codex runtime with the user's local Codex subscription.
    private let codexCLIClient = CodexCLIClient()

    /// Tracks all running and recently completed Codex agent sessions (the "siblings").
    let agentSessionManager = AgentSessionManager()

    /// Owns the floating siblings overlay window that shows mini sibling icons.
    private let agentSiblingsWindowManager = AgentSiblingsWindowManager()

    /// Owns the click-to-inspect detail panel that opens when the user taps
    /// a sibling icon. Renders the session's live Codex output.
    private let agentSessionDetailWindowManager = AgentSessionDetailWindowManager()

    /// Manages persistent memory across sessions: ~/.ipop-ai/memory.md, user.md, history.json.
    private let memoryManager = MemoryManager()

    /// Dedicated teaching controller. It owns active lesson state and keeps
    /// Teacher Mode isolated from generic recent chat history.
    let teacherModeController = TeacherModeController()

    /// Visual lesson surface used for instant, readable anchors while native
    /// apps such as Freeform are warming up.
    private let lessonVisualOverlayWindowManager = LessonVisualOverlayWindowManager()

    private lazy var agentCursorFlightCoordinator = AgentCursorFlightCoordinator(companionManager: self)

    /// Broad computer-use agent. Kept behind the explicit Agent Mode toggle.
    lazy var computerUseAgent = ComputerUseAgent(
        chatClient: claudeAPI,
        cursorFlightCoordinator: agentCursorFlightCoordinator
    )

    /// Plans broad "super app" work around the raw computer-use loop so
    /// iPOP has task memory, app skills, confirmations, and a visible status.
    private let superAppMissionControl = SuperAppMissionControl()
    private let tinyfishWebAgentClient = TinyfishWebAgentClient()
    @Published private(set) var superAppDashboardSnapshot: SuperAppDashboardSnapshot = .empty
    private var activeSuperAppPlan: SuperAppTaskPlan?

    @Published var seeModeEnabled: Bool = UserDefaults.standard.object(forKey: "seeModeEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "seeModeEnabled") {
        didSet {
            UserDefaults.standard.set(seeModeEnabled, forKey: "seeModeEnabled")
            seeModeEnabled ? startPresenceObservationIfNeeded() : stopPresenceObservation()
        }
    }
    @Published private(set) var presenceSnapshot: IPOPPresenceSnapshot = .empty
    private var presenceObservationTimer: Timer?
    private var lastNonIpopSeeContext: IPOPSeeContext?

    @Published var agentModeEnabled: Bool = UserDefaults.standard.bool(forKey: "agentModeEnabled") {
        didSet { UserDefaults.standard.set(agentModeEnabled, forKey: "agentModeEnabled") }
    }

    @Published var yoloModeEnabled: Bool = UserDefaults.standard.bool(forKey: "agentYoloModeEnabled") {
        didSet { UserDefaults.standard.set(yoloModeEnabled, forKey: "agentYoloModeEnabled") }
    }

    @Published var cuaDriverEnabled: Bool = UserDefaults.standard.object(forKey: CuaDriverBackend.userDefaultsKey) == nil
        ? CuaDriverBackend.defaultEnabled
        : UserDefaults.standard.bool(forKey: CuaDriverBackend.userDefaultsKey) {
        didSet { UserDefaults.standard.set(cuaDriverEnabled, forKey: CuaDriverBackend.userDefaultsKey) }
    }

    @Published private(set) var activeAgentRunState: AgentRunState = .idle

    /// Memory context block injected into every system prompt. Loaded at startup from disk.
    private var memoryCacheSystemPromptBlock: String = ""

    private lazy var elevenLabsTTSClient: ElevenLabsTTSClient = {
        return ElevenLabsTTSClient()
    }()

    /// Conversation history so Claude remembers prior exchanges within a session.
    /// Seeded from history.json on startup so sessions resume across app restarts.
    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?
    private var teacherSurfaceActionTask: Task<Void, Never>?
    private var currentTurnStartDate: Date?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var computerUseRunStateCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
#if DEBUG
    private var debugTranscriptObserver: NSObjectProtocol?
#endif
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?

    /// True when all three required permissions (accessibility, screen recording,
    /// microphone) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    /// The Claude model used for voice responses. Persisted to UserDefaults.
    @Published var selectedModel: String = CompanionManager.initialSelectedModel()
    @Published private(set) var activeChatProviderName: String = "Resolving"

    var activeRuntimeSummary: String {
        if activeChatProviderName == "Z.ai" {
            let textModel = ZAIChatClient.resolvedModel(
                selectedModel: selectedModel,
                hasImages: false
            )
            let visionModel = ZAIChatClient.resolvedModel(
                selectedModel: selectedModel,
                hasImages: true
            )
            return "Z.ai · text \(textModel) · vision \(visionModel)"
        }
        return "\(activeChatProviderName) · \(Self.shortModelName(selectedModel))"
    }

    func setSelectedModel(_ model: String) {
        selectedModel = model
        UserDefaults.standard.set(model, forKey: "selectedClaudeModel")
        UserDefaults.standard.set(true, forKey: "hasExplicitlySelectedClaudeModel")
        claudeAPI.model = model
        FileLogger.log("🧠 Runtime model selected: \(activeRuntimeSummary)")
    }

    private static func initialSelectedModel() -> String {
        let defaults = UserDefaults.standard
        let fastModel = "claude-haiku-4-5-20251001"
        guard let storedModel = defaults.string(forKey: "selectedClaudeModel") else {
            return fastModel
        }
        // Migrate the old launch default from Sonnet to Fast. If the user picks
        // Sonnet from the menu after this build, the explicit-selection flag
        // preserves that choice.
        if storedModel == "claude-sonnet-4-6",
           defaults.bool(forKey: "hasExplicitlySelectedClaudeModel") == false {
            return fastModel
        }
        return storedModel
    }

    private static func shortModelName(_ modelID: String) -> String {
        if modelID.contains("haiku") { return "Haiku 4.5" }
        if modelID.contains("sonnet") { return "Sonnet 4.6" }
        if modelID.contains("opus") { return "Opus 4.6" }
        return modelID
    }

    /// User preference for whether the cursor should be shown.
    /// When toggled off, the overlay is hidden and push-to-talk is disabled.
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isIpopCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isIpopCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isIpopCursorEnabled")

    func setIpopCursorEnabled(_ enabled: Bool) {
        isIpopCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isIpopCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    /// Whether the user has submitted their email during onboarding.
    @Published var hasSubmittedEmail: Bool = UserDefaults.standard.bool(forKey: "hasSubmittedEmail")

    /// Records that the user dismissed the optional email step.
    /// Production beta builds do not transmit email addresses from the app.
    func submitEmail(_ email: String) {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else { return }

        hasSubmittedEmail = true
        UserDefaults.standard.set(true, forKey: "hasSubmittedEmail")
    }

    func start() {
        refreshAllPermissions()
        print("🔑 ipop.ai start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        bindComputerUseStateObservation()
        startPresenceObservationIfNeeded()
#if DEBUG
        installDebugTranscriptObserver()
#endif

        // Load persistent memory and seed conversation history from previous sessions
        let sessionContext = memoryManager.loadSessionContext()
        memoryCacheSystemPromptBlock = sessionContext.systemPromptBlock
        // Seed with up to the last 5 exchanges so the session resumes naturally
        conversationHistory = sessionContext.seedHistory.suffix(5).map { $0 }
        print("🧠 Codex CLI available: \(CodexCLIClient.isAvailable())")

        // Wire the detail panel's "Send" button to actually send a follow-up
        // message to the corresponding codex session.
        agentSessionDetailWindowManager.onSendFollowUp = { [weak self] sessionID, prompt in
            guard let self else { return }
            print("🔁 Detail panel follow-up requested for session \(sessionID): \(prompt.prefix(80))")
            self.agentSessionManager.sendFollowUp(
                sessionID: sessionID,
                prompt: prompt,
                codexClient: self.codexCLIClient
            )
        }

        // Save memory when the app quits — runs end-of-session summarization.
        // ALSO synchronously kill the codex app-server process tree; without
        // this, every app restart leaks the codex subprocess, which keeps
        // running indefinitely and consuming the user's quota.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.memoryManager.onSessionEnd(fullSessionHistory: self.conversationHistory)
                CodexAppServerClient.shared.shutdownSync()
            }
        }

        // Eagerly touch the Claude API so its TLS warmup handshake completes
        // well before the onboarding demo fires at ~40s into the video.
        _ = claudeAPI

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted && isIpopCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
    }

    /// Called by BlueCursorView after the buddy finishes its pointing
    /// animation and returns to cursor-following mode.
    /// Triggers the onboarding sequence — dismisses the panel and restarts
    /// the overlay so the welcome animation and intro video play.
    func triggerOnboarding() {
        // Post notification so the panel manager can dismiss the panel
        NotificationCenter.default.post(name: .ipopDismissPanel, object: nil)

        // Mark onboarding as completed so the Start button won't appear
        // again on future launches — the cursor will auto-show instead
        hasCompletedOnboarding = true

        IpopAnalytics.trackOnboardingStarted()

        // Play Besaid theme at 60% volume, fade out after 1m 30s
        startOnboardingMusic()

        // Show the overlay for the first time — isFirstAppearance triggers
        // the welcome animation and onboarding video
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    /// Replays the onboarding experience from the "Watch Onboarding Again"
    /// footer link. Same flow as triggerOnboarding but the cursor overlay
    /// is already visible so we just restart the welcome animation and video.
    func replayOnboarding() {
        NotificationCenter.default.post(name: .ipopDismissPanel, object: nil)
        IpopAnalytics.trackOnboardingReplayed()
        startOnboardingMusic()
        // Tear down any existing overlays and recreate with isFirstAppearance = true
        overlayWindowManager.hasShownOverlayBefore = false
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    private func stopOnboardingMusic() {
        onboardingMusicFadeTask?.cancel()
        onboardingMusicFadeTask = nil
        onboardingMusicPlayer?.stop()
        onboardingMusicPlayer = nil
    }

    private func startOnboardingMusic() {
        stopOnboardingMusic()
        guard let musicURL = Bundle.main.url(forResource: "ff", withExtension: "mp3") else {
            print("⚠️ ipop.ai: ff.mp3 not found in bundle")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: musicURL)
            player.volume = 0.3
            player.play()
            self.onboardingMusicPlayer = player

            scheduleOnboardingMusicFade(after: 90.0)
        } catch {
            print("⚠️ ipop.ai: Failed to play onboarding music: \(error)")
        }
    }

    private func fadeOutOnboardingMusic() {
        scheduleOnboardingMusicFade(after: 0)
    }

    private func scheduleOnboardingMusicFade(after delay: TimeInterval) {
        onboardingMusicFadeTask?.cancel()
        let fadeSteps = 30
        let fadeDuration: Double = 3.0
        let stepInterval = fadeDuration / Double(fadeSteps)

        onboardingMusicFadeTask = Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled, let self, let player = self.onboardingMusicPlayer else {
                return
            }

            let volumeDecrement = player.volume / Float(fadeSteps)
            for _ in 0..<fadeSteps {
                guard !Task.isCancelled, let activePlayer = self.onboardingMusicPlayer else {
                    return
                }
                activePlayer.volume = max(0, activePlayer.volume - volumeDecrement)
                try? await Task.sleep(nanoseconds: UInt64(stepInterval * 1_000_000_000))
            }

            guard !Task.isCancelled, let activePlayer = self.onboardingMusicPlayer else {
                return
            }
            activePlayer.stop()
            self.onboardingMusicPlayer = nil
            self.onboardingMusicFadeTask = nil
        }
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    func stop() {
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()

        currentResponseTask?.cancel()
        currentResponseTask = nil
        teacherSurfaceActionTask?.cancel()
        teacherSurfaceActionTask = nil
        lessonVisualOverlayWindowManager.hide()
        shortcutTransitionCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        computerUseRunStateCancellable?.cancel()
        stopPresenceObservation()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
#if DEBUG
        if let debugTranscriptObserver {
            DistributedNotificationCenter.default().removeObserver(debugTranscriptObserver)
            self.debugTranscriptObserver = nil
        }
#endif
    }

#if DEBUG
    private func installDebugTranscriptObserver() {
        guard debugTranscriptObserver == nil else { return }
        debugTranscriptObserver = DistributedNotificationCenter.default().addObserver(
            forName: .ipopDebugSubmitTranscript,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let transcript = notification.userInfo?["transcript"] as? String else { return }
            Task { @MainActor [weak self] in
                self?.submitDebugTranscript(transcript)
            }
        }
        FileLogger.log("🧪 Debug transcript injection enabled")
    }

    private func submitDebugTranscript(_ transcript: String) {
        let finalTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !finalTranscript.isEmpty else { return }
        lastTranscript = finalTranscript
        FileLogger.log("🧪 Debug transcript: \(finalTranscript)")
        sendTranscriptToClaudeWithScreenshot(transcript: finalTranscript)
    }
#endif

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        }

        // Track individual permission grants as they happen
        if !previouslyHadAccessibility && hasAccessibilityPermission {
            IpopAnalytics.trackPermissionGranted(permission: "accessibility")
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            IpopAnalytics.trackPermissionGranted(permission: "screen_recording")
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
            IpopAnalytics.trackPermissionGranted(permission: "microphone")
        }
        // Screen content permission is persisted — once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        if !previouslyHadAll && allPermissionsGranted {
            IpopAnalytics.trackAllPermissionsGranted()
        }
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                    IpopAnalytics.trackPermissionGranted(permission: "screen_content")

                    // If onboarding was already completed, show the cursor overlay now
                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isIpopCursorEnabled {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    private func bindComputerUseStateObservation() {
        computerUseRunStateCancellable = computerUseAgent.$runState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] runState in
                self?.activeAgentRunState = runState
                self?.updateSuperAppDashboard(for: runState)
            }
    }

    private func startPresenceObservationIfNeeded() {
        guard seeModeEnabled else { return }
        refreshPresenceSnapshot()
        guard presenceObservationTimer == nil else { return }
        presenceObservationTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshPresenceSnapshot()
            }
        }
    }

    private func stopPresenceObservation() {
        presenceObservationTimer?.invalidate()
        presenceObservationTimer = nil
        presenceSnapshot = .empty
    }

    private func refreshPresenceSnapshot() {
        guard seeModeEnabled else { return }
        var context = IPOPSeeContextReader.capture()
        if context.bundleIdentifier == Bundle.main.bundleIdentifier,
           let lastNonIpopSeeContext {
            context = lastNonIpopSeeContext
        } else if context.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastNonIpopSeeContext = context
        }

        presenceSnapshot = IPOPPresenceEngine.snapshot(
            from: context,
            recentTasks: Array(superAppMissionControl.recentTaskMemory().suffix(3)),
            agentModeEnabled: agentModeEnabled,
            teacherModeEnabled: teacherModeController.isEnabled
        )
    }

    func runSuggestedPresenceMove(_ move: IPOPProactiveMove) {
        let command = move.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        if move.requiresAgentMode {
            agentModeEnabled = true
        }
        lastTranscript = command
        sendTranscriptToClaudeWithScreenshot(transcript: command)
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }
                // Don't override .responding — the AI response pipeline
                // manages that state directly until streaming finishes.
                guard self.voiceState != .responding else { return }

                if isFinalizing {
                    self.voiceState = .processing
                } else if isRecording {
                    self.voiceState = .listening
                } else if isPreparing {
                    self.voiceState = .processing
                } else {
                    self.voiceState = .idle
                    // If the user pressed and released the hotkey without
                    // saying anything, no response task runs — schedule the
                    // transient hide here so the overlay doesn't get stuck.
                    // Only do this when no response is in flight, otherwise
                    // the brief idle gap between recording and processing
                    // would prematurely hide the overlay.
                    if self.currentResponseTask == nil {
                        self.scheduleTransientHideIfNeeded()
                    }
                }
            }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard !buddyDictationManager.isDictationInProgress else { return }
            // Don't register push-to-talk while the onboarding video is playing
            guard !showOnboardingVideo else { return }

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil

            // If the cursor is hidden, bring it back transiently for this interaction
            if !isIpopCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .ipopDismissPanel, object: nil)

            // Cancel any in-progress response and TTS from a previous utterance.
            // We also terminate the /usr/bin/say process immediately so the old
            // voice is silenced the moment the user starts a new push-to-talk —
            // otherwise the old voice keeps droning until the next Claude
            // response arrives, which can briefly overlap with the new reply.
            currentResponseTask?.cancel()
            elevenLabsSpeechTask?.cancel()
            elevenLabsSpeechTask = nil
            elevenLabsTTSClient.stopPlayback()
            macOSSpeechProcess?.terminate()
            macOSSpeechProcess = nil
            clearDetectedElementLocation()

            // Dismiss the onboarding prompt if it's showing
            if showOnboardingPrompt {
                withAnimation(.easeOut(duration: 0.3)) {
                    onboardingPromptOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.showOnboardingPrompt = false
                    self.onboardingPromptText = ""
                }
            }
    

            IpopAnalytics.trackPushToTalkStarted()

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in
                        // Partial transcripts are hidden (waveform-only UI)
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        self?.lastTranscript = finalTranscript
                        FileLogger.log("🗣️ Companion received transcript: \(finalTranscript)")
                        IpopAnalytics.trackUserMessageSent(transcript: finalTranscript)
                        self?.sendTranscriptToClaudeWithScreenshot(transcript: finalTranscript)
                    }
                )
            }
        case .released:
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            IpopAnalytics.trackPushToTalkReleased()
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
        case .none:
            break
        }
    }

    // MARK: - Companion Prompt

    /// Builds the system prompt, prepending the memory context block so ipop.ai
    /// remembers facts and preferences from previous sessions.
    private var companionVoiceResponseSystemPromptWithMemory: String {
        memoryCacheSystemPromptBlock + Self.companionVoiceResponseSystemPrompt
    }

    private var textOnlyVoiceResponseSystemPromptWithMemory: String {
        memoryCacheSystemPromptBlock + Self.companionVoiceResponseSystemPrompt + """

        this turn does not include a screenshot. answer from the user's words, memory, and conversation context only. do not claim you can see the screen. end with [POINT:none].
        """
    }

    private static let companionVoiceResponseSystemPrompt = """
    you're ipop.ai, a friendly always-on companion that lives in the user's menu bar. the user just spoke to you via push-to-talk and you can see their screen(s). your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.

    rules:
    - default to one or two sentences. be direct and dense. BUT if the user asks you to explain more, go deeper, or elaborate, then go all out — give a thorough, detailed explanation with no length limit.
    - all lowercase, casual, warm. no emojis.
    - write for the ear, not the eye. short sentences. no lists, bullet points, markdown, or formatting — just natural speech.
    - don't use abbreviations or symbols that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
    - if the user's question relates to what's on their screen, reference specific things you see.
    - if the screenshot doesn't seem relevant to their question, just answer the question directly.
    - you can help with anything — coding, writing, general knowledge, brainstorming.
    - never say "simply" or "just".
    - don't read out code verbatim. describe what the code does or what needs to change conversationally.
    - never click, type, press return, or submit anything that could send a message, submit an application/form, make a purchase/payment, delete data, or change an account unless the user has explicitly confirmed that final action.
    - focus on giving a thorough, useful explanation. don't end with simple yes/no questions like "want me to explain more?" or "should i show you?" — those are dead ends that force the user to just say yes.
    - instead, when it fits naturally, end by planting a seed — mention something bigger or more ambitious they could try, a related concept that goes deeper, or a next-level technique that builds on what you just explained. make it something worth coming back for, not a question they'd just nod to. it's okay to not end with anything extra if the answer is complete on its own.
    - if you receive multiple screen images, the one labeled "primary focus" is where the cursor is — prioritize that one but reference others if relevant.

    mac actions:
    when the user asks you to do something on their mac, emit action tags instead of only talking. tags execute in order:
    [OPEN_APP:Notes], [QUIT_APP:Safari], [CLICK:File], [TYPE:hello], [KEY:cmd+s], [SCROLL:down].
    for example, if they say "make a note about pasta tonight", respond with [OPEN_APP:Notes] [KEY:cmd+n] [TYPE:pasta tonight].
    keep any spoken words short; if the tags fully do the task, you can output only tags.

    element pointing:
    you have a small blue triangle cursor that can fly to and point at things on screen. use it whenever pointing would genuinely help the user — if they're asking how to do something, looking for a menu, trying to find a button, or need help navigating an app, point at the relevant element. err on the side of pointing rather than not pointing, because it makes your help way more useful and concrete.

    don't point at things when it would be pointless — like if the user asks a general knowledge question, or the conversation has nothing to do with what's on screen, or you'd just be pointing at something obvious they're already looking at. but if there's a specific UI element, menu, button, or area on screen that's relevant to what you're helping with, point at it.

    when you point, append a coordinate tag at the very end of your response, AFTER your spoken text. the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. the origin (0,0) is the top-left corner of the image. x increases rightward, y increases downward.

    format: [POINT:x,y:label] where x,y are integer pixel coordinates in the screenshot's coordinate space, and label is a short 1-3 word description of the element (like "search bar" or "save button"). if the element is on the cursor's screen you can omit the screen number. if the element is on a DIFFERENT screen, append :screenN where N is the screen number from the image label (e.g. :screen2). this is important — without the screen number, the cursor will point at the wrong place.

    if pointing wouldn't help, append [POINT:none].

    examples:
    - user asks how to color grade in final cut: "you'll want to open the color inspector — it's right up in the top right area of the toolbar. click that and you'll get all the color wheels and curves. [POINT:1100,42:color inspector]"
    - user asks what html is: "html stands for hypertext markup language, it's basically the skeleton of every web page. curious how it connects to the css you're looking at? [POINT:none]"
    - user asks how to commit in xcode: "see that source control menu up top? click that and hit commit, or you can use command option c as a shortcut. [POINT:285,11:source control]"
    - element is on screen 2 (not where cursor is): "that's over on your other monitor — see the terminal window? [POINT:400,300:terminal:screen2]"
    """

    nonisolated static func shouldCaptureScreenForTranscript(_ transcript: String) -> Bool {
        let lower = transcript
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty else { return false }

        let visualPhrases = [
            "on my screen", "on the screen", "on screen",
            "what do you see", "what can you see", "what's on",
            "what is on", "look at", "look over", "take a look",
            "do you see", "can you see", "this screen",
            "this page", "this window", "this app", "this error",
            "this code", "this file", "this button", "this menu",
            "that button", "that menu", "that window",
            "point at", "point to", "show me where",
            "where is", "where's", "which button", "which menu",
        ]
        if visualPhrases.contains(where: { lower.contains($0) }) {
            return true
        }

        let words = Set(
            lower
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
        )
        let visualWords: Set<String> = [
            "screen", "screenshot", "visible", "shown", "looking",
            "cursor", "pointer", "button", "menu", "icon", "tab",
            "window", "panel", "sidebar", "toolbar", "dialog",
            "xcode", "chrome", "safari", "browser", "page",
            "click", "tap", "select", "navigate", "scroll",
        ]
        if !words.isDisjoint(with: visualWords) {
            return true
        }

        let textOnlyPrefixes = [
            "what is", "what's", "who is", "who's", "why",
            "how do i", "how can i", "how should i",
            "explain", "define", "tell me about", "teach me",
            "brainstorm", "write", "draft", "rewrite", "summarize",
            "should i", "help me think", "give me ideas",
        ]
        if textOnlyPrefixes.contains(where: { lower.hasPrefix($0) }) {
            return false
        }

        let deicticWords: Set<String> = ["this", "that", "these", "those", "here"]
        return !words.isDisjoint(with: deicticWords)
    }

    private func routeTranscriptToCodexIfNeeded(
        _ transcript: String,
        presenceSnapshot: IPOPPresenceSnapshot
    ) async -> Bool {
        // Route to Codex before screenshot capture. Agent tasks do not need
        // screen pixels, and avoiding capture keeps multi-agent requests snappy.
        let isAgent = CodexCLIClient.isAgentTask(transcript)
        let codexAvailable = CodexCLIClient.isAvailable()
        print("🎙️ Transcript received: \"\(transcript)\"")
        print("🤖 isAgentTask: \(isAgent), Codex available: \(codexAvailable)")
        guard isAgent && codexAvailable else { return false }

        // PRIVACY: do NOT pass screenshots to Codex agents. Codex tasks
        // should not receive visible emails, browser tabs, files, or other
        // sensitive desktop state unless the user explicitly provides it.
        let screenshotsForCodex: [(data: Data, label: String)] = []
        let memoryBlock = [
            memoryCacheSystemPromptBlock,
            presenceSnapshot.promptBlock
        ]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        // If the user asked for multiple parallel sessions ("spawn two
        // sessions, one for X and one for Y"), decompose into N tasks.
        let parallelTasks = await CodexCLIClient.decomposeTaskIntoParallelTasksWithLLMFallback(transcript)
        print("🤖 Decomposed into \(parallelTasks.count) parallel task(s):")
        for (taskIndex, task) in parallelTasks.enumerated() {
            print("   #\(taskIndex + 1): \(task)")
        }

        // Show the siblings overlay. The onSelectSession callback fires when
        // a sibling icon is tapped, opening the detail panel anchored there.
        agentSiblingsWindowManager.show(
            sessionManager: agentSessionManager,
            onSelectSession: { [weak self] sessionID, overlayFrame in
                guard let self else { return }
                self.agentSessionDetailWindowManager.show(
                    sessionID: sessionID,
                    sessionManager: self.agentSessionManager,
                    anchoredTo: overlayFrame
                )
            }
        )

        // Acknowledge verbally, then go idle so the user can keep talking
        // while agents work in the background.
        voiceState = .idle
        let acknowledgment = parallelTasks.count > 1
            ? "On it. Spawning \(parallelTasks.count) agents."
            : "On it."
        speakWithPreferredVoice(acknowledgment)
        scheduleTransientHideIfNeeded()

        // Launch one sibling per task — they all run in parallel.
        for (taskIndex, individualTask) in parallelTasks.enumerated() {
            let isMultiTask = parallelTasks.count > 1
            agentSessionManager.launchAgent(
                prompt: individualTask,
                screenshots: screenshotsForCodex,
                memoryContextBlock: memoryBlock,
                codexClient: codexCLIClient
            ) { [weak self] agentResult in
                guard let self else { return }
                let trimmedResult = agentResult.trimmingCharacters(in: .whitespacesAndNewlines)
                self.conversationHistory.append((userTranscript: individualTask, assistantResponse: trimmedResult))
                if self.conversationHistory.count > 10 {
                    self.conversationHistory.removeFirst(self.conversationHistory.count - 10)
                }
                self.memoryManager.onTurnCompleted(userTranscript: individualTask, assistantResponse: trimmedResult)
                // Speak only a short confirmation. The user can click the
                // sibling icon to see the full result.
                let confirmation = isMultiTask
                    ? "Task \(taskIndex + 1) ready."
                    : "Done."
                self.speakWithPreferredVoice(confirmation)
                if !self.agentSessionManager.hasAnySessions {
                    self.agentSiblingsWindowManager.hide()
                    self.agentSessionDetailWindowManager.hide()
                }
            }
        }
        return true
    }

    private func routeTranscriptToLocalIntentIfNeeded(_ transcript: String) async -> Bool {
        let localIntent = LocalIntentRouter.route(transcript: transcript)
        guard localIntent != .unmatched else {
            FileLogger.log("🎯 LocalIntentRouter: unmatched (transcript: \"\(transcript)\") — falling to Claude")
            return false
        }

        FileLogger.log("🎯 LocalIntentRouter matched: \(localIntent) (transcript: \"\(transcript)\")")
        switch await LocalIntentExecutor.execute(localIntent) {
        case .succeeded(let spokenAcknowledgement):
            let assistantResponse = spokenAcknowledgement.isEmpty
                ? "(executed: \(localIntent))"
                : spokenAcknowledgement
            conversationHistory.append((userTranscript: transcript, assistantResponse: assistantResponse))
            if conversationHistory.count > 10 {
                conversationHistory.removeFirst(conversationHistory.count - 10)
            }
            memoryManager.onTurnCompleted(userTranscript: transcript, assistantResponse: assistantResponse)

            if !spokenAcknowledgement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                speakWithPreferredVoice(spokenAcknowledgement)
                voiceState = .responding
            } else {
                voiceState = .idle
            }
            scheduleTransientHideIfNeeded()
            return true
        case .failed(let reason):
            FileLogger.log("⚠️ LocalIntent fell through: \(reason)")
            return false
        }
    }

    // MARK: - AI Response Pipeline

    /// Captures a screenshot, sends it along with the transcript to Claude,
    /// and plays the response aloud via ElevenLabs TTS. The cursor stays in
    /// the spinner/processing state until TTS audio begins playing.
    /// Claude's response may include a [POINT:x,y:label] tag which triggers
    /// the buddy to fly to that element on screen.
    private func sendTranscriptToClaudeWithScreenshot(transcript: String) {
        currentResponseTask?.cancel()
        teacherSurfaceActionTask?.cancel()
        teacherSurfaceActionTask = nil
        elevenLabsSpeechTask?.cancel()
        elevenLabsSpeechTask = nil
        elevenLabsTTSClient.stopPlayback()
        macOSSpeechProcess?.terminate()
        macOSSpeechProcess = nil
        refreshPresenceSnapshot()
        let currentPresenceSnapshot = presenceSnapshot

        let shouldRouteToCodexAgent = CodexCLIClient.isAgentTask(transcript) && CodexCLIClient.isAvailable()
        let learningRoute = LearningIntentRouter.route(
            transcript: transcript,
            isTeacherModeEnabled: teacherModeController.isEnabled,
            hasActiveLesson: teacherModeController.hasActiveLesson
        )
        let shouldRouteToTeacherMode = !shouldRouteToCodexAgent && learningRoute == .teacherMode
        let localIntent = LocalIntentRouter.route(transcript: transcript)

        if learningRoute == .endLesson {
            runEndLessonTurn(transcript: transcript)
            return
        }

        if localIntent != .unmatched && !shouldRouteToTeacherMode {
            clearTeacherSurfaceForNonLearningTurn(reason: "local intent \(localIntent)")
            runLocalIntentTurn(transcript: transcript, intent: localIntent)
            return
        }

        if shouldRouteToTeacherMode {
            currentResponseTask = Task {
                voiceState = .processing
                do {
                    try await runTeacherLessonTurn(transcript: transcript)
                } catch is CancellationError {
                    // User spoke again — teacher turn was interrupted.
                } catch {
                    IpopAnalytics.trackResponseError(error: error.localizedDescription)
                    print("⚠️ Teacher Mode error: \(error)")
                    speakCreditsErrorFallback()
                }

                if !Task.isCancelled {
                    voiceState = .idle
                    scheduleTransientHideIfNeeded()
                }
            }
            return
        }

        if let tinyfishTask = TinyfishWebTaskRouter.route(
            transcript: transcript,
            screenContext: currentPresenceSnapshot.promptBlock
        ) {
            clearTeacherSurfaceForNonLearningTurn(reason: "tinyfish web agent turn")
            runTinyfishWebAgentTurn(
                task: tinyfishTask,
                presenceSnapshot: currentPresenceSnapshot
            )
            return
        }

        if agentModeEnabled && !shouldRouteToCodexAgent && Self.shouldRouteToComputerUseAgent(transcript) {
            clearTeacherSurfaceForNonLearningTurn(reason: "computer-use agent turn")
            runComputerUseAgentTurn(
                forUserInstruction: transcript,
                presenceSnapshot: currentPresenceSnapshot
            )
            return
        }

        currentResponseTask = Task {
            clearTeacherSurfaceForNonLearningTurn(reason: shouldRouteToCodexAgent ? "codex agent turn" : "general conversation turn")
            // Stay in processing (spinner) state — no streaming text displayed
            voiceState = .processing
            currentTurnStartDate = Date()
            logPipelinePhase("turn started")

            do {
                if await routeTranscriptToCodexIfNeeded(
                    transcript,
                    presenceSnapshot: currentPresenceSnapshot
                ) {
                    return
                }

                let shouldCaptureScreen = Self.shouldCaptureScreenForTranscript(transcript)
                let screenCaptures: [CompanionScreenCapture]
                let labeledImages: [(data: Data, label: String)]
                if shouldCaptureScreen {
                    // Capture all connected screens only when the transcript
                    // actually needs visual context. Vision turns are much
                    // slower and send a lot more data to Claude.
                    screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
                    logPipelinePhase("screenshots captured (\(screenCaptures.count))")

                    guard !Task.isCancelled else { return }

                    // Build image labels with the actual screenshot pixel dimensions
                    // so Claude's coordinate space matches the image it sees. We
                    // scale from screenshot pixels to display points ourselves.
                    labeledImages = screenCaptures.map { capture in
                        let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                        return (data: capture.imageData, label: capture.label + dimensionInfo)
                    }
                } else {
                    screenCaptures = []
                    labeledImages = []
                    logPipelinePhase("text-only turn (no screenshot)")
                }

                // Pass conversation history so Claude remembers prior exchanges
                let historyForAPI = conversationHistory.map { entry in
                    (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
                }

                let userPromptWithAppContext = """
                \(currentPresenceSnapshot.promptBlock)

                \(transcript)
                """

                var didReceiveFirstChunk = false
                let (fullResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: shouldCaptureScreen
                        ? companionVoiceResponseSystemPromptWithMemory
                        : textOnlyVoiceResponseSystemPromptWithMemory,
                    conversationHistory: historyForAPI,
                    userPrompt: userPromptWithAppContext,
                    onTextChunk: { [weak self] _ in
                        // No streaming text display — spinner stays until TTS plays
                        if !didReceiveFirstChunk {
                            didReceiveFirstChunk = true
                            self?.logPipelinePhase("first stream chunk")
                        }
                    }
                )

                guard !Task.isCancelled else { return }

                logPipelinePhase("stream complete (\(fullResponseText.count) chars)")
                FileLogger.log("📝 Claude raw response:\n  ┌─\n  │ \(fullResponseText.replacingOccurrences(of: "\n", with: "\n  │ "))\n  └─")

                // Parse pointing plus native action tags, then execute actions.
                let compoundResult = ActionTagParser.parseAllActionTags(from: fullResponseText)
                FileLogger.log("📝 Parsed \(compoundResult.actions.count) action tags from response")
                let parseResult = compoundResult.pointResult
                let actionSequenceRequiresConfirmation = Self.companionActionTagsRequireConfirmation(
                    transcript: transcript,
                    actions: compoundResult.actions
                )

                var actionSafetyMessages: [String] = []
                var previousActionToolUseBlock: ParsedToolUseBlock? = nil
                for action in compoundResult.actions {
                    let toolUseBlock = Self.synthesizedToolUseBlock(forCompanionAction: action)
                    let safetyDecision = Self.companionActionSequenceSafetyDecision(
                        for: action,
                        requiresConfirmation: actionSequenceRequiresConfirmation
                    ) ?? AgentSafetyClassifier.classify(
                        toolUseBlock: toolUseBlock,
                        previousToolUseBlock: previousActionToolUseBlock,
                        missionRequiresConfirmation: actionSequenceRequiresConfirmation
                    )

                    switch safetyDecision {
                    case .auto:
                        let executionResult = await LocalIntentExecutor.execute(action)
                        switch executionResult {
                        case .succeeded:
                            FileLogger.log("⚡️ Claude action executed: \(action)")
                            previousActionToolUseBlock = toolUseBlock
                        case .failed(let reason):
                            FileLogger.log("⚠️ Claude action failed: \(action) — \(reason)")
                        }
                    case .confirmRequired(let reason):
                        FileLogger.log("🛑 Claude action skipped pending confirmation: \(action) — \(reason)")
                        actionSafetyMessages.append("i need your confirmation before i do that.")
                    case .blocked(let reason):
                        FileLogger.log("🛑 Claude action blocked: \(action) — \(reason)")
                        actionSafetyMessages.append("i blocked that action because it looked unsafe.")
                    }
                }
                let spokenText = Self.spokenText(
                    compoundResult.spokenText,
                    appendingSafetyMessages: actionSafetyMessages
                )

                // Handle element pointing if Claude returned coordinates.
                // Switch to idle BEFORE setting the location so the triangle
                // becomes visible and can fly to the target. Without this, the
                // spinner hides the triangle and the flight animation is invisible.
                let hasPointCoordinate = parseResult.coordinate != nil
                if hasPointCoordinate {
                    voiceState = .idle
                }

                // Pick the screen capture matching Claude's screen number,
                // falling back to the cursor screen if not specified.
                let targetScreenCapture: CompanionScreenCapture? = {
                    if let screenNumber = parseResult.screenNumber,
                       screenNumber >= 1 && screenNumber <= screenCaptures.count {
                        return screenCaptures[screenNumber - 1]
                    }
                    return screenCaptures.first(where: { $0.isCursorScreen })
                }()

                if let pointCoordinate = parseResult.coordinate,
                   let targetScreenCapture {
                    // Claude's coordinates are in the screenshot's pixel space
                    // (top-left origin, e.g. 1280x831). Scale to the display's
                    // point space (e.g. 1512x982), then convert to AppKit global coords.
                    let screenshotWidth = CGFloat(targetScreenCapture.screenshotWidthInPixels)
                    let screenshotHeight = CGFloat(targetScreenCapture.screenshotHeightInPixels)
                    let displayWidth = CGFloat(targetScreenCapture.displayWidthInPoints)
                    let displayHeight = CGFloat(targetScreenCapture.displayHeightInPoints)
                    let displayFrame = targetScreenCapture.displayFrame

                    // Clamp to screenshot coordinate space
                    let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                    let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))

                    // Scale from screenshot pixels to display points
                    let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                    let displayLocalY = clampedY * (displayHeight / screenshotHeight)

                    // Convert from top-left origin (screenshot) to bottom-left origin (AppKit)
                    let appKitY = displayHeight - displayLocalY

                    // Convert display-local coords to global screen coords
                    let globalLocation = CGPoint(
                        x: displayLocalX + displayFrame.origin.x,
                        y: appKitY + displayFrame.origin.y
                    )

                    detectedElementScreenLocation = globalLocation
                    detectedElementDisplayFrame = displayFrame
                    IpopAnalytics.trackElementPointed(elementLabel: parseResult.elementLabel)
                    print("🎯 Element pointing: (\(Int(pointCoordinate.x)), \(Int(pointCoordinate.y))) → \"\(parseResult.elementLabel ?? "element")\"")
                } else {
                    print("🎯 Element pointing: \(parseResult.elementLabel ?? "no element")")
                }

                // Save this exchange to conversation history (with the point tag
                // stripped so it doesn't confuse future context)
                conversationHistory.append((
                    userTranscript: transcript,
                    assistantResponse: spokenText
                ))

                // Keep only the last 10 exchanges to avoid unbounded context growth
                if conversationHistory.count > 10 {
                    conversationHistory.removeFirst(conversationHistory.count - 10)
                }

                // Persist exchange to disk and extract any memorable facts in the background
                memoryManager.onTurnCompleted(userTranscript: transcript, assistantResponse: spokenText)

                print("🧠 Conversation history: \(conversationHistory.count) exchanges")

                IpopAnalytics.trackAIResponseReceived(response: spokenText)

                // Prefer ElevenLabs when configured; fall back to macOS say so
                // a missing key never blocks the interaction.
                if !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    speakWithPreferredVoice(spokenText)
                    voiceState = .responding
                }
            } catch is CancellationError {
                // User spoke again — response was interrupted
            } catch {
                IpopAnalytics.trackResponseError(error: error.localizedDescription)
                print("⚠️ Companion response error: \(error)")
                speakCreditsErrorFallback()
            }

            if !Task.isCancelled {
                voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
        }
    }

    private func runEndLessonTurn(transcript: String) {
        currentResponseTask = Task {
            voiceState = .processing
            let endedLesson = teacherModeController.endLesson()
            lessonVisualOverlayWindowManager.hide()
            if endedLesson != nil {
                LearningActionExecutor.dismissPreparedLessonSurface()
            }
            let response: String
            if let endedLesson {
                response = "lesson wrapped. we were working on \(endedLesson.displayTitle)."
            } else {
                response = "no active lesson was running."
            }

            conversationHistory.append((userTranscript: transcript, assistantResponse: response))
            if conversationHistory.count > 10 {
                conversationHistory.removeFirst(conversationHistory.count - 10)
            }
            memoryManager.onTurnCompleted(userTranscript: transcript, assistantResponse: response)

            speakWithPreferredVoice(response)
            voiceState = .responding

            if !Task.isCancelled {
                voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
        }
    }

    private func clearTeacherSurfaceForNonLearningTurn(reason: String) {
        guard teacherModeController.hasActiveLesson else {
            lessonVisualOverlayWindowManager.hide()
            return
        }
        let endedLesson = teacherModeController.endLesson()
        teacherSurfaceActionTask?.cancel()
        teacherSurfaceActionTask = nil
        lessonVisualOverlayWindowManager.hide()
        LearningActionExecutor.dismissPreparedLessonSurface()
        FileLogger.log("🎓 Cleared teacher surface for \(reason): \(endedLesson?.displayTitle ?? "active lesson")")
    }

    private func runLocalIntentTurn(transcript: String, intent: LocalIntent) {
        FileLogger.log("🎯 LocalIntentRouter matched: \(intent) (transcript: \"\(transcript)\")")
        currentResponseTask = Task {
            voiceState = .processing
            let result = await LocalIntentExecutor.execute(intent)
            switch result {
            case .succeeded(let spokenAcknowledgement):
                let assistantResponse = spokenAcknowledgement.isEmpty
                    ? "(executed local action: \(intent))"
                    : spokenAcknowledgement
                conversationHistory.append((userTranscript: transcript, assistantResponse: assistantResponse))
                if conversationHistory.count > 10 {
                    conversationHistory.removeFirst(conversationHistory.count - 10)
                }
                memoryManager.onTurnCompleted(userTranscript: transcript, assistantResponse: assistantResponse)

                if !spokenAcknowledgement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    speakWithPreferredVoice(spokenAcknowledgement)
                    voiceState = .responding
                } else {
                    voiceState = .idle
                }
            case .failed(let reason):
                FileLogger.log("⚠️ LocalIntent failed: \(reason) (intent: \(intent))")
                let response = "I couldn't do that directly: \(reason)."
                memoryManager.onTurnCompleted(userTranscript: transcript, assistantResponse: response)
                speakWithPreferredVoice(response)
                voiceState = .responding
            }

            if !Task.isCancelled {
                scheduleTransientHideIfNeeded()
            }
        }
    }

    private func runTeacherLessonTurn(transcript: String) async throws {
        let turnStartedAt = Date()

        let bridgeText = teacherModeController.bridgeLine(for: transcript)
        speakWithPreferredVoice(bridgeText)
        let firstAudioMS = Self.milliseconds(since: turnStartedAt)
        voiceState = .processing

        let assetGatherStartedAt = Date()
        var screenCaptures = try await CompanionScreenCaptureUtility.captureCursorScreenAsJPEG()
        var frontmostAppName = NSWorkspace.shared.frontmostApplication?.localizedName
        var assetContext = LearningAssetContextBuilder.build(
            frontmostAppName: frontmostAppName,
            screenCaptures: screenCaptures
        )
        var assetGatherMS = Self.milliseconds(since: assetGatherStartedAt)
        var surfaceActionMS: Int?
        var preparedLearningSurfaceContext: String?
        var preparedDiagramSpec: FreeformDiagramSpec?

        if let immediateAction = teacherModeController.immediateLearningAction(
            transcript: transcript,
            assetContext: assetContext
        ) {
            if case .prepareFreeformDiagram(let diagramSpec) = immediateAction {
                preparedLearningSurfaceContext = diagramSpec.promptContext
                preparedDiagramSpec = diagramSpec
                lessonVisualOverlayWindowManager.show(spec: diagramSpec)
                assetContext = LearningAssetContext(
                    assetType: .whiteboard,
                    frontmostAppName: "iPOP lesson canvas",
                    candidateTopic: diagramSpec.title,
                    browserTitle: assetContext.browserTitle,
                    browserURL: assetContext.browserURL,
                    selectedFilePaths: assetContext.selectedFilePaths,
                    selectedFilePreview: assetContext.selectedFilePreview,
                    screenContextLines: assetContext.screenContextLines,
                    assetNotes: assetContext.assetNotes + [
                        "instant_lesson_canvas: iPOP displayed a large readable canvas immediately; native Freeform setup continues in the background."
                    ]
                )
                frontmostAppName = "iPOP lesson canvas"
                surfaceActionMS = 0
                runTeacherSurfaceActionInBackground(immediateAction)
            } else {
                let surfaceActionStartedAt = Date()
                let actionResult = await LearningActionExecutor.execute(immediateAction)
                surfaceActionMS = Self.milliseconds(since: surfaceActionStartedAt)
                print("🎓 Teacher surface action \(immediateAction.logLabel): \(actionResult)")

                let settleNanoseconds: UInt64
                switch immediateAction {
                case .openURL:
                    settleNanoseconds = 1_200_000_000
                default:
                    settleNanoseconds = 600_000_000
                }
                try? await Task.sleep(nanoseconds: settleNanoseconds)
                try Task.checkCancellation()

                let refreshedContextStartedAt = Date()
                screenCaptures = try await CompanionScreenCaptureUtility.captureCursorScreenAsJPEG()
                frontmostAppName = NSWorkspace.shared.frontmostApplication?.localizedName
                assetContext = LearningAssetContextBuilder.build(
                    frontmostAppName: frontmostAppName,
                    screenCaptures: screenCaptures
                )
                assetGatherMS += Self.milliseconds(since: refreshedContextStartedAt)
            }
        }

        let lesson = teacherModeController.beginOrUpdateLesson(
            transcript: transcript,
            assetContext: assetContext,
            preparedLearningSurfaceContext: preparedLearningSurfaceContext
        )

        let labeledImages = screenCaptures.map { capture in
            let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
            return (data: capture.imageData, label: capture.label + dimensionInfo)
        }
        let historyForAPI = lesson.recentTurns.suffix(4).map { turn in
            (userPlaceholder: turn.userTranscript, assistantResponse: turn.assistantResponse)
        }
        let teacherSystemPrompt = teacherModeController.systemPrompt(
            memoryContextBlock: memoryManager.loadTeacherMemoryPromptBlock(),
            learnerProfileBlock: memoryManager.loadLearnerProfilePromptBlock()
        )
        let teacherUserPrompt = teacherModeController.userPrompt(
            transcript: transcript,
            assetContext: assetContext,
            lesson: lesson
        )

        let modelStartedAt = Date()
        let rawTeachingMove: TeachingMove
        let modelMS: Int
        if let localMove = teacherModeController.localTeachingMove(
            transcript: transcript,
            lesson: lesson,
            preparedDiagramSpec: preparedDiagramSpec
        ) {
            rawTeachingMove = localMove
            modelMS = 0
        } else {
            let (fullResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                images: labeledImages,
                systemPrompt: teacherSystemPrompt,
                conversationHistory: historyForAPI,
                userPrompt: teacherUserPrompt,
                onTextChunk: { _ in }
            )
            try Task.checkCancellation()
            rawTeachingMove = TeachingMove.parse(from: fullResponseText)
            modelMS = Self.milliseconds(since: modelStartedAt)
        }

        let validatedTeachingMove = TeacherTurnValidator.repairedMove(
            rawTeachingMove,
            lesson: lesson,
            assetContext: assetContext
        )
        let qualityCheckedMove = TeacherQualityLoop.refinedMove(
            validatedTeachingMove,
            lesson: lesson,
            assetContext: assetContext
        )
        let experienceMove = LearningExperienceDesigner.refinedMove(
            qualityCheckedMove,
            lesson: lesson,
            assetContext: assetContext
        )
        let teachingMove = LearningPresenceEngine.refinedMove(
            experienceMove,
            transcript: transcript,
            lesson: lesson,
            assetContext: assetContext
        )
        let pointParseResult = Self.parsePointingCoordinates(from: teachingMove.responseWithPointTag())
        let spokenText = pointParseResult.spokenText
        applyPointing(pointParseResult, screenCaptures: screenCaptures, logPrefix: "Teacher pointing")

        var metrics = LessonTurnMetrics(
            transcriptMS: nil,
            firstAudioMS: firstAudioMS,
            assetGatherMS: assetGatherMS,
            surfaceActionMS: surfaceActionMS,
            modelMS: modelMS,
            ttsStartMS: nil,
            route: "teacher_mode",
            surface: assetContext.assetType.rawValue,
            memoryWriteEnabled: true
        )

        if !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            speakWithPreferredVoice(spokenText)
            metrics.ttsStartMS = Self.milliseconds(since: turnStartedAt)
            voiceState = .responding
        }

        let updatedLesson = teacherModeController.completeTurn(
            userTranscript: transcript,
            assistantResponse: spokenText,
            teachingMove: teachingMove,
            metrics: metrics
        )

        conversationHistory.append((userTranscript: transcript, assistantResponse: spokenText))
        if conversationHistory.count > 10 {
            conversationHistory.removeFirst(conversationHistory.count - 10)
        }
        memoryManager.onTeacherTurnCompleted(
            userTranscript: transcript,
            assistantResponse: spokenText,
            lessonSnapshot: updatedLesson
        )

        print("🎓 Teacher Mode lesson: \(updatedLesson?.displayTitle ?? lesson.displayTitle)")
        IpopAnalytics.trackAIResponseReceived(response: spokenText)

        if let modelAction = teachingMove.surfaceAction {
            let actionResult = await executeTeacherLearningAction(modelAction)
            print("🎓 Teacher follow-up action \(modelAction.logLabel): \(actionResult)")
        }
    }

    private func executeTeacherLearningAction(_ action: LearningAction) async -> String {
        if case .writeFreeformText(let noteText) = action {
            let noteCount = lessonVisualOverlayWindowManager.addBoardNote(noteText)
            return "wrote visible lesson note in overlay lane \(noteCount)"
        }

        if Self.shouldKeepLessonOnVisibleBrowserSurface(action, lesson: teacherModeController.activeLesson) {
            FileLogger.log("🎓 Skipped scratchpad action for browser lesson: \(action.logLabel)")
            return "kept browser lesson surface visible"
        }

        if Self.shouldExposeNativeFreeformSurface(for: action) {
            lessonVisualOverlayWindowManager.hide()
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        return await LearningActionExecutor.execute(action)
    }

    private func runTeacherSurfaceActionInBackground(_ action: LearningAction) {
        teacherSurfaceActionTask?.cancel()
        teacherSurfaceActionTask = Task {
            guard !Task.isCancelled else { return }
            if Self.shouldKeepLessonOnVisibleBrowserSurface(action, lesson: teacherModeController.activeLesson) {
                FileLogger.log("🎓 Skipped background scratchpad action for browser lesson: \(action.logLabel)")
                return
            }
            let actionResult = await LearningActionExecutor.execute(action)
            guard !Task.isCancelled else { return }
            print("🎓 Teacher background surface action \(action.logLabel): \(actionResult)")
        }
    }

    private static func shouldExposeNativeFreeformSurface(for action: LearningAction) -> Bool {
        switch action {
        case .prepareFreeformBoard:
            return true
        default:
            return false
        }
    }

    private static func shouldKeepLessonOnVisibleBrowserSurface(
        _ action: LearningAction,
        lesson: LessonSession?
    ) -> Bool {
        guard let lesson else { return false }

        let lessonSurfaceText = [
            lesson.topic,
            lesson.currentGoal,
            lesson.activeAppName ?? ""
        ]
            .joined(separator: " ")
            .lowercased()
        let shouldKeepVisibleSurface = lesson.assetType == .youtube
            || lesson.assetType == .browserPage
            || lessonSurfaceText.contains("youtube")
            || lessonSurfaceText.contains("video")
            || lessonSurfaceText.contains("browser")
            || lessonSurfaceText.contains("safari")
        guard shouldKeepVisibleSurface else { return false }

        switch action {
        case .openScratchpad, .writeScratchpad:
            return true
        case .openNativeApp(let appName):
            let normalizedAppName = appName
                .lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return normalizedAppName == "textedit" || normalizedAppName == "text edit"
        default:
            return false
        }
    }

    static func synthesizedToolUseBlock(forCompanionAction action: LocalIntent) -> ParsedToolUseBlock {
        let inputJSON: [String: Any]
        switch action {
        case .launchOrActivateApp(let name):
            inputJSON = ["action": "open_app", "text": name]
        case .quitApp(let name):
            inputJSON = ["action": "quit_app", "text": name]
        case .closeFrontmostWindow:
            inputJSON = ["action": "close_window"]
        case .closeWindowInApp(let name):
            inputJSON = ["action": "close_window", "text": name]
        case .calculateInCalculator(let expression):
            inputJSON = ["action": "type", "text": expression]
        case .createNote(let text):
            inputJSON = ["action": "type", "text": text]
        case .clickByName(let targetName):
            inputJSON = ["action": "ax_click", "text": targetName]
        case .typeText(let text):
            inputJSON = ["action": "type", "text": text]
        case .pressKeyChord(let chord):
            inputJSON = ["action": "key", "text": chord]
        case .scroll(let direction):
            inputJSON = ["action": "scroll", "text": String(describing: direction)]
        case .currentTime:
            inputJSON = ["action": "current_time"]
        case .unmatched:
            inputJSON = ["action": "none"]
        }

        return ParsedToolUseBlock(
            toolUseId: "companion-action-\(UUID().uuidString)",
            toolName: "computer",
            inputJSON: inputJSON
        )
    }

    static func companionActionTagsRequireConfirmation(
        transcript: String,
        actions: [LocalIntent]
    ) -> Bool {
        let normalizedTranscript = transcript.lowercased()
        let transcriptRiskSignals = [
            "draft a note", "make a note", "create a note", "write a note",
            "take a note", "jot down", "note down", "notes app",
            "draft an email", "send an email", "send a message", "submit",
            "apply to", "apply with", "payment", "purchase", "delete"
        ]
        if transcriptRiskSignals.contains(where: { normalizedTranscript.contains($0) }) {
            return true
        }

        let opensNotes = actions.contains { action in
            if case .launchOrActivateApp(let name) = action {
                return name.lowercased().contains("notes")
            }
            return false
        }
        let writesContent = actions.contains { action in
            if case .typeText = action { return true }
            if case .createNote = action { return true }
            return false
        }
        return opensNotes && writesContent
    }

    static func companionActionSequenceSafetyDecision(
        for action: LocalIntent,
        requiresConfirmation: Bool
    ) -> AgentSafetyDecision? {
        guard requiresConfirmation else { return nil }

        switch action {
        case .typeText, .createNote:
            return .confirmRequired(reason: "Mission requires approval before writing persistent or external content")
        case .pressKeyChord(let chord):
            let normalizedChord = chord
                .lowercased()
                .replacingOccurrences(of: "command", with: "cmd")
                .split(separator: "+")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "+")
            if normalizedChord == "cmd+n" || normalizedChord == "return" || normalizedChord == "cmd+return" {
                return .confirmRequired(reason: "Mission requires approval before creating or submitting content")
            }
            return nil
        default:
            return nil
        }
    }

    static func spokenText(
        _ base: String,
        appendingSafetyMessages safetyMessages: [String]
    ) -> String {
        var uniqueMessages: [String] = []
        for message in safetyMessages {
            guard !uniqueMessages.contains(message) else { continue }
            uniqueMessages.append(message)
        }

        guard !uniqueMessages.isEmpty else {
            return base
        }

        let trimmedBase = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let safetySuffix = uniqueMessages.joined(separator: " ")
        if trimmedBase.isEmpty {
            return safetySuffix
        }
        return "\(trimmedBase) \(safetySuffix)"
    }

    private func runComputerUseAgentTurn(
        forUserInstruction transcript: String,
        presenceSnapshot: IPOPPresenceSnapshot
    ) {
        let missionPlan = superAppMissionControl.plan(
            for: transcript,
            screenContext: presenceSnapshot.promptBlock
        )
        FileLogger.log("""
        🧭 SuperApp plan: \(missionPlan.objective)
        🧭 Apps: \(missionPlan.targetApps.map(\.displayName).joined(separator: ", "))
        🧭 Requires confirmation: \(missionPlan.requiresConfirmation)\(missionPlan.confirmationReason.map { " — \($0)" } ?? "")
        🧭 Steps: \(missionPlan.steps.map(\.title).joined(separator: " → "))
        """)
        activeSuperAppPlan = missionPlan
        superAppDashboardSnapshot = superAppMissionControl.dashboardSnapshot(
            for: missionPlan,
            status: .planning
        )

        currentResponseTask = Task {
            voiceState = .processing
            activeAgentRunState = .waitingForClaude
            superAppDashboardSnapshot = superAppMissionControl.dashboardSnapshot(
                for: missionPlan,
                status: .executing,
                currentStepIndex: 0
            )

            do {
                let agentResultText = try await computerUseAgent.runAgentTurn(
                    userInstruction: transcript,
                    yoloMode: yoloModeEnabled,
                    cuaDriverEnabled: cuaDriverEnabled,
                    missionRequiresConfirmation: missionPlan.requiresConfirmation,
                    upworkStandingSubmissionApproval: missionPlan.workflowContext?.contains("STANDING_UPWORK_SUBMISSION_APPROVAL=granted") == true,
                    missionContext: [
                        presenceSnapshot.promptBlock,
                        missionPlan.agentSystemContext
                    ].joined(separator: "\n\n")
                )

                try Task.checkCancellation()
                activeAgentRunState = .finishedWithText(agentResultText)
                superAppDashboardSnapshot = superAppMissionControl.dashboardSnapshot(
                    for: missionPlan,
                    status: .done,
                    currentStepIndex: max(missionPlan.steps.count - 1, 0),
                    resultSummary: agentResultText
                )
                superAppMissionControl.record(
                    plan: missionPlan,
                    status: .done,
                    resultSummary: agentResultText
                )
                conversationHistory.append((userTranscript: transcript, assistantResponse: agentResultText))
                if conversationHistory.count > 10 {
                    conversationHistory.removeFirst(conversationHistory.count - 10)
                }
                memoryManager.onTurnCompleted(userTranscript: transcript, assistantResponse: agentResultText)
                IpopAnalytics.trackAIResponseReceived(response: agentResultText)

                let trimmedResultText = agentResultText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedResultText.isEmpty {
                    speakWithPreferredVoice(trimmedResultText)
                    voiceState = .responding
                }
            } catch is CancellationError {
                activeAgentRunState = .idle
            } catch {
                activeAgentRunState = .failedWithError(error.localizedDescription)
                superAppDashboardSnapshot = superAppMissionControl.dashboardSnapshot(
                    for: missionPlan,
                    status: .failed,
                    currentStepIndex: max(missionPlan.steps.count - 1, 0),
                    resultSummary: error.localizedDescription
                )
                superAppMissionControl.record(
                    plan: missionPlan,
                    status: .failed,
                    resultSummary: error.localizedDescription
                )
                IpopAnalytics.trackResponseError(error: error.localizedDescription)
                print("⚠️ Agent run error: \(error)")
                speakWithPreferredVoice("Agent failed: \(error.localizedDescription)")
                voiceState = .responding
            }

            if !Task.isCancelled {
                voiceState = .idle
                activeSuperAppPlan = nil
                scheduleTransientHideIfNeeded()
            }
        }
    }

    private func runTinyfishWebAgentTurn(
        task: TinyfishWebAgentTask,
        presenceSnapshot: IPOPPresenceSnapshot
    ) {
        let missionPlan = superAppMissionControl.plan(
            for: task.originalTranscript,
            screenContext: presenceSnapshot.promptBlock
        )
        FileLogger.log("""
        🐟 Tinyfish web task: \(task.originalTranscript)
        🐟 URL: \(task.url.absoluteString)
        🐟 Requires confirmation: \(task.requiresConfirmation)\(task.confirmationReason.map { " — \($0)" } ?? "")
        🐟 Blocked: \(task.blockedReason ?? "no")
        """)

        activeSuperAppPlan = missionPlan
        superAppDashboardSnapshot = superAppMissionControl.dashboardSnapshot(
            for: missionPlan,
            status: .planning
        )

        currentResponseTask = Task {
            voiceState = .processing
            activeAgentRunState = .waitingForClaude
            superAppDashboardSnapshot = superAppMissionControl.dashboardSnapshot(
                for: missionPlan,
                status: .executing,
                currentStepIndex: 0,
                resultSummary: "Tinyfish is preparing the remote browser."
            )

            do {
                if let blockedReason = task.blockedReason {
                    throw TinyfishWebAgentError.blocked(reason: blockedReason)
                }
                if let confirmationReason = task.confirmationReason, task.requiresConfirmation {
                    throw TinyfishWebAgentError.confirmationRequired(reason: confirmationReason)
                }
                if !tinyfishWebAgentClient.isConfigured {
                    throw TinyfishWebAgentError.notConfigured
                }

                let result = try await tinyfishWebAgentClient.run(task)
                try Task.checkCancellation()

                let resultText = result.spokenSummary
                activeAgentRunState = .finishedWithText(resultText)
                superAppDashboardSnapshot = superAppMissionControl.dashboardSnapshot(
                    for: missionPlan,
                    status: .done,
                    currentStepIndex: max(missionPlan.steps.count - 1, 0),
                    resultSummary: resultText
                )
                superAppMissionControl.record(
                    plan: missionPlan,
                    status: .done,
                    resultSummary: resultText
                )
                conversationHistory.append((userTranscript: task.originalTranscript, assistantResponse: resultText))
                if conversationHistory.count > 10 {
                    conversationHistory.removeFirst(conversationHistory.count - 10)
                }
                memoryManager.onTurnCompleted(userTranscript: task.originalTranscript, assistantResponse: resultText)
                IpopAnalytics.trackAIResponseReceived(response: resultText)

                let trimmedResultText = resultText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedResultText.isEmpty {
                    speakWithPreferredVoice(trimmedResultText)
                    voiceState = .responding
                }
            } catch is CancellationError {
                activeAgentRunState = .idle
            } catch TinyfishWebAgentError.confirmationRequired(let reason) {
                let message = "I can use Tinyfish for that web task, but \(reason). I stopped before handing it to the remote browser."
                activeAgentRunState = .awaitingUserConfirmation(toolName: "tinyfish", humanReadableSummary: message)
                superAppDashboardSnapshot = superAppMissionControl.dashboardSnapshot(
                    for: missionPlan,
                    status: .needsConfirmation,
                    currentStepIndex: missionPlan.steps.firstIndex(where: { $0.needsUserConfirmation }) ?? 0,
                    resultSummary: message
                )
                speakWithPreferredVoice(message)
                voiceState = .responding
            } catch TinyfishWebAgentError.blocked(let reason) {
                let message = "I blocked that Tinyfish web task: \(reason)"
                activeAgentRunState = .failedWithError(message)
                superAppDashboardSnapshot = superAppMissionControl.dashboardSnapshot(
                    for: missionPlan,
                    status: .blocked,
                    currentStepIndex: 0,
                    resultSummary: message
                )
                speakWithPreferredVoice(message)
                voiceState = .responding
            } catch TinyfishWebAgentError.notConfigured {
                let message = "Tinyfish is wired in, but I do not have a local Tinyfish API key configured yet."
                activeAgentRunState = .failedWithError(message)
                superAppDashboardSnapshot = superAppMissionControl.dashboardSnapshot(
                    for: missionPlan,
                    status: .blocked,
                    currentStepIndex: 0,
                    resultSummary: message
                )
                speakWithPreferredVoice(message)
                voiceState = .responding
            } catch {
                let message = "Tinyfish web task failed: \(error.localizedDescription)"
                activeAgentRunState = .failedWithError(message)
                superAppDashboardSnapshot = superAppMissionControl.dashboardSnapshot(
                    for: missionPlan,
                    status: .failed,
                    currentStepIndex: max(missionPlan.steps.count - 1, 0),
                    resultSummary: message
                )
                superAppMissionControl.record(
                    plan: missionPlan,
                    status: .failed,
                    resultSummary: message
                )
                IpopAnalytics.trackResponseError(error: message)
                speakWithPreferredVoice(message)
                voiceState = .responding
            }

            if !Task.isCancelled {
                if case .awaitingUserConfirmation = activeAgentRunState {
                    // Keep the dashboard visible so the user can see why iPOP stopped.
                } else {
                    activeSuperAppPlan = nil
                    voiceState = .idle
                    scheduleTransientHideIfNeeded()
                }
            }
        }
    }

    private func updateSuperAppDashboard(for runState: AgentRunState) {
        guard let plan = activeSuperAppPlan else { return }

        switch runState {
        case .idle:
            return
        case .classifyingRequest, .capturingScreenshot:
            superAppDashboardSnapshot = superAppMissionControl.dashboardSnapshot(
                for: plan,
                status: .executing,
                currentStepIndex: 0
            )
        case .waitingForClaude:
            superAppDashboardSnapshot = superAppMissionControl.dashboardSnapshot(
                for: plan,
                status: .executing,
                currentStepIndex: min(1, max(plan.steps.count - 1, 0))
            )
        case .executingToolUse(let toolName):
            superAppDashboardSnapshot = superAppMissionControl.dashboardSnapshot(
                for: plan,
                status: .executing,
                currentStepIndex: min(2, max(plan.steps.count - 1, 0)),
                resultSummary: "Executing \(toolName)."
            )
        case .awaitingUserConfirmation(_, let humanReadableSummary):
            let confirmationStepIndex = plan.steps.firstIndex(where: { $0.needsUserConfirmation })
                ?? max(plan.steps.count - 2, 0)
            superAppDashboardSnapshot = superAppMissionControl.dashboardSnapshot(
                for: plan,
                status: .needsConfirmation,
                currentStepIndex: confirmationStepIndex,
                resultSummary: humanReadableSummary
            )
        case .finishedWithText(let text):
            superAppDashboardSnapshot = superAppMissionControl.dashboardSnapshot(
                for: plan,
                status: .done,
                currentStepIndex: max(plan.steps.count - 1, 0),
                resultSummary: text
            )
        case .failedWithError(let message):
            superAppDashboardSnapshot = superAppMissionControl.dashboardSnapshot(
                for: plan,
                status: .failed,
                currentStepIndex: max(plan.steps.count - 1, 0),
                resultSummary: message
            )
        }
    }

    private func applyPointing(
        _ parseResult: PointingParseResult,
        screenCaptures: [CompanionScreenCapture],
        logPrefix: String
    ) {
        if parseResult.coordinate != nil {
            voiceState = .idle
        }

        let targetScreenCapture: CompanionScreenCapture? = {
            if let screenNumber = parseResult.screenNumber,
               screenNumber >= 1 && screenNumber <= screenCaptures.count {
                return screenCaptures[screenNumber - 1]
            }
            return screenCaptures.first(where: { $0.isCursorScreen })
        }()

        if let pointCoordinate = parseResult.coordinate,
           let targetScreenCapture {
            let screenshotWidth = CGFloat(targetScreenCapture.screenshotWidthInPixels)
            let screenshotHeight = CGFloat(targetScreenCapture.screenshotHeightInPixels)
            let displayWidth = CGFloat(targetScreenCapture.displayWidthInPoints)
            let displayHeight = CGFloat(targetScreenCapture.displayHeightInPoints)
            let displayFrame = targetScreenCapture.displayFrame

            let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
            let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))
            let displayLocalX = clampedX * (displayWidth / screenshotWidth)
            let displayLocalY = clampedY * (displayHeight / screenshotHeight)
            let appKitY = displayHeight - displayLocalY
            let globalLocation = CGPoint(
                x: displayLocalX + displayFrame.origin.x,
                y: appKitY + displayFrame.origin.y
            )

            detectedElementScreenLocation = globalLocation
            detectedElementDisplayFrame = displayFrame
            IpopAnalytics.trackElementPointed(elementLabel: parseResult.elementLabel)
            print("🎯 \(logPrefix): (\(Int(pointCoordinate.x)), \(Int(pointCoordinate.y))) -> \"\(parseResult.elementLabel ?? "element")\"")
        } else {
            print("🎯 \(logPrefix): \(parseResult.elementLabel ?? "no element")")
        }
    }

    private static func milliseconds(since startDate: Date) -> Int {
        Int(Date().timeIntervalSince(startDate) * 1_000)
    }

    private static func shouldRouteToComputerUseAgent(_ transcript: String) -> Bool {
        var normalized = transcript
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let leadingFillers = [
            "and, ", "and ", "um, ", "um ", "uh, ", "uh ",
            "so, ", "so ", "ipop, ", "ipop "
        ]
        var didStrip = true
        while didStrip {
            didStrip = false
            for filler in leadingFillers where normalized.hasPrefix(filler) {
                normalized = String(normalized.dropFirst(filler.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                didStrip = true
            }
        }

        let magicModeSignals = [
            "make this better",
            "make it better",
            "make this happen",
            "make it happen",
            "debug this",
            "fix this",
            "ship this",
            "apply to this",
            "apply for this",
            "draft this",
            "draft a reply",
            "summarize this page",
            "summarize this pdf",
            "summarize this call",
            "clean this mess",
            "clean this folder",
            "turn this into",
            "use this page",
            "watch this",
            "follow up",
            "keep checking",
            "take care of this",
            "handle this",
            "do this for me",
            "complete this",
            "finish this"
        ]
        if magicModeSignals.contains(where: { normalized.contains($0) }) {
            return true
        }

        let outcomeMissionSignals = [
            "upwork",
            "make money",
            "real money",
            "earn money",
            "earn income",
            "find clients",
            "find me clients",
            "find work",
            "find jobs",
            "job pipeline",
            "proposal",
            "send proposals",
            "apply to jobs",
            "apply for jobs",
            "long term",
            "long-term",
            "agentic task",
            "background task",
            "keep doing",
            "keep working",
            "monitor this",
            "automate this"
        ]
        if outcomeMissionSignals.contains(where: { normalized.contains($0) }) {
            return true
        }

        let questionStarters = [
            "what ", "what's ", "whats ", "why ", "how ", "explain ",
            "who ", "when ", "where ", "is ", "are ", "do ", "does ",
            "did ", "can you explain", "could you explain"
        ]
        if questionStarters.contains(where: { normalized.hasPrefix($0) }) {
            return false
        }

        let macControlSignals = [
            "use ", "click ", "drag ", "move ", "resize ", "select ",
            "fill ", "submit ", "send ", "download ", "upload ",
            "search ", "find ", "navigate ", "organize ", "rename ",
            "configure ", "change ", "set ", "install ", "uninstall ",
            "open ", "close ", "quit ", "type ", "press ", "scroll ",
            "draft ", "summarize ", "watch ", "monitor ",
            "research ", "compare ", "extract ", "scrape ",
            "in safari", "in chrome", "in finder", "in xcode",
            "on my mac", "on the screen", "this window", "the window"
        ]
        return macControlSignals.contains { normalized.contains($0) }
    }

    /// If the cursor is in transient mode (user toggled "Show cursor" off),
    /// waits for TTS playback and any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    private func scheduleTransientHideIfNeeded() {
        guard !isIpopCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for TTS audio to finish playing
            while elevenLabsTTSClient.isPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor)
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 1s after everything finishes, then fade out
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    /// Speaks a hardcoded error message using macOS system TTS when API
    /// credits run out. Uses NSSpeechSynthesizer so it works even when
    /// ElevenLabs is down.
    private func speakCreditsErrorFallback() {
        speakWithPreferredVoice("Sorry, something went wrong. Please try again.")
        voiceState = .responding
    }

    private func logPipelinePhase(_ phaseName: String) {
        let elapsedMs: Int
        if let currentTurnStartDate {
            elapsedMs = Int(Date().timeIntervalSince(currentTurnStartDate) * 1000)
        } else {
            elapsedMs = 0
        }
        FileLogger.log("⏱️ [+\(elapsedMs)ms] \(phaseName)")
    }

    /// Speaks text via `/usr/bin/say` in a separate process so it cannot
    /// conflict with the app's AVAudioEngine (used for microphone capture).
    private func speakWithPreferredVoice(_ text: String) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        macOSSpeechProcess?.terminate()
        macOSSpeechProcess = nil
        elevenLabsSpeechTask?.cancel()
        elevenLabsSpeechTask = nil

        guard elevenLabsTTSClient.isConfigured else {
            FileLogger.log("🔊 ElevenLabs not configured — using macOS voice fallback")
            speakWithMacOSVoice(trimmedText)
            return
        }

        elevenLabsSpeechTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.elevenLabsTTSClient.speakText(trimmedText)
                if !Task.isCancelled {
                    self.elevenLabsSpeechTask = nil
                }
            } catch is CancellationError {
                // User interrupted playback.
            } catch {
                guard !Task.isCancelled else { return }
                IpopAnalytics.trackTTSError(error: error.localizedDescription)
                FileLogger.log("⚠️ ElevenLabs TTS failed: \(error.localizedDescription) — using macOS fallback")
                self.speakWithMacOSVoice(trimmedText)
                self.elevenLabsSpeechTask = nil
            }
        }
    }

    private func speakWithMacOSVoice(_ text: String) {
        macOSSpeechProcess?.terminate()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = [
            "-v", Self.configuredMacOSVoiceName(),
            "-r", "\(Self.configuredMacOSVoiceRate())",
            text
        ]
        macOSSpeechProcess = process
        try? process.run()
    }

    private static func configuredMacOSVoiceName() -> String {
        runtimeString(
            defaultsKeys: ["MacOSVoiceName"],
            infoKeys: ["MacOSVoiceName"],
            environmentKeys: ["IPOP_MACOS_VOICE_NAME", "MACOS_VOICE_NAME"]
        ) ?? defaultMacOSVoiceName
    }

    private static func configuredMacOSVoiceRate() -> Int {
        guard let rateString = runtimeString(
            defaultsKeys: ["MacOSVoiceRate"],
            infoKeys: ["MacOSVoiceRate"],
            environmentKeys: ["IPOP_MACOS_VOICE_RATE", "MACOS_VOICE_RATE"]
        ), let rate = Int(rateString) else {
            return defaultMacOSVoiceRate
        }
        return max(120, min(rate, 230))
    }

    private static func runtimeString(
        defaultsKeys: [String],
        infoKeys: [String],
        environmentKeys: [String]
    ) -> String? {
        for key in environmentKeys {
            if let value = ProcessInfo.processInfo.environment[key]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }

        for key in defaultsKeys {
            if let value = UserDefaults.standard.string(forKey: key)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }

        for key in infoKeys {
            if let value = AppBundleConfiguration.stringValue(forKey: key) {
                return value
            }
        }

        return nil
    }

    // MARK: - Point Tag Parsing

    /// Result of parsing a [POINT:...] tag from Claude's response.
    struct PointingParseResult {
        /// The response text with the [POINT:...] tag removed — this is what gets spoken.
        let spokenText: String
        /// The parsed pixel coordinate, or nil if Claude said "none" or no tag was found.
        let coordinate: CGPoint?
        /// Short label describing the element (e.g. "run button"), or "none".
        let elementLabel: String?
        /// Which screen the coordinate refers to (1-based), or nil to default to cursor screen.
        let screenNumber: Int?
    }

    /// Parses a [POINT:x,y:label:screenN] or [POINT:none] tag from the end of Claude's response.
    /// Returns the spoken text (tag removed) and the optional coordinate + label + screen number.
    static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        // Match [POINT:none] or [POINT:123,456:label] or [POINT:123,456:label:screen2]
        let pattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)) else {
            // No tag found at all
            return PointingParseResult(spokenText: responseText, coordinate: nil, elementLabel: nil, screenNumber: nil)
        }

        // Remove the tag from the spoken text
        let tagRange = Range(match.range, in: responseText)!
        let spokenText = String(responseText[..<tagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if it's [POINT:none]
        guard match.numberOfRanges >= 3,
              let xRange = Range(match.range(at: 1), in: responseText),
              let yRange = Range(match.range(at: 2), in: responseText),
              let x = Double(responseText[xRange]),
              let y = Double(responseText[yRange]) else {
            return PointingParseResult(spokenText: spokenText, coordinate: nil, elementLabel: "none", screenNumber: nil)
        }

        var elementLabel: String? = nil
        if match.numberOfRanges >= 4, let labelRange = Range(match.range(at: 3), in: responseText) {
            elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
        }

        var screenNumber: Int? = nil
        if match.numberOfRanges >= 5, let screenRange = Range(match.range(at: 4), in: responseText) {
            screenNumber = Int(responseText[screenRange])
        }

        return PointingParseResult(
            spokenText: spokenText,
            coordinate: CGPoint(x: x, y: y),
            elementLabel: elementLabel,
            screenNumber: screenNumber
        )
    }

    // MARK: - Onboarding Video

    /// Sets up the onboarding video player, starts playback, and schedules
    /// the demo interaction at 40s. Called by BlueCursorView when onboarding starts.
    func setupOnboardingVideo() {
        guard let videoURL = URL(string: "https://stream.mux.com/e5jB8UuSrtFABVnTHCR7k3sIsmcUHCyhtLu1tzqLlfs.m3u8") else { return }

        let player = AVPlayer(url: videoURL)
        player.isMuted = false
        player.volume = 0.0
        self.onboardingVideoPlayer = player
        self.showOnboardingVideo = true
        self.onboardingVideoOpacity = 0.0

        // Start playback immediately — the video plays while invisible,
        // then we fade in both the visual and audio over 1s.
        player.play()

        // Wait for SwiftUI to mount the view, then set opacity to 1.
        // The .animation modifier on the view handles the actual animation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.onboardingVideoOpacity = 1.0
            // Fade audio volume from 0 → 1 over 2s to match visual fade
            self.fadeInVideoAudio(player: player, targetVolume: 1.0, duration: 2.0)
        }

        // At 40 seconds into the video, trigger the onboarding demo where
        // ipop.ai flies to something interesting on screen and comments on it
        let demoTriggerTime = CMTime(seconds: 40, preferredTimescale: 600)
        onboardingDemoTimeObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: demoTriggerTime)],
            queue: .main
        ) { [weak self] in
            Task { @MainActor [weak self] in
                IpopAnalytics.trackOnboardingDemoTriggered()
                self?.performOnboardingDemoInteraction()
            }
        }

        // Fade out and clean up when the video finishes
        onboardingVideoEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                IpopAnalytics.trackOnboardingVideoCompleted()
                self.onboardingVideoOpacity = 0.0
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self.tearDownOnboardingVideo()
                try? await Task.sleep(nanoseconds: 300_000_000)
                self.startOnboardingPromptStream()
            }
        }
    }

    func tearDownOnboardingVideo() {
        onboardingPromptStreamTask?.cancel()
        onboardingPromptStreamTask = nil
        showOnboardingVideo = false
        if let timeObserver = onboardingDemoTimeObserver {
            onboardingVideoPlayer?.removeTimeObserver(timeObserver)
            onboardingDemoTimeObserver = nil
        }
        onboardingVideoPlayer?.pause()
        onboardingVideoPlayer = nil
        if let observer = onboardingVideoEndObserver {
            NotificationCenter.default.removeObserver(observer)
            onboardingVideoEndObserver = nil
        }
    }

    private func startOnboardingPromptStream() {
        let message = "press control + option and introduce yourself"
        onboardingPromptStreamTask?.cancel()
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.4)) {
            onboardingPromptOpacity = 1.0
        }

        onboardingPromptStreamTask = Task { @MainActor [weak self] in
            guard let self else { return }

            for character in message {
                guard !Task.isCancelled else { return }
                self.onboardingPromptText.append(character)
                try? await Task.sleep(nanoseconds: 30_000_000)
            }

            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled, self.showOnboardingPrompt else {
                return
            }

            withAnimation(.easeOut(duration: 0.3)) {
                self.onboardingPromptOpacity = 0.0
            }
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }

            self.showOnboardingPrompt = false
            self.onboardingPromptText = ""
            self.onboardingPromptStreamTask = nil
        }
    }

    /// Gradually raises an AVPlayer's volume from its current level to the
    /// target over the specified duration, creating a smooth audio fade-in.
    private func fadeInVideoAudio(player: AVPlayer, targetVolume: Float, duration: Double) {
        let steps = 20
        let stepInterval = duration / Double(steps)
        let volumeIncrement = (targetVolume - player.volume) / Float(steps)
        var stepsRemaining = steps

        Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { timer in
            stepsRemaining -= 1
            player.volume += volumeIncrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.volume = targetVolume
            }
        }
    }

    // MARK: - Onboarding Demo Interaction

    private static let onboardingDemoSystemPrompt = """
    you're ipop.ai, a small blue cursor buddy living on the user's screen. you're showing off during onboarding — look at their screen and find ONE specific, concrete thing to point at. pick something with a clear name or identity: a specific app icon (say its name), a specific word or phrase of text you can read, a specific filename, a specific button label, a specific tab title, a specific image you can describe. do NOT point at vague things like "a window" or "some text" — be specific about exactly what you see.

    make a short quirky 3-6 word observation about the specific thing you picked — something fun, playful, or curious that shows you actually read/recognized it. no emojis ever. NEVER quote or repeat text you see on screen — just react to it. keep it to 6 words max, no exceptions.

    CRITICAL COORDINATE RULE: you MUST only pick elements near the CENTER of the screen. your x coordinate must be between 20%-80% of the image width. your y coordinate must be between 20%-80% of the image height. do NOT pick anything in the top 20%, bottom 20%, left 20%, or right 20% of the screen. no menu bar items, no dock icons, no sidebar items, no items near any edge. only things clearly in the middle area of the screen. if the only interesting things are near the edges, pick something boring in the center instead.

    respond with ONLY your short comment followed by the coordinate tag. nothing else. all lowercase.

    format: your comment [POINT:x,y:label]

    the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. origin (0,0) is top-left. x increases rightward, y increases downward.
    """

    /// Captures a screenshot and asks Claude to find something interesting to
    /// point at, then triggers the buddy's flight animation. Used during
    /// onboarding to demo the pointing feature while the intro video plays.
    func performOnboardingDemoInteraction() {
        // Don't interrupt an active voice response
        guard voiceState == .idle || voiceState == .responding else { return }

        Task {
            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                // Only send the cursor screen so Claude can't pick something
                // on a different monitor that we can't point at.
                guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) else {
                    print("🎯 Onboarding demo: no cursor screen found")
                    return
                }

                let dimensionInfo = " (image dimensions: \(cursorScreenCapture.screenshotWidthInPixels)x\(cursorScreenCapture.screenshotHeightInPixels) pixels)"
                let labeledImages = [(data: cursorScreenCapture.imageData, label: cursorScreenCapture.label + dimensionInfo)]

                let (fullResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.onboardingDemoSystemPrompt,
                    conversationHistory: [],
                    userPrompt: "look around my screen and find something interesting to point at",
                    onTextChunk: { _ in }
                )

                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)

                guard let pointCoordinate = parseResult.coordinate else {
                    print("🎯 Onboarding demo: no element to point at")
                    return
                }

                let screenshotWidth = CGFloat(cursorScreenCapture.screenshotWidthInPixels)
                let screenshotHeight = CGFloat(cursorScreenCapture.screenshotHeightInPixels)
                let displayWidth = CGFloat(cursorScreenCapture.displayWidthInPoints)
                let displayHeight = CGFloat(cursorScreenCapture.displayHeightInPoints)
                let displayFrame = cursorScreenCapture.displayFrame

                let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))
                let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                let displayLocalY = clampedY * (displayHeight / screenshotHeight)
                let appKitY = displayHeight - displayLocalY
                let globalLocation = CGPoint(
                    x: displayLocalX + displayFrame.origin.x,
                    y: appKitY + displayFrame.origin.y
                )

                // Set custom bubble text so the pointing animation uses Claude's
                // comment instead of a random phrase
                detectedElementBubbleText = parseResult.spokenText
                detectedElementScreenLocation = globalLocation
                detectedElementDisplayFrame = displayFrame
                print("🎯 Onboarding demo: pointing at \"\(parseResult.elementLabel ?? "element")\" — \"\(parseResult.spokenText)\"")
            } catch {
                print("⚠️ Onboarding demo error: \(error)")
            }
        }
    }
}
