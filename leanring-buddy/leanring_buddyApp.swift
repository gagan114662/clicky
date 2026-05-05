//
//  leanring_buddyApp.swift
//  leanring-buddy
//
//  Menu bar-only companion app. No dock icon, no main window — just an
//  always-available status item in the macOS menu bar. Clicking the icon
//  opens a floating panel with companion voice controls.
//

import AppKit
import ServiceManagement
import SwiftUI
import Sparkle

@main
struct leanring_buddyApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) var appDelegate

    var body: some Scene {
        // The app lives entirely in the menu bar panel managed by the AppDelegate.
        // This empty Settings scene satisfies SwiftUI's requirement for at least
        // one scene but is never shown (LSUIElement=true removes the app menu).
        Settings {
            EmptyView()
        }
    }
}

/// Manages the companion lifecycle: creates the menu bar panel and starts
/// the companion voice pipeline on launch.
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarPanelManager: MenuBarPanelManager?
    private let companionManager = CompanionManager()
    private var sparkleUpdaterController: SPUStandardUpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🎯 ipop.ai: Starting...")
        print("🎯 ipop.ai: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        guard !isRunningAsUnitTestHost else {
            print("🎯 ipop.ai: XCTest host detected; skipping live companion startup")
            return
        }

        // Enforce single-instance. Because ipop.ai is a menu bar app
        // (LSUIElement=true, no dock icon) AND registers itself as a login item
        // via SMAppService, it's very easy to end up with two copies running
        // at once: one auto-launched at login, plus a second one launched by
        // `Cmd+R` in Xcode. Both instances would install their own global
        // ctrl+option CGEvent tap, both would transcribe, both would call
        // Claude, and both would spawn `/usr/bin/say`. The user hears two
        // voices overlapping because there are literally two apps speaking.
        //
        // On launch, terminate any other running copies of ipop.ai so the
        // instance that just started (typically the one freshly built by
        // Xcode) is the only one handling push-to-talk and TTS.
        terminateOtherRunningInstances()

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

        IpopAnalytics.configure()
        IpopAnalytics.trackAppOpened()

        menuBarPanelManager = MenuBarPanelManager(companionManager: companionManager)
        companionManager.start()
        // Auto-open the panel if the user still needs to do something:
        // either they haven't onboarded yet, or permissions were revoked.
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            menuBarPanelManager?.showPanelOnLaunch()
        }
        registerAsLoginItemIfNeeded()
        // startSparkleUpdater()
    }

    func applicationWillTerminate(_ notification: Notification) {
        companionManager.stop()
    }

    /// Kills any other copies of ipop.ai that are already running so this
    /// newly-launched process is the sole instance. Called at launch to
    /// prevent duplicated push-to-talk + TTS pipelines when the login-item
    /// copy and an Xcode-launched copy are running at the same time.
    ///
    /// We pick "terminate others, keep self" (instead of "quit self") so
    /// that when a developer hits Cmd+R in Xcode, the fresh build takes
    /// over instead of being silently ignored in favor of the stale login
    /// item copy.
    /// All known bundle identifiers — catches previous beta/dev builds so they
    /// cannot run alongside the production app.
    private static let allKnownBundleIdentifiers = [
        "ai.ipop.mac",
        "com.yourcompany.leanring-buddy",
        "com.humansongs.clicky",
    ]

    private func terminateOtherRunningInstances() {
        let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier

        let otherInstances = Self.allKnownBundleIdentifiers
            .flatMap { bundleID in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) }
            .filter { runningApplication in
                runningApplication.processIdentifier != ownProcessIdentifier
            }

        guard !otherInstances.isEmpty else { return }

        print("🎯 ipop.ai: found \(otherInstances.count) other running instance(s), terminating them")
        for otherInstance in otherInstances {
            // Ask nicely first so the other instance can clean up its CGEvent
            // tap, audio engine, etc. via applicationWillTerminate. If it
            // doesn't exit within a short grace period, force-kill it so it
            // can't keep stealing our push-to-talk keypresses.
            let didTerminateGracefully = otherInstance.terminate()
            if !didTerminateGracefully {
                otherInstance.forceTerminate()
            }
        }

        // Give the other instances a moment to actually exit and release
        // their global CGEvent tap before we install ours. Without this
        // brief wait, both event taps can coexist for a few hundred ms
        // and the first push-to-talk after launch still double-fires.
        let maxWaitUntilOthersExit = Date().addingTimeInterval(1.5)
        while Date() < maxWaitUntilOthersExit {
            let stillRunning = Self.allKnownBundleIdentifiers
                .flatMap { bundleID in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) }
                .contains { runningApplication in
                    runningApplication.processIdentifier != ownProcessIdentifier
                }
            if !stillRunning { break }
            // Block main thread briefly — this runs once on launch, before
            // we create the status item or install any event taps.
            Thread.sleep(forTimeInterval: 0.05)
        }

        // Force-kill any stragglers that still haven't exited.
        let stragglers = Self.allKnownBundleIdentifiers
            .flatMap { bundleID in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) }
            .filter { runningApplication in
                runningApplication.processIdentifier != ownProcessIdentifier
            }
        for straggler in stragglers {
            straggler.forceTerminate()
        }
    }

    private var isRunningAsUnitTestHost: Bool {
        NSClassFromString("XCTestCase") != nil ||
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// Registers the app as a login item so it launches automatically on
    /// startup. Uses SMAppService which shows the app in System Settings >
    /// General > Login Items, letting the user toggle it off if they want.
    private func registerAsLoginItemIfNeeded() {
        let loginItemService = SMAppService.mainApp
        if loginItemService.status != .enabled {
            do {
                try loginItemService.register()
                print("🎯 ipop.ai: Registered as login item")
            } catch {
                print("⚠️ ipop.ai: Failed to register as login item: \(error)")
            }
        }
    }

    private func startSparkleUpdater() {
        let updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.sparkleUpdaterController = updaterController

        do {
            try updaterController.updater.start()
        } catch {
            print("⚠️ ipop.ai: Sparkle updater failed to start: \(error)")
        }
    }
}
