//
//  CompanionPanelView.swift
//  leanring-buddy
//
//  The SwiftUI content hosted inside the menu bar panel. Shows the companion
//  voice status, push-to-talk shortcut, and quick settings. Designed to feel
//  like Loom's recording panel — dark, rounded, minimal, and special.
//

import AVFoundation
import SwiftUI

struct CompanionPanelView: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader
            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            permissionsCopySection
                .padding(.top, 16)
                .padding(.horizontal, 16)

            if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 12)

                PresenceNowPanelView(
                    snapshot: companionManager.presenceSnapshot,
                    onRunMove: { move in
                        companionManager.runSuggestedPresenceMove(move)
                    }
                )
                .padding(.horizontal, 16)

                Spacer()
                    .frame(height: 12)

                modelPickerRow
                    .padding(.horizontal, 16)

                Spacer()
                    .frame(height: 12)

                learningControlsSection
                    .padding(.horizontal, 16)
            }

            if !companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 16)

                settingsSection
                    .padding(.horizontal, 16)
            }

            if !companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 16)

                startButton
                    .padding(.horizontal, 16)
            }

            // Show cursor toggle — hidden for now
            // if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            //     Spacer()
            //         .frame(height: 16)
            //
            //     showCursorToggleRow
            //         .padding(.horizontal, 16)
            // }

            if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 16)

                feedbackButton
                    .padding(.horizontal, 16)
            }

            Spacer()
                .frame(height: 12)

            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            footerSection
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .frame(width: 320)
        .background(panelBackground)
    }

    // MARK: - Header

    private var panelHeader: some View {
        HStack {
            HStack(spacing: 8) {
                // Animated status dot
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: statusDotColor.opacity(0.6), radius: 4)

                Text("ipop.ai")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
            }

            Spacer()

            Text(statusText)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)

            Button(action: {
                NotificationCenter.default.post(name: .ipopDismissPanel, object: nil)
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 20, height: 20)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Permissions Copy

    @ViewBuilder
    private var permissionsCopySection: some View {
        if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            Text("Hold Control+Option to talk.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.allPermissionsGranted {
            Text("You're all set. Hit Start to meet ipop.ai.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.hasCompletedOnboarding {
            // Permissions were revoked after onboarding — tell user to re-grant
            VStack(alignment: .leading, spacing: 6) {
                Text("Permissions needed")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)

                Text("Some permissions were revoked. Grant all permissions below to keep using ipop.ai.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("This is ipop.ai.")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)

                Text("A Mac voice agent that opens apps, uses approved screen context, and can launch background agent sessions.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("See Mode reads the current app/window and selected text when macOS exposes it. Screenshots only happen when you press the hot key or start an action.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Email + Start Button

    @ViewBuilder
    private var startButton: some View {
        if !companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            Button(action: {
                companionManager.triggerOnboarding()
            }) {
                Text("Start")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DS.Colors.textOnAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                            .fill(DS.Colors.accent)
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
    }

    // MARK: - Permissions

    private var settingsSection: some View {
        VStack(spacing: 2) {
            Text("PERMISSIONS")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 6)

            microphonePermissionRow

            accessibilityPermissionRow

            screenRecordingPermissionRow

            if companionManager.hasScreenRecordingPermission {
                screenContentPermissionRow
            }

        }
    }

    private var accessibilityPermissionRow: some View {
        let isGranted = companionManager.hasAccessibilityPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text("Accessibility")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                HStack(spacing: 6) {
                    Button(action: {
                        // Triggers the system accessibility prompt (AXIsProcessTrustedWithOptions)
                        // on first attempt, then opens System Settings on subsequent attempts.
                        WindowPositionManager.requestAccessibilityPermission()
                    }) {
                        Text("Grant")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textOnAccent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(DS.Colors.accent)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()

                    Button(action: {
                        // Reveals the app in Finder so the user can drag it into
                        // the Accessibility list if it doesn't appear automatically
                        // (common with unsigned dev builds).
                        WindowPositionManager.revealAppInFinder()
                        WindowPositionManager.openAccessibilitySettings()
                    }) {
                        Text("Find App")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var screenRecordingPermissionRow: some View {
        let isGranted = companionManager.hasScreenRecordingPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.dashed.badge.record")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Screen Recording")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)

                    Text(isGranted
                         ? "Only takes a screenshot when you use the hotkey"
                         : "Quit and reopen after granting")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    // Triggers the native macOS screen recording prompt on first
                    // attempt (auto-adds app to the list), then opens System Settings
                    // on subsequent attempts.
                    WindowPositionManager.requestScreenRecordingPermission()
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }

    private var screenContentPermissionRow: some View {
        let isGranted = companionManager.hasScreenContentPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "eye")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text("Screen Content")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    companionManager.requestScreenContentPermission()
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }

    private var microphonePermissionRow: some View {
        let isGranted = companionManager.hasMicrophonePermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "mic")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text("Microphone")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    // Triggers the native macOS microphone permission dialog on
                    // first attempt. If already denied, opens System Settings.
                    let status = AVCaptureDevice.authorizationStatus(for: .audio)
                    if status == .notDetermined {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in }
                    } else {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }

    private func permissionRow(
        label: String,
        iconName: String,
        isGranted: Bool,
        settingsURL: String
    ) -> some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    if let url = URL(string: settingsURL) {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }



    // MARK: - Show Cursor Toggle

    private var showCursorToggleRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "cursorarrow")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)

                Text("Show cursor")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { companionManager.isIpopCursorEnabled },
                set: { companionManager.setIpopCursorEnabled($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(DS.Colors.accent)
            .scaleEffect(0.8)
        }
        .padding(.vertical, 4)
    }

    private var speechToTextProviderRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "mic.badge.waveform")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)

                Text("Speech to Text")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            Text(companionManager.buddyDictationManager.transcriptionProviderDisplayName)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Model Picker

    private var modelPickerRow: some View {
        VStack(spacing: 4) {
            HStack {
                Text("Model")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)

                Spacer()

                HStack(spacing: 0) {
                    modelOptionButton(label: "Fast", modelID: "claude-haiku-4-5-20251001")
                    modelOptionButton(label: "Sonnet", modelID: "claude-sonnet-4-6")
                    modelOptionButton(label: "Opus", modelID: "claude-opus-4-6")
                }
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                )
            }

            HStack {
                Text("Runtime")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                Spacer()
                Text(companionManager.activeRuntimeSummary)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
        }
        .padding(.vertical, 4)
    }

    private func modelOptionButton(label: String, modelID: String) -> some View {
        let isSelected = companionManager.selectedModel == modelID
        return Button(action: {
            companionManager.setSelectedModel(modelID)
        }) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isSelected ? Color.white.opacity(0.1) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - Learning + Agent Controls

    private var learningControlsSection: some View {
        VStack(spacing: 8) {
            controlToggleRow(
                iconName: "eye.fill",
                title: "See Mode",
                subtitle: companionManager.presenceSnapshot.context.appDisplayName,
                isOn: $companionManager.seeModeEnabled
            )

            controlToggleRow(
                iconName: "graduationcap.fill",
                title: "Teacher Mode",
                subtitle: "Visual lessons for teach, explain, confusion",
                isOn: Binding(
                    get: { companionManager.teacherModeController.isEnabled },
                    set: { companionManager.teacherModeController.setEnabled($0) }
                )
            )

            controlToggleRow(
                iconName: "cursorarrow.motionlines",
                title: "Agent Mode",
                subtitle: "Broad Mac control, with confirmations",
                isOn: $companionManager.agentModeEnabled
            )

            if companionManager.agentModeEnabled {
                controlToggleRow(
                    iconName: "keyboard.fill",
                    title: "Cua Driver",
                    subtitle: CuaDriverBackend.statusSubtitle(isEnabled: companionManager.cuaDriverEnabled),
                    isOn: $companionManager.cuaDriverEnabled
                )

                controlToggleRow(
                    iconName: "bolt.fill",
                    title: "Yolo",
                    subtitle: "Skip low-risk prompts only",
                    isOn: $companionManager.yoloModeEnabled
                )
            }

            if let pendingConfirmation = companionManager.computerUseAgent.pendingConfirmation {
                AgentConfirmationPanelView(
                    humanReadableSummary: pendingConfirmation.humanReadableSummary,
                    onApprove: {
                        companionManager.computerUseAgent.resolvePendingConfirmation(
                            id: pendingConfirmation.id,
                            approved: true
                        )
                    },
                    onEdit: { editedInstruction in
                        companionManager.computerUseAgent.resolvePendingConfirmation(
                            id: pendingConfirmation.id,
                            editInstruction: editedInstruction
                        )
                    },
                    onDeny: {
                        companionManager.computerUseAgent.resolvePendingConfirmation(
                            id: pendingConfirmation.id,
                            approved: false
                        )
                    }
                )
            }

            if companionManager.agentModeEnabled || companionManager.superAppDashboardSnapshot.status != .idle {
                SuperAppDashboardPanelView(snapshot: companionManager.superAppDashboardSnapshot)
            }
        }
    }

    private func controlToggleRow(
        iconName: String,
        title: String,
        subtitle: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Spacer()

            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(DS.Colors.accent)
                .scaleEffect(0.78)
        }
        .padding(.vertical, 5)
    }

    // MARK: - Feedback Button

    private var feedbackButton: some View {
        Button(action: {
            if let url = URL(string: "https://github.com/gagan114662/ipop-ai/issues/new") {
                NSWorkspace.shared.open(url)
            }
        }) {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.fill")
                    .font(.system(size: 12, weight: .medium))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Send feedback")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Bugs, ideas, anything you want improved.")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }
            .foregroundColor(DS.Colors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Button(action: {
                NSApp.terminate(nil)
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "power")
                        .font(.system(size: 11, weight: .medium))
                    Text("Quit ipop.ai")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .pointerCursor()

            if companionManager.hasCompletedOnboarding {
                Spacer()

                Button(action: {
                    companionManager.replayOnboarding()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "play.circle")
                            .font(.system(size: 11, weight: .medium))
                        Text("Watch Onboarding Again")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
    }

    // MARK: - Visual Helpers

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(DS.Colors.background)
            .shadow(color: Color.black.opacity(0.5), radius: 20, x: 0, y: 10)
            .shadow(color: Color.black.opacity(0.3), radius: 4, x: 0, y: 2)
    }

    private var statusDotColor: Color {
        if !companionManager.isOverlayVisible {
            return DS.Colors.textTertiary
        }
        switch companionManager.voiceState {
        case .idle:
            return DS.Colors.success
        case .listening:
            return DS.Colors.blue400
        case .processing, .responding:
            return DS.Colors.blue400
        }
    }

    private var statusText: String {
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            return "Setup"
        }
        if !companionManager.isOverlayVisible {
            return "Ready"
        }
        switch companionManager.voiceState {
        case .idle:
            return "Active"
        case .listening:
            return "Listening"
        case .processing:
            return "Processing"
        case .responding:
            return "Responding"
        }
    }

}

private struct PresenceNowPanelView: View {
    let snapshot: IPOPPresenceSnapshot
    let onRunMove: (IPOPProactiveMove) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: iconName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(modeColor)
                    .frame(width: 16, height: 16)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(snapshot.mode.displayName)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(modeColor)
                        Text(snapshot.context.appDisplayName)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(DS.Colors.textTertiary)
                            .lineLimit(1)
                    }

                    Text(snapshot.line)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !snapshot.suggestedMoves.isEmpty {
                HStack(spacing: 6) {
                    ForEach(snapshot.suggestedMoves.prefix(2)) { move in
                        Button(action: { onRunMove(move) }) {
                            HStack(spacing: 5) {
                                Image(systemName: iconName(for: move.mode))
                                    .font(.system(size: 10, weight: .semibold))
                                Text(move.title)
                                    .font(.system(size: 10, weight: .semibold))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.82)
                            }
                            .foregroundColor(DS.Colors.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color.white.opacity(0.07))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                            )
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(Color.white.opacity(0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .stroke(modeColor.opacity(0.28), lineWidth: 0.8)
        )
    }

    private var iconName: String {
        iconName(for: snapshot.mode)
    }

    private func iconName(for mode: IPOPPresenceMode) -> String {
        switch mode {
        case .see: return "eye.fill"
        case .do: return "cursorarrow.motionlines"
        case .magic: return "sparkles"
        }
    }

    private var modeColor: Color {
        switch snapshot.mode {
        case .see: return DS.Colors.info
        case .do: return DS.Colors.accentText
        case .magic: return DS.Colors.floatingGradientPink
        }
    }
}

private struct SuperAppDashboardPanelView: View {
    let snapshot: SuperAppDashboardSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: missionIconName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(statusColor)
                    .frame(width: 16)

                Text("Outcome Engine")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)

                Spacer()

                Text(snapshot.missionKind.displayName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)

                Text(snapshot.status.displayName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(statusColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule(style: .continuous)
                            .fill(statusColor.opacity(0.12))
                    )
            }

            Text(snapshot.objective)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Text(snapshot.impactPromise)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            dashboardStatusGrid

            if !snapshot.outcomeMetrics.isEmpty {
                outcomeMetricsView
            }

            if !snapshot.stepTitles.isEmpty {
                missionProgressView
            }

            VStack(alignment: .leading, spacing: 6) {
                if let currentApp = snapshot.currentApp {
                    dashboardRow(
                        iconName: "app.connected.to.app.below.fill",
                        title: "App",
                        value: currentApp.displayName
                    )
                }
                if let step = snapshot.currentStepTitle {
                    dashboardRow(
                        iconName: "scope",
                        title: "Step",
                        value: step
                    )
                }
                if let nextAction = snapshot.nextAction {
                    dashboardRow(
                        iconName: "arrow.forward.circle.fill",
                        title: "Next",
                        value: nextAction
                    )
                }
                if let blockedReason = snapshot.blockedReason {
                    dashboardRow(
                        iconName: "hand.raised.fill",
                        title: "Needs",
                        value: blockedReason,
                        color: DS.Colors.warning
                    )
                } else if let verificationSummary = snapshot.verificationSummary {
                    dashboardRow(
                        iconName: "checkmark.seal.fill",
                        title: "Proof",
                        value: verificationSummary,
                        color: DS.Colors.success
                    )
                }
                if let guardrailLine = snapshot.guardrailLine {
                    dashboardRow(
                        iconName: "lock.shield.fill",
                        title: "Safe",
                        value: guardrailLine,
                        color: DS.Colors.warning
                    )
                }
            }

            if !snapshot.proofLog.isEmpty {
                proofLogView
            }

            if !snapshot.approvalChips.isEmpty {
                approvalChipsView
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(Color.white.opacity(0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
        )
    }

    private var dashboardStatusGrid: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 6),
                GridItem(.flexible(), spacing: 6)
            ],
            alignment: .leading,
            spacing: 6
        ) {
            dashboardStatusTile(
                iconName: "scope",
                title: "Doing",
                value: snapshot.currentStepTitle ?? snapshot.status.displayName,
                color: statusColor
            )
            dashboardStatusTile(
                iconName: "magnifyingglass",
                title: "Found",
                value: snapshot.verificationSummary ?? snapshot.proofLine ?? "Gathering proof",
                color: DS.Colors.info
            )
            dashboardStatusTile(
                iconName: snapshot.blockedReason == nil ? "checkmark.seal.fill" : "hand.raised.fill",
                title: "Blocked",
                value: snapshot.blockedReason ?? "Clear",
                color: snapshot.blockedReason == nil ? DS.Colors.success : DS.Colors.warning
            )
            dashboardStatusTile(
                iconName: "chart.line.uptrend.xyaxis",
                title: "Outcome",
                value: snapshot.outcomeMetrics.first(where: { $0.isPrimary })?.value ?? snapshot.impactPromise,
                color: DS.Colors.accentText
            )
        }
    }

    private func dashboardStatusTile(
        iconName: String,
        title: String,
        value: String,
        color: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: iconName)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(color)
                .frame(width: 11, height: 11)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(1)
                Text(value)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.78)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.045))
        )
    }

    private var missionProgressView: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geometry in
                let total = max(snapshot.stepTitles.count, 1)
                let fraction = min(max(CGFloat(snapshot.completedStepCount) / CGFloat(total), 0), 1)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(statusColor.opacity(0.72))
                        .frame(width: max(6, geometry.size.width * fraction))
                }
            }
            .frame(height: 5)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(snapshot.stepTitles.prefix(4).enumerated()), id: \.offset) { index, title in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: stepIconName(for: index))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(stepColor(for: index))
                            .frame(width: 12, height: 12)
                            .padding(.top, 1)

                        Text(title)
                            .font(.system(size: 10))
                            .foregroundColor(index <= snapshot.completedStepCount ? DS.Colors.textSecondary : DS.Colors.textTertiary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                    }
                }
            }
        }
    }

    private var outcomeMetricsView: some View {
        HStack(spacing: 6) {
            ForEach(snapshot.outcomeMetrics.prefix(3)) { metric in
                VStack(alignment: .leading, spacing: 2) {
                    Text(metric.label)
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(1)
                    Text(metric.value)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(metric.isPrimary ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(metric.isPrimary ? 0.075 : 0.045))
                )
            }
        }
    }

    private func dashboardRow(
        iconName: String,
        title: String,
        value: String,
        color: Color = DS.Colors.textTertiary
    ) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: iconName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(color)
                .frame(width: 13, height: 13)
                .padding(.top, 1)

            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(width: 34, alignment: .leading)

            Text(value)
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var proofLogView: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Proof log")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)

            ForEach(snapshot.proofLog.prefix(4)) { entry in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: proofIconName(for: entry.status))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(proofColor(for: entry.status))
                        .frame(width: 12, height: 12)
                        .padding(.top, 1)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.title)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(DS.Colors.textSecondary)
                            .lineLimit(1)
                        Text(entry.detail)
                            .font(.system(size: 9.5))
                            .foregroundColor(DS.Colors.textTertiary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var approvalChipsView: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Approval gates")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)

            ForEach(snapshot.approvalChips.prefix(3)) { chip in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: approvalIconName(for: chip))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(approvalColor(for: chip))
                        .frame(width: 12, height: 12)
                        .padding(.top, 1)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(chip.title)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(DS.Colors.textSecondary)
                            .lineLimit(1)
                        Text(chip.detail)
                            .font(.system(size: 9.5))
                            .foregroundColor(DS.Colors.textTertiary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func proofIconName(for status: SuperAppProofLogStatus) -> String {
        switch status {
        case .planned:
            return "circle"
        case .captured:
            return "checkmark.circle.fill"
        case .blocked:
            return "exclamationmark.circle.fill"
        }
    }

    private func proofColor(for status: SuperAppProofLogStatus) -> Color {
        switch status {
        case .planned:
            return DS.Colors.textTertiary
        case .captured:
            return DS.Colors.success
        case .blocked:
            return DS.Colors.warning
        }
    }

    private func approvalIconName(for chip: SuperAppApprovalChip) -> String {
        if chip.riskLevel == .blocked {
            return "xmark.octagon.fill"
        }
        return chip.isBlocking ? "hand.raised.fill" : "lock.fill"
    }

    private func approvalColor(for chip: SuperAppApprovalChip) -> Color {
        switch chip.riskLevel {
        case .blocked:
            return DS.Colors.destructiveText
        case .confirmationRequired:
            return DS.Colors.warning
        case .medium:
            return DS.Colors.accentText
        case .low:
            return DS.Colors.textTertiary
        }
    }

    private func stepIconName(for index: Int) -> String {
        if index < snapshot.completedStepCount {
            return "checkmark.circle.fill"
        }
        if index == snapshot.completedStepCount && snapshot.status != .idle {
            return "circle.lefthalf.filled"
        }
        return "circle"
    }

    private func stepColor(for index: Int) -> Color {
        if index < snapshot.completedStepCount {
            return DS.Colors.success
        }
        if index == snapshot.completedStepCount && snapshot.status != .idle {
            return statusColor
        }
        return DS.Colors.textTertiary
    }

    private var missionIconName: String {
        switch snapshot.missionKind {
        case .learn:
            return "graduationcap.fill"
        case .earn:
            return "briefcase.fill"
        case .build:
            return "hammer.fill"
        case .operate:
            return "cursorarrow.motionlines"
        case .automate:
            return "clock.arrow.circlepath"
        case .research:
            return "magnifyingglass"
        case .communicate:
            return "bubble.left.and.bubble.right.fill"
        case .organize:
            return "square.grid.2x2.fill"
        case .general:
            return "sparkles"
        }
    }

    private var statusColor: Color {
        switch snapshot.status {
        case .idle:
            return DS.Colors.textTertiary
        case .planning, .executing, .verifying:
            return DS.Colors.accentText
        case .needsConfirmation:
            return DS.Colors.warning
        case .blocked, .failed:
            return DS.Colors.destructiveText
        case .done:
            return DS.Colors.success
        }
    }
}
