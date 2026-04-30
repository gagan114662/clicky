//
//  AgentSiblingsOverlayWindow.swift
//  leanring-buddy
//
//  Floating panel that shows "mini clicky siblings" — one icon per running
//  or recently completed Codex agent. Inspired by the sibling icons seen in
//  the original Clicky app: dark rounded squares with a colored triangle and
//  a small status dot (blue = running, green = done, red = failed).
//
//  The window lives on top of all other windows (level .floating), never
//  steals focus, and joins all Spaces so it persists across virtual desktops.
//  It auto-hides when there are no sessions and reappears when new agents launch.
//

import AppKit
import SwiftUI

// MARK: - Siblings window

final class AgentSiblingsOverlayWindow: NSPanel {
    private var hostingController: NSHostingController<AgentSiblingsContainerView>?

    init(
        sessionManager: AgentSessionManager,
        onSelectSession: @escaping (UUID) -> Void,
        onSessionsEmpty: @escaping () -> Void
    ) {
        // Start with a compact frame — SwiftUI content drives the actual size.
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 90, height: 90),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        level = .floating
        isReleasedWhenClosed = false
        hasShadow = false
        hidesOnDeactivate = false
        ignoresMouseEvents = false  // siblings are interactive (click to dismiss)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let rootView = AgentSiblingsContainerView(
            sessionManager: sessionManager,
            onSelectSession: onSelectSession,
            onSessionsEmpty: onSessionsEmpty
        )
        let hc = NSHostingController(rootView: rootView)
        hostingController = hc
        contentView = hc.view
        contentView?.wantsLayer = true
        contentView?.layer?.backgroundColor = NSColor.clear.cgColor

        // Position: right side of primary screen, vertically centered.
        positionOnScreen()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private func positionOnScreen() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        // Anchor to the right edge with 16pt inset, vertically centered.
        let windowX = screenFrame.maxX - 90 - 16
        let windowY = screenFrame.midY - 200
        setFrameOrigin(NSPoint(x: windowX, y: windowY))
    }
}

// MARK: - Manager that owns the window

@MainActor
final class AgentSiblingsWindowManager {
    private var window: AgentSiblingsOverlayWindow?

    /// Shows the siblings overlay. `onSelectSession` is called with the
    /// session id and the overlay window's screen frame whenever the user
    /// taps a sibling icon — CompanionManager uses this to position the
    /// click-to-inspect detail panel next to the column of icons.
    func show(
        sessionManager: AgentSessionManager,
        onSelectSession: @escaping (UUID, NSRect) -> Void
    ) {
        if window == nil {
            // Wrap the (UUID) callback so it includes the live overlay frame
            // at click time, used by the detail window for anchoring.
            let wrappedSelect: (UUID) -> Void = { [weak self] sessionID in
                guard let frame = self?.window?.frame else {
                    onSelectSession(sessionID, .zero)
                    return
                }
                onSelectSession(sessionID, frame)
            }
            window = AgentSiblingsOverlayWindow(
                sessionManager: sessionManager,
                onSelectSession: wrappedSelect,
                onSessionsEmpty: { [weak self] in self?.hide() }
            )
            print("🪟 Created AgentSiblingsOverlayWindow")
        }
        window?.orderFront(nil)
        if let frame = window?.frame {
            print("🪟 Sibling overlay shown at frame: \(frame), visible: \(window?.isVisible ?? false), screen: \(window?.screen?.localizedName ?? "nil")")
        }
    }

    func hide() {
        window?.orderOut(nil)
    }
}

// MARK: - Container SwiftUI view

struct AgentSiblingsContainerView: View {
    @ObservedObject var sessionManager: AgentSessionManager
    let onSelectSession: (UUID) -> Void
    let onSessionsEmpty: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            ForEach(sessionManager.sessions) { session in
                AgentSiblingIconView(
                    session: session,
                    onSelect: { onSelectSession(session.id) },
                    onDismiss: { sessionManager.removeSession(id: session.id) }
                )
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.6).combined(with: .opacity),
                    removal: .scale(scale: 0.6).combined(with: .opacity)
                ))
            }
        }
        .padding(8)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: sessionManager.sessions.map { $0.id })
        .onAppear {
            if sessionManager.sessions.isEmpty {
                onSessionsEmpty()
            }
        }
        .onChange(of: sessionManager.sessions.count) { _, count in
            if count == 0 {
                onSessionsEmpty()
            }
        }
    }
}

// MARK: - Single sibling icon

struct AgentSiblingIconView: View {
    let session: AgentSession
    let onSelect: () -> Void
    let onDismiss: () -> Void

    @State private var isHovered = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Dark rounded square background
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(hex: "#1C1F1E"))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.5), radius: 8, x: 0, y: 4)
                .frame(width: 64, height: 64)

            // Colored triangle
            Triangle()
                .fill(session.triangleColor)
                .shadow(color: session.triangleColor.opacity(0.5), radius: 6)
                .frame(width: 30, height: 30)
                .frame(width: 64, height: 64) // center within icon

            // Status dot — top-right corner
            statusDot
                .offset(x: 4, y: -4)

            // Running shimmer ring
            if session.status == .running {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(session.triangleColor.opacity(0.3), lineWidth: 1.5)
                    .frame(width: 64, height: 64)
                    .scaleEffect(isHovered ? 1.05 : 1.0)
            }
        }
        .frame(width: 72, height: 72)
        .overlay(alignment: .leading) {
            // Task label — shown on hover to the left of the icon
            if isHovered {
                taskLabel
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .offset(x: -8, y: 0)
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
        }
        .onTapGesture {
            // Single click — open the detail panel for ANY session (running,
            // completed, or failed). Long-press on completed sessions removes
            // them early; otherwise they auto-fade after the linger window.
            onSelect()
        }
        .onLongPressGesture(minimumDuration: 0.6) {
            // Long-press dismisses ANY session (running, done, or failed).
            // For running sessions this also interrupts the codex turn so
            // the agent stops doing work in the background.
            onDismiss()
        }
        .help(session.taskDescription)
    }

    @ViewBuilder
    private var statusDot: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 10, height: 10)
            .overlay(Circle().stroke(Color(hex: "#1C1F1E"), lineWidth: 1.5))
            .shadow(color: dotColor.opacity(0.8), radius: 3)
    }

    private var dotColor: Color {
        switch session.status {
        case .running:   return Color(hex: "#3B82F6") // blue
        case .completed: return Color(hex: "#22C55E") // green
        case .failed:    return Color(hex: "#EF4444") // red
        }
    }

    private var taskLabel: some View {
        HStack(spacing: 6) {
            Text(session.taskDescription.prefix(40) + (session.taskDescription.count > 40 ? "..." : ""))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color(hex: "#ECEEED"))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(hex: "#1C1F1E"))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.4), radius: 6, x: 0, y: 3)
        )
        .frame(maxWidth: 180, alignment: .trailing)
        .offset(x: -76) // position to the left of the icon
    }
}
