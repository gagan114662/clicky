//
//  AgentSessionDetailWindow.swift
//  leanring-buddy
//
//  Click-to-inspect floating panel that opens when the user taps a sibling
//  icon. Shows the full task description, status badge ("Running" / "Done" /
//  "Failed"), elapsed time, and the live streaming output that Codex emits
//  as the agent runs. The panel re-renders automatically whenever the
//  session it's bound to publishes a state change.
//

import AppKit
import SwiftUI

// MARK: - Window manager

@MainActor
final class AgentSessionDetailWindowManager {
    private var window: AgentSessionDetailWindow?
    private var dismissOutsideClickMonitor: Any?
    private var displayedSessionID: UUID?
    /// Closure injected by CompanionManager to send a follow-up prompt to a
    /// specific session via the codex resume flow.
    var onSendFollowUp: ((UUID, String) -> Void)?

    /// Shows (or moves) the detail panel anchored to the given icon frame.
    /// `iconScreenFrame` is the icon's frame in screen coordinates; the panel
    /// is placed to its left with a small gap so it doesn't cover the icon.
    func show(
        sessionID: UUID,
        sessionManager: AgentSessionManager,
        anchoredTo iconScreenFrame: NSRect
    ) {
        if window == nil {
            window = AgentSessionDetailWindow(
                sessionID: sessionID,
                sessionManager: sessionManager,
                onClose: { [weak self] in self?.hide() },
                onSendFollowUp: { [weak self] sid, prompt in
                    self?.onSendFollowUp?(sid, prompt)
                }
            )
        } else {
            window?.update(
                sessionID: sessionID,
                sessionManager: sessionManager,
                onClose: { [weak self] in self?.hide() }
            )
        }
        displayedSessionID = sessionID

        guard let panel = window else { return }

        let panelWidth: CGFloat = 360
        let panelHeight: CGFloat = 320
        // Anchor to the LEFT of the icon with a small gap, vertically aligned
        // to the icon's vertical midpoint.
        let gap: CGFloat = 12
        let panelX = iconScreenFrame.minX - panelWidth - gap
        let panelY = iconScreenFrame.midY - panelHeight / 2
        panel.setFrame(NSRect(x: panelX, y: panelY, width: panelWidth, height: panelHeight), display: true)
        panel.orderFront(nil)

        installOutsideClickMonitor()
    }

    func hide() {
        window?.orderOut(nil)
        displayedSessionID = nil
        if let monitor = dismissOutsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            dismissOutsideClickMonitor = nil
        }
    }

    private func installOutsideClickMonitor() {
        if dismissOutsideClickMonitor != nil { return }
        dismissOutsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            // Any click outside the panel hides it. The panel itself swallows
            // clicks before they reach the global monitor.
            DispatchQueue.main.async { self?.hide() }
        }
    }

    var isShowing: Bool { window?.isVisible ?? false }
    var currentSessionID: UUID? { displayedSessionID }
}

// MARK: - The NSPanel

final class AgentSessionDetailWindow: NSPanel {
    private var hostingController: NSHostingController<AgentSessionDetailHostView>?
    private var onClose: () -> Void
    private var onSendFollowUp: (UUID, String) -> Void

    init(
        sessionID: UUID,
        sessionManager: AgentSessionManager,
        onClose: @escaping () -> Void,
        onSendFollowUp: @escaping (UUID, String) -> Void
    ) {
        self.onClose = onClose
        self.onSendFollowUp = onSendFollowUp
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 320),
            styleMask: [.borderless, .nonactivatingPanel, .titled],
            backing: .buffered,
            defer: false
        )
        // Need .titled in styleMask so TextField inside accepts text input,
        // but we hide the title bar for the borderless look.
        styleMask.remove(.titled)
        styleMask.insert(.borderless)

        isOpaque = false
        backgroundColor = .clear
        level = .floating
        isReleasedWhenClosed = false
        hasShadow = true
        hidesOnDeactivate = false
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let rootView = AgentSessionDetailHostView(
            sessionID: sessionID,
            sessionManager: sessionManager,
            onClose: onClose,
            onCloseSession: { [weak self, weak sessionManager] sid in
                sessionManager?.removeSession(id: sid)
                self?.onClose()
            },
            onSendFollowUp: onSendFollowUp
        )
        let hc = NSHostingController(rootView: rootView)
        hostingController = hc
        contentView = hc.view
        contentView?.wantsLayer = true
        contentView?.layer?.backgroundColor = NSColor.clear.cgColor
    }

    /// Allow this panel to become key so its TextField can take keyboard
    /// focus for follow-up text input. Without this, typing into the field
    /// silently does nothing because focus stays on the previous app.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func update(sessionID: UUID, sessionManager: AgentSessionManager, onClose: @escaping () -> Void) {
        self.onClose = onClose
        let newRoot = AgentSessionDetailHostView(
            sessionID: sessionID,
            sessionManager: sessionManager,
            onClose: onClose,
            onCloseSession: { [weak self, weak sessionManager] sid in
                sessionManager?.removeSession(id: sid)
                self?.onClose()
            },
            onSendFollowUp: onSendFollowUp
        )
        hostingController?.rootView = newRoot
    }
}

// MARK: - SwiftUI host view (looks up the session each render so updates flow)

struct AgentSessionDetailHostView: View {
    let sessionID: UUID
    @ObservedObject var sessionManager: AgentSessionManager
    let onClose: () -> Void
    let onCloseSession: (UUID) -> Void
    let onSendFollowUp: (UUID, String) -> Void

    var body: some View {
        if let session = sessionManager.sessions.first(where: { $0.id == sessionID }) {
            AgentSessionDetailView(
                session: session,
                onClose: onClose,
                onCloseSession: { onCloseSession(session.id) },
                onSendFollowUp: { prompt in onSendFollowUp(session.id, prompt) }
            )
        } else {
            // Session was already removed (cleanup linger expired). Fade away.
            EmptyView()
                .onAppear { onClose() }
        }
    }
}

// MARK: - The actual detail card

struct AgentSessionDetailView: View {
    let session: AgentSession
    let onClose: () -> Void
    let onCloseSession: () -> Void
    let onSendFollowUp: (String) -> Void

    @State private var followUpDraft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            outputArea
            followUpComposer
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(hex: "#1C1F1E"))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.6), radius: 16, x: 0, y: 6)
        )
        .frame(width: 360, height: 320)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.taskDescription.uppercased())
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(hex: "#ECEEED"))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(elapsedTimeLabel)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundColor(Color(hex: "#888B8A"))
            }

            Spacer(minLength: 8)

            statusBadge

            Button(action: onCloseSession) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Color(hex: "#888B8A"))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.white.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .help(session.status == .running ? "Stop and close session" : "Close session")
        }
    }

    private var statusBadge: some View {
        let (label, color): (String, Color) = {
            switch session.status {
            case .running:   return ("Running", Color(hex: "#22C55E"))
            case .completed: return ("Done", Color(hex: "#3B82F6"))
            case .failed:    return ("Failed", Color(hex: "#EF4444"))
            }
        }()
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(color.opacity(0.15))
                .overlay(Capsule().stroke(color.opacity(0.4), lineWidth: 0.5))
        )
    }

    private var outputAreaContent: some View {
        let displayText = session.liveOutput.isEmpty ? placeholderText : session.liveOutput
        return Text(displayText)
            .font(.system(size: 11, weight: .regular, design: .monospaced))
            .foregroundColor(Color(hex: "#C4C7C6"))
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .id("output")
    }

    private var outputArea: some View {
        ScrollView {
            ScrollViewReader { proxy in
                outputAreaContent
                    .onChange(of: session.liveOutput) { _ in
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo("output", anchor: .bottom)
                        }
                    }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(hex: "#0F1110"))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
        )
    }

    private var followUpComposer: some View {
        let canSend = !followUpDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && session.status != .running
            && session.codexThreadID != nil

        return HStack(spacing: 8) {
            TextField("Follow up…", text: $followUpDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(Color(hex: "#ECEEED"))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(hex: "#0F1110"))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                )
                .onSubmit { sendIfPossible() }

            Button(action: sendIfPossible) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(canSend ? Color.white : Color.white.opacity(0.35))
                    .frame(width: 28, height: 28)
                    .background(
                        Circle().fill(canSend ? Color(hex: "#3B82F6") : Color.white.opacity(0.06))
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
    }

    private func sendIfPossible() {
        let trimmed = followUpDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              session.status != .running,
              session.codexThreadID != nil else { return }
        onSendFollowUp(trimmed)
        followUpDraft = ""
    }

    private var elapsedTimeLabel: String {
        let elapsed = Int(Date().timeIntervalSince(session.startedAt))
        if elapsed < 60 { return "\(elapsed)s elapsed" }
        let minutes = elapsed / 60
        let seconds = elapsed % 60
        return "\(minutes)m \(seconds)s elapsed"
    }

    private var placeholderText: String {
        switch session.status {
        case .running:   return "Waiting for first output…"
        case .completed: return session.result ?? "(no output)"
        case .failed:    return session.result ?? "(failed with no output)"
        }
    }
}
