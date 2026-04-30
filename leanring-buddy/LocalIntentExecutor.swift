//
//  LocalIntentExecutor.swift
//  leanring-buddy
//
//  Runs LocalIntent values via macOS-native APIs (NSWorkspace, AXUIElement,
//  CGEvent). Designed for sub-200ms latency — no network, no LLM, no TTS
//  round-trip. The visible action IS the user feedback for most intents.
//

import AppKit
import ApplicationServices
import Foundation

@MainActor
enum LocalIntentExecutor {

    /// Result of attempting an intent.
    enum ExecutionResult {
        /// Intent ran successfully — caller should skip the LLM.
        /// `spokenAcknowledgement` is non-empty only when the intent's whole
        /// purpose IS to speak (e.g. .currentTime). For action intents we
        /// leave it empty because the visible action is the feedback.
        case succeeded(spokenAcknowledgement: String)
        /// Intent didn't run — caller falls back to the LLM with the
        /// original transcript.
        case failed(reason: String)
    }

    static func execute(_ intent: LocalIntent) async -> ExecutionResult {
        switch intent {
        case .launchOrActivateApp(let name):
            return await launchOrActivateApp(named: name)
        case .quitApp(let name):
            return quitApp(named: name)
        case .createNote(let text):
            return await createNote(text: text)
        case .clickByName(let name):
            // Brief settle pause so click lands AFTER any preceding launch
            // has actually focused its window. Cheap insurance for chains.
            try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
            return clickElementByName(name)
        case .typeText(let text):
            // Same insurance — typing into a window that hasn't focused yet
            // is the most common multi-action chain failure.
            try? await Task.sleep(nanoseconds: 100_000_000)
            return typeText(text)
        case .pressKeyChord(let chord):
            try? await Task.sleep(nanoseconds: 100_000_000)
            return pressKeyChord(chord)
        case .scroll(let direction):
            return scroll(direction: direction)
        case .currentTime:
            return .succeeded(spokenAcknowledgement: spokenCurrentTime())
        case .unmatched:
            return .failed(reason: "no local intent matched")
        }
    }

    private static func createNote(text: String) async -> ExecutionResult {
        let launchResult = await launchOrActivateApp(named: "Notes")
        guard case .succeeded = launchResult else { return launchResult }

        try? await Task.sleep(nanoseconds: 150_000_000)
        let newNoteResult = pressKeyChord("cmd+n")
        guard case .succeeded = newNoteResult else { return newNoteResult }

        try? await Task.sleep(nanoseconds: 150_000_000)
        let typeResult = typeText(text)
        if case .succeeded = typeResult {
            FileLogger.log("⚡️ LocalIntent: create note \"\(text.prefix(80))\(text.count > 80 ? "…" : "")\"")
        }
        return typeResult
    }

    // MARK: - App launch / activate

    private static func launchOrActivateApp(named requestedName: String) async -> ExecutionResult {
        // Fast path: app already running — just activate. macOS makes this
        // synchronous with the next action: by the time activate() returns,
        // the app's main window is the key window.
        let lowercaseRequested = requestedName.lowercased()
        if let runningApp = NSWorkspace.shared.runningApplications.first(where: {
            ($0.localizedName ?? "").lowercased() == lowercaseRequested
        }) {
            runningApp.activate(options: [.activateAllWindows])
            FileLogger.log("⚡️ LocalIntent: activate \"\(runningApp.localizedName ?? requestedName)\"")
            await waitForAppToBecomeFrontmost(matching: runningApp.localizedName ?? requestedName, timeoutSeconds: 1.0)
            return .succeeded(spokenAcknowledgement: "")
        }

        for candidate in casingCandidates(for: requestedName) {
            if let appURL = installedApplicationURL(named: candidate) {
                return await launchAppAt(appURL, label: candidate)
            }
        }

        // Fuzzy fallback: voice transcripts get app names slightly wrong
        // ("feeform" instead of "Freeform"). Search the installed-app cache
        // for the closest match within a tight Levenshtein distance.
        if let fuzzyMatch = closestInstalledAppName(to: requestedName),
           let appURL = installedApplicationURL(named: fuzzyMatch) {
            FileLogger.log("🔍 LocalIntent: fuzzy-matched \"\(requestedName)\" → \"\(fuzzyMatch)\"")
            return await launchAppAt(appURL, label: fuzzyMatch)
        }

        return .failed(reason: "no app named \(requestedName) found")
    }

    /// Helper that runs the actual NSWorkspace open with the standard config
    /// and waits for the launched app to actually become frontmost so any
    /// chained subsequent actions land in the right window.
    private static func launchAppAt(_ url: URL, label: String) async -> ExecutionResult {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                if let error {
                    FileLogger.log("⚠️ LocalIntent: openApplication failed for \(label): \(error)")
                }
                continuation.resume()
            }
        }
        FileLogger.log("⚡️ LocalIntent: launch \"\(label)\"")

        // Critical for chained actions like Notes→cmd+n→type: don't return
        // until the app is actually frontmost, otherwise the next action's
        // CGEvent goes to the wrong window.
        await waitForAppToBecomeFrontmost(matching: label, timeoutSeconds: 2.5)
        return .succeeded(spokenAcknowledgement: "")
    }

    /// Polls every 50ms until the frontmost app's name matches `label` (case
    /// insensitive, partial match either way), or the timeout elapses.
    /// Typical app activation completes in 200-500ms so the timeout is
    /// generous; we exit early on success.
    private static func waitForAppToBecomeFrontmost(matching label: String, timeoutSeconds: Double) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        let normalizedLabel = label.lowercased()
        while Date() < deadline {
            if let frontmostApp = NSWorkspace.shared.frontmostApplication,
               let frontmostName = frontmostApp.localizedName?.lowercased() {
                if frontmostName == normalizedLabel
                    || frontmostName.contains(normalizedLabel)
                    || normalizedLabel.contains(frontmostName) {
                    // Tiny extra settle so the window is really key, not just
                    // the process being foregrounded.
                    try? await Task.sleep(nanoseconds: 80_000_000)  // 80ms
                    return
                }
            }
            try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms poll
        }
        FileLogger.log("⚠️ Timeout (\(timeoutSeconds)s) waiting for \"\(label)\" to become frontmost")
    }

    /// Scans /Applications, /System/Applications, and ~/Applications once
    /// per process and caches the list. Used for fuzzy name matching when
    /// the user's spoken app name doesn't exactly match what's installed.
    private static let installedAppNamesCache: [String] = {
        let appDirectories = installedApplicationDirectories
        let fileManager = FileManager.default
        var collectedAppNames: Set<String> = []
        for directoryURL in appDirectories {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for entryURL in entries where entryURL.pathExtension == "app" {
                let appName = entryURL.deletingPathExtension().lastPathComponent
                if !appName.isEmpty {
                    collectedAppNames.insert(appName)
                }
            }
        }
        return collectedAppNames.sorted()
    }()

    private static let installedApplicationDirectories: [URL] = [
        URL(fileURLWithPath: "/Applications"),
        URL(fileURLWithPath: "/System/Applications"),
        URL(fileURLWithPath: "/System/Applications/Utilities"),
        URL(fileURLWithPath: NSHomeDirectory() + "/Applications"),
    ]

    private static func installedApplicationURL(named requestedName: String) -> URL? {
        let normalizedRequestedName = requestedName.lowercased()
        let fileManager = FileManager.default

        for directoryURL in installedApplicationDirectories {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            for entryURL in entries where entryURL.pathExtension == "app" {
                let appName = entryURL.deletingPathExtension().lastPathComponent
                if appName.lowercased() == normalizedRequestedName {
                    return entryURL
                }
            }
        }

        return nil
    }
    /// Finds the installed app whose name is closest to `requestedName`,
    /// returning nil if no app is within the acceptable similarity bound.
    /// Tunable: ~30% character distance is generous enough for ASR typos
    /// like "feeform"→"Freeform" while strict enough to reject unrelated
    /// transcripts ("explain html" → no match).
    private static func closestInstalledAppName(to requestedName: String) -> String? {
        let normalizedRequested = requestedName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedRequested.isEmpty else { return nil }

        var bestMatch: (name: String, distance: Int)? = nil

        for installedName in installedAppNamesCache {
            let distance = levenshteinDistance(normalizedRequested, installedName.lowercased())
            if bestMatch == nil || distance < bestMatch!.distance {
                bestMatch = (installedName, distance)
            }
        }

        guard let match = bestMatch else { return nil }

        // Accept only matches within ~30% character distance, with a floor
        // of 1 for very short names (so 1-char typos in 3-char names work).
        let maxAllowedDistance = max(1, normalizedRequested.count * 3 / 10)
        return match.distance <= maxAllowedDistance ? match.name : nil
    }

    /// Standard Wagner-Fischer Levenshtein distance.
    private static func levenshteinDistance(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        if aChars.isEmpty { return bChars.count }
        if bChars.isEmpty { return aChars.count }

        var distanceMatrix = Array(
            repeating: Array(repeating: 0, count: bChars.count + 1),
            count: aChars.count + 1
        )
        for i in 0...aChars.count { distanceMatrix[i][0] = i }
        for j in 0...bChars.count { distanceMatrix[0][j] = j }
        for i in 1...aChars.count {
            for j in 1...bChars.count {
                if aChars[i - 1] == bChars[j - 1] {
                    distanceMatrix[i][j] = distanceMatrix[i - 1][j - 1]
                } else {
                    distanceMatrix[i][j] = 1 + min(
                        distanceMatrix[i - 1][j],
                        distanceMatrix[i][j - 1],
                        distanceMatrix[i - 1][j - 1]
                    )
                }
            }
        }
        return distanceMatrix[aChars.count][bChars.count]
    }

    private static func casingCandidates(for name: String) -> [String] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var candidates: [String] = [trimmed]
        let titleCased = trimmed
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
        if titleCased != trimmed {
            candidates.append(titleCased)
        }

        let knownCasings: [String: String] = [
            "vs code": "Visual Studio Code",
            "vscode": "Visual Studio Code",
            "intellij": "IntelliJ IDEA",
            "iterm": "iTerm",
            "iterm2": "iTerm",
            "imovie": "iMovie",
            "preview": "Preview",
            "safari": "Safari",
            "freeform": "Freeform",
            "x code": "Xcode",
            "xcode": "Xcode",
            "chrome": "Google Chrome",
            "firefox": "Firefox",
        ]
        if let known = knownCasings[trimmed.lowercased()] {
            candidates.append(known)
        }

        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    private static func quitApp(named requestedName: String) -> ExecutionResult {
        let lowercaseRequested = requestedName.lowercased()
        for runningApp in NSWorkspace.shared.runningApplications {
            guard let localizedName = runningApp.localizedName else { continue }
            if localizedName.lowercased() == lowercaseRequested {
                if runningApp.terminate() {
                    FileLogger.log("⚡️ LocalIntent: quit \"\(localizedName)\"")
                    return .succeeded(spokenAcknowledgement: "")
                } else {
                    return .failed(reason: "\(localizedName) refused to quit")
                }
            }
        }
        return .failed(reason: "no running app named \(requestedName)")
    }

    // MARK: - Generic click via AX tree walk

    /// Walks the frontmost app's accessibility tree looking for any element
    /// whose title matches `targetName` (case-insensitively, exact match
    /// preferred, prefix match second, substring match last). Calls
    /// AXPress on the best match. ~10-50ms for typical apps.
    ///
    /// "apple" / "apple menu" is special-cased to mean "first menu bar item"
    /// because the Apple menu has no title in AX.
    private static func clickElementByName(_ targetName: String) -> ExecutionResult {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            return .failed(reason: "no frontmost app")
        }
        let appElement = AXUIElementCreateApplication(frontmostApp.processIdentifier)
        let normalizedTarget = targetName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip a trailing UI-noun suffix so "file menu" matches an
        // AXMenuBarItem titled "File", and "save button" matches a button
        // titled "Save".
        let strippedTarget = stripUINounSuffix(normalizedTarget)

        // Apple menu special case: empty title, always at index 0 of menu bar.
        if strippedTarget == "apple" {
            if let menuBar = axCopyAttribute(appElement, attribute: kAXMenuBarAttribute),
               CFGetTypeID(menuBar) == AXUIElementGetTypeID(),
               let children = axCopyAttribute(menuBar as! AXUIElement, attribute: kAXChildrenAttribute) as? [AXUIElement],
               let appleMenu = children.first {
                if AXUIElementPerformAction(appleMenu, kAXPressAction as CFString) == .success {
                    FileLogger.log("⚡️ LocalIntent: click Apple menu in \(frontmostApp.localizedName ?? "?")")
                    return .succeeded(spokenAcknowledgement: "")
                }
            }
            return .failed(reason: "could not press Apple menu (accessibility permission?)")
        }

        // Generic walk — find best-scoring titled element.
        var bestMatch: (element: AXUIElement, score: Double, title: String, role: String)? = nil
        walkAccessibilityTree(appElement, depth: 0, maxDepth: 10) { element in
            let title = (axCopyAttribute(element, attribute: kAXTitleAttribute) as? String) ?? ""
            let titleLower = title.lowercased()
            guard !titleLower.isEmpty else { return }

            var score: Double = 0
            if titleLower == strippedTarget {
                score = 100
            } else if titleLower.hasPrefix(strippedTarget + " ") || titleLower.hasPrefix(strippedTarget) {
                score = 70
            } else if titleLower.contains(strippedTarget) {
                score = 40
            } else {
                return
            }

            // Boost interactive roles so we prefer a button labeled "Save"
            // over a static text labeled "Save".
            let role = (axCopyAttribute(element, attribute: kAXRoleAttribute) as? String) ?? ""
            let interactiveRoles: Set<String> = [
                "AXButton", "AXMenuItem", "AXMenuBarItem", "AXMenu",
                "AXLink", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
                "AXTabGroup", "AXSwitch",
            ]
            if interactiveRoles.contains(role) {
                score += 15
            }

            if bestMatch == nil || score > bestMatch!.score {
                bestMatch = (element, score, title, role)
            }
        }

        guard let match = bestMatch else {
            return .failed(reason: "no element titled \"\(targetName)\" in \(frontmostApp.localizedName ?? "frontmost app")")
        }

        let pressStatus = AXUIElementPerformAction(match.element, kAXPressAction as CFString)
        if pressStatus == .success {
            FileLogger.log("⚡️ LocalIntent: click \"\(match.title)\" (\(match.role)) in \(frontmostApp.localizedName ?? "?")")
            return .succeeded(spokenAcknowledgement: "")
        } else {
            return .failed(reason: "AX press failed on \"\(match.title)\" (status=\(pressStatus.rawValue))")
        }
    }

    private static func stripUINounSuffix(_ text: String) -> String {
        let suffixes = [" menu", " button", " tab", " window", " panel", " link", " field", " checkbox"]
        for suffix in suffixes {
            if text.hasSuffix(suffix) {
                return String(text.dropLast(suffix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return text
    }

    /// Bounded depth-first walk of the AX tree, calling `visit` on each
    /// element. We follow children, visible-children, and the menu-bar
    /// pseudo-attribute (since menu bars aren't always linked from the
    /// regular children list).
    private static func walkAccessibilityTree(
        _ root: AXUIElement,
        depth: Int,
        maxDepth: Int,
        visit: (AXUIElement) -> Void
    ) {
        guard depth <= maxDepth else { return }
        visit(root)

        let childAttributes = [
            kAXChildrenAttribute,
            kAXVisibleChildrenAttribute,
            kAXMenuBarAttribute,
        ]
        for attribute in childAttributes {
            guard let value = axCopyAttribute(root, attribute: attribute) else { continue }

            if let array = value as? [AXUIElement] {
                for child in array {
                    walkAccessibilityTree(child, depth: depth + 1, maxDepth: maxDepth, visit: visit)
                }
            } else if CFGetTypeID(value) == AXUIElementGetTypeID() {
                walkAccessibilityTree(value as! AXUIElement, depth: depth + 1, maxDepth: maxDepth, visit: visit)
            }
        }
    }

    private static func axCopyAttribute(_ element: AXUIElement, attribute: String) -> AnyObject? {
        var ref: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &ref)
        guard status == .success else { return nil }
        return ref
    }

    // MARK: - Type text via CGEvent

    /// Types a literal string at the current keyboard focus by synthesizing
    /// per-character key events with `CGEventKeyboardSetUnicodeString`.
    /// Handles arbitrary Unicode (emoji, accented chars, CJK).
    private static func typeText(_ text: String) -> ExecutionResult {
        guard !text.isEmpty else { return .failed(reason: "empty type text") }
        for character in text {
            postUnicodeKeyEvent(for: String(character))
        }
        FileLogger.log("⚡️ LocalIntent: type \"\(text.prefix(80))\(text.count > 80 ? "…" : "")\"")
        return .succeeded(spokenAcknowledgement: "")
    }

    private static func postUnicodeKeyEvent(for substring: String) {
        let utf16 = Array(substring.utf16)
        guard let downEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else { return }
        utf16.withUnsafeBufferPointer { buffer in
            if let baseAddress = buffer.baseAddress {
                downEvent.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: baseAddress)
            }
        }
        downEvent.post(tap: .cghidEventTap)

        guard let upEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { return }
        utf16.withUnsafeBufferPointer { buffer in
            if let baseAddress = buffer.baseAddress {
                upEvent.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: baseAddress)
            }
        }
        upEvent.post(tap: .cghidEventTap)
    }

    // MARK: - Key chord via CGEvent

    /// Posts a chord like "cmd+s" or "cmd+shift+t" or just "return".
    private static func pressKeyChord(_ chord: String) -> ExecutionResult {
        let parts = chord.lowercased().split(separator: "+").map { String($0) }
        guard let keyName = parts.last else { return .failed(reason: "empty chord") }
        let modifierNames = parts.dropLast()

        guard let keyCode = virtualKeyCode(for: keyName) else {
            return .failed(reason: "unknown key \"\(keyName)\" in chord \"\(chord)\"")
        }

        var flags: CGEventFlags = []
        for modifierName in modifierNames {
            switch modifierName {
            case "cmd":   flags.insert(.maskCommand)
            case "ctrl":  flags.insert(.maskControl)
            case "opt":   flags.insert(.maskAlternate)
            case "shift": flags.insert(.maskShift)
            case "fn":    flags.insert(.maskSecondaryFn)
            default:      return .failed(reason: "unknown modifier \"\(modifierName)\"")
            }
        }

        guard let downEvent = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let upEvent = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            return .failed(reason: "could not create key event for \(chord)")
        }

        downEvent.flags = flags
        upEvent.flags = flags
        downEvent.post(tap: .cghidEventTap)
        upEvent.post(tap: .cghidEventTap)
        FileLogger.log("⚡️ LocalIntent: press \(chord)")
        return .succeeded(spokenAcknowledgement: "")
    }

    /// US-keyboard virtual key codes for the keys we recognize.
    private static func virtualKeyCode(for key: String) -> CGKeyCode? {
        if let code = singleCharKeyCode[key] { return code }
        if let code = namedKeyCode[key] { return code }
        return nil
    }

    private static let singleCharKeyCode: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
        "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43,
        "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
    ]

    private static let namedKeyCode: [String: CGKeyCode] = [
        "return": 36, "enter": 36, "tab": 48, "space": 49, "spacebar": 49,
        "delete": 51, "backspace": 51, "forward delete": 117,
        "escape": 53, "esc": 53,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]

    // MARK: - Scroll via CGEvent

    private static func scroll(direction: ScrollDirection) -> ExecutionResult {
        // ~120px per call, roughly 4 lines of text. Multiple calls for more.
        let pixelDelta: Int32 = 120
        let (verticalDelta, horizontalDelta): (Int32, Int32) = {
            switch direction {
            case .up: return (pixelDelta, 0)
            case .down: return (-pixelDelta, 0)
            case .left: return (0, pixelDelta)
            case .right: return (0, -pixelDelta)
            }
        }()

        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: verticalDelta,
            wheel2: horizontalDelta,
            wheel3: 0
        ) else {
            return .failed(reason: "could not create scroll event")
        }
        event.post(tap: .cghidEventTap)
        FileLogger.log("⚡️ LocalIntent: scroll \(direction)")
        return .succeeded(spokenAcknowledgement: "")
    }

    // MARK: - Current time

    private static func spokenCurrentTime() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return "it's \(formatter.string(from: Date()))"
    }
}
