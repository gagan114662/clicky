#!/usr/bin/env swift

import Foundation
import AppKit
import ApplicationServices

struct LiveEvalManifest: Decodable {
    let suite: String
    let version: Int
    let description: String
    let cases: [LiveEvalCase]
}

struct LiveEvalCase: Decodable {
    let id: String
    let title: String
    let lane: String
    let risk: String
    let transcript: String
    let setup: [String]
    let waitSeconds: Double
    let requiredApps: [String]?
    let expectedFrontmostApp: String?
    let expected: [String]
}

struct Options {
    var manifestPath = "docs/live-evals/ipop-live-eval-suite.json"
    var outputDirectory: String?
    var selectedCaseIDs = Set<String>()
    var runAll = false
    var dryRun = false
    var listOnly = false
    var waitOverride: Double?
}

enum RunnerError: Error, CustomStringConvertible {
    case missingValue(String)
    case unknownArgument(String)
    case noSelectedCases
    case caseNotFound(String)

    var description: String {
        switch self {
        case .missingValue(let flag):
            return "Missing value after \(flag)"
        case .unknownArgument(let argument):
            return "Unknown argument: \(argument)"
        case .noSelectedCases:
            return "Choose --all or one or more --case <id>. Use --list to see cases."
        case .caseNotFound(let id):
            return "No live eval case exists with id \(id)"
        }
    }
}

@discardableResult
func runProcess(_ executable: String, _ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    try process.run()
    process.waitUntilExit()

    let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

    if process.terminationStatus != 0 {
        throw NSError(
            domain: "LiveEvalRunner",
            code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: errorOutput.isEmpty ? output : errorOutput]
        )
    }

    return output
}

func runShell(_ command: String) throws {
    _ = try runProcess("/bin/zsh", ["-lc", command])
}

func parseOptions(_ arguments: [String]) throws -> Options {
    var options = Options()
    var index = 0

    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--manifest":
            index += 1
            guard index < arguments.count else { throw RunnerError.missingValue(argument) }
            options.manifestPath = arguments[index]
        case "--out":
            index += 1
            guard index < arguments.count else { throw RunnerError.missingValue(argument) }
            options.outputDirectory = arguments[index]
        case "--case":
            index += 1
            guard index < arguments.count else { throw RunnerError.missingValue(argument) }
            options.selectedCaseIDs.insert(arguments[index])
        case "--all":
            options.runAll = true
        case "--dry-run":
            options.dryRun = true
        case "--list":
            options.listOnly = true
        case "--wait":
            index += 1
            guard index < arguments.count else { throw RunnerError.missingValue(argument) }
            options.waitOverride = Double(arguments[index])
        case "--help", "-h":
            printUsage()
            exit(0)
        default:
            throw RunnerError.unknownArgument(argument)
        }
        index += 1
    }

    return options
}

func printUsage() {
    print("""
    Usage:
      scripts/live-eval-runner.swift --list
      scripts/live-eval-runner.swift --dry-run --all
      scripts/live-eval-runner.swift --case teacher-freeform-multiplication
      scripts/live-eval-runner.swift --all --out artifacts/live-evals/manual-run

    Notes:
      - Launch iPOP from Xcode in DEBUG before a real run.
      - The runner posts ipopDebugSubmitTranscript through DistributedNotificationCenter.
      - It captures before/after screenshots, screen text snapshots, iPOP logs, action traces, and a markdown report.
    """)
}

func loadManifest(path: String) throws -> LiveEvalManifest {
    let url = URL(fileURLWithPath: path)
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(LiveEvalManifest.self, from: data)
}

func isIpopDebugAppLikelyRunning() -> Bool {
    let bundleIDs = [
        "ai.ipop.mac",
        "com.yourcompany.leanring-buddy",
        "com.humansongs.clicky"
    ]
    return bundleIDs.contains { bundleID in
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }
}

func selectedCases(from manifest: LiveEvalManifest, options: Options) throws -> [LiveEvalCase] {
    if options.runAll {
        return manifest.cases
    }

    guard !options.selectedCaseIDs.isEmpty else {
        if options.listOnly { return [] }
        throw RunnerError.noSelectedCases
    }

    return try options.selectedCaseIDs.sorted().map { id in
        guard let liveCase = manifest.cases.first(where: { $0.id == id }) else {
            throw RunnerError.caseNotFound(id)
        }
        return liveCase
    }
}

func makeRunDirectory(_ explicitPath: String?) throws -> URL {
    if let explicitPath {
        let url = URL(fileURLWithPath: explicitPath)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let path = "artifacts/live-evals/\(formatter.string(from: Date()))"
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func append(_ text: String, to fileURL: URL) throws {
    let data = Data(text.utf8)
    if FileManager.default.fileExists(atPath: fileURL.path) {
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.close()
    } else {
        try data.write(to: fileURL)
    }
}

func write(_ text: String, to fileURL: URL) throws {
    try Data(text.utf8).write(to: fileURL)
}

func captureScreenshot(_ fileURL: URL) throws {
    _ = try runProcess("/usr/sbin/screencapture", ["-x", fileURL.path])
}

func frontmostAccessibilityTextSnapshot() -> String {
    guard AXIsProcessTrusted() else {
        return "Accessibility permission is not granted to this runner, so screen text could not be captured."
    }
    guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else {
        return "No frontmost application was available."
    }

    let rootElement = AXUIElementCreateApplication(frontmostApplication.processIdentifier)
    var lines: [String] = [
        "Frontmost app: \(frontmostApplication.localizedName ?? "(unknown)")"
    ]

    if let focusedWindow = axElementAttribute(rootElement, kAXFocusedWindowAttribute) {
        appendAccessibilitySnapshot(
            from: focusedWindow,
            depth: 0,
            maxDepth: 6,
            remainingNodeBudget: 180,
            lines: &lines
        )
    } else {
        appendAccessibilitySnapshot(
            from: rootElement,
            depth: 0,
            maxDepth: 5,
            remainingNodeBudget: 180,
            lines: &lines
        )
    }

    let uniqueLines = lines.reduce(into: [String]()) { result, line in
        if !result.contains(line) {
            result.append(line)
        }
    }
    return uniqueLines.joined(separator: "\n")
}

func axElementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    guard result == .success, let value else { return nil }
    return (value as! AXUIElement)
}

func axChildren(of element: AXUIElement) -> [AXUIElement] {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
    guard result == .success, let children = value as? [AXUIElement] else {
        return []
    }
    return children
}

func axStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    guard result == .success, let value else { return nil }

    if let stringValue = value as? String {
        let trimmedString = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedString.isEmpty ? nil : trimmedString
    }
    if let attributedStringValue = value as? NSAttributedString {
        let trimmedString = attributedStringValue.string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedString.isEmpty ? nil : trimmedString
    }
    return nil
}

func appendAccessibilitySnapshot(
    from element: AXUIElement,
    depth: Int,
    maxDepth: Int,
    remainingNodeBudget: Int,
    lines: inout [String]
) {
    guard depth <= maxDepth, remainingNodeBudget > 0 else { return }

    let role = axStringAttribute(element, kAXRoleAttribute)
    let title = axStringAttribute(element, kAXTitleAttribute)
    let value = axStringAttribute(element, kAXValueAttribute)
    let description = axStringAttribute(element, kAXDescriptionAttribute)
    let linePieces = [role, title, value, description]
        .compactMap { $0 }
        .filter { !$0.isEmpty }

    if !linePieces.isEmpty {
        let indent = String(repeating: "  ", count: depth)
        lines.append(indent + linePieces.joined(separator: " | "))
    }

    var childBudget = remainingNodeBudget - 1
    for child in axChildren(of: element) where childBudget > 0 {
        appendAccessibilitySnapshot(
            from: child,
            depth: depth + 1,
            maxDepth: maxDepth,
            remainingNodeBudget: childBudget,
            lines: &lines
        )
        childBudget -= 1
    }
}

func frontmostAppName() -> String {
    NSWorkspace.shared.frontmostApplication?.localizedName ?? "(none)"
}

func appIsInstalledOrRunning(named appName: String) -> Bool {
    let lowercasedName = appName.lowercased()
    if NSWorkspace.shared.runningApplications.contains(where: {
        ($0.localizedName ?? "").lowercased() == lowercasedName
    }) {
        return true
    }

    let applicationPaths = [
        "/Applications/\(appName).app",
        "/System/Applications/\(appName).app",
        "\(NSHomeDirectory())/Applications/\(appName).app"
    ]
    return applicationPaths.contains { FileManager.default.fileExists(atPath: $0) }
}

func missingRequiredApps(for liveCase: LiveEvalCase) -> [String] {
    (liveCase.requiredApps ?? []).filter { !appIsInstalledOrRunning(named: $0) }
}

func ipopLogFileURL() -> URL {
    let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory() + "/Desktop")
    return desktop.appendingPathComponent("ipop-ai.log")
}

func fullIpopLogText() -> String {
    let url = ipopLogFileURL()
    guard let data = try? Data(contentsOf: url),
          let text = String(data: data, encoding: .utf8)
    else {
        return ""
    }
    return text
}

func recentIpopLogTail(maxLines: Int = 220) -> String {
    let text = fullIpopLogText()
    guard !text.isEmpty else {
        return "(no iPOP log found at \(ipopLogFileURL().path))"
    }

    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    return lines.suffix(maxLines).joined(separator: "\n")
}

func ipopLogSlice(after previousLogText: String) -> String {
    let currentLogText = fullIpopLogText()
    guard !currentLogText.isEmpty else {
        return "(no iPOP log found at \(ipopLogFileURL().path))"
    }

    if currentLogText.hasPrefix(previousLogText) {
        let sliceStartIndex = currentLogText.index(
            currentLogText.startIndex,
            offsetBy: previousLogText.count
        )
        let slice = String(currentLogText[sliceStartIndex...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return slice.isEmpty ? "(no new iPOP log lines during this case)" : slice
    }

    return recentIpopLogTail(maxLines: 260)
}

func actionTrace(from logText: String) -> String {
    let interestingSignals = [
        "🧭",
        "🤖 Agent",
        "🛑 Agent confirmation",
        "⚡️",
        "🐟",
        "🎯 LocalIntent",
        "📝 Parsed",
        "Claude action"
    ]
    let lines = logText
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
        .filter { line in
            interestingSignals.contains { line.contains($0) }
        }
    return lines.isEmpty
        ? "(no action trace lines found in the case log slice)"
        : lines.joined(separator: "\n")
}

func postTranscript(_ transcript: String) {
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("ipopDebugSubmitTranscript"),
        object: nil,
        userInfo: ["transcript": transcript],
        deliverImmediately: true
    )
}

func markdownList(_ values: [String]) -> String {
    values.map { "- \($0)" }.joined(separator: "\n")
}

func runCase(_ liveCase: LiveEvalCase, options: Options, runDirectory: URL, reportURL: URL) throws {
    let waitSeconds = options.waitOverride ?? liveCase.waitSeconds
    let beforeURL = runDirectory.appendingPathComponent("\(liveCase.id)-before.png")
    let afterURL = runDirectory.appendingPathComponent("\(liveCase.id)-after.png")
    let logTailURL = runDirectory.appendingPathComponent("\(liveCase.id)-ipop-log-tail.txt")
    let logSliceURL = runDirectory.appendingPathComponent("\(liveCase.id)-ipop-log-slice.txt")
    let actionTraceURL = runDirectory.appendingPathComponent("\(liveCase.id)-action-trace.txt")
    let screenTextURL = runDirectory.appendingPathComponent("\(liveCase.id)-screen-text.txt")
    let metadataURL = runDirectory.appendingPathComponent("\(liveCase.id)-metadata.txt")

    print("Running \(liveCase.id): \(liveCase.title)")

    try append("""

    ## \(liveCase.id)

    Title: \(liveCase.title)
    Lane: \(liveCase.lane)
    Risk: \(liveCase.risk)

    Transcript:
    ```
    \(liveCase.transcript)
    ```

    Expected:
    \(markdownList(liveCase.expected))

    """, to: reportURL)

    let missingApps = missingRequiredApps(for: liveCase)
    if !missingApps.isEmpty {
        let skippedMessage = "Skipped: missing required app(s): \(missingApps.joined(separator: ", "))."
        print("  \(skippedMessage)")
        try append("""
        \(skippedMessage)

        Manual verdict:
        - Pass/fail: SKIPPED
        - Notes:

        """, to: reportURL)
        return
    }

    if options.dryRun {
        try append("Dry run only. No setup, transcript injection, or screenshots.\n", to: reportURL)
        return
    }

    let logBeforeCase = fullIpopLogText()
    for command in liveCase.setup {
        print("  setup: \(command)")
        do {
            try runShell(command)
        } catch {
            try append("Setup command failed: `\(command)`\n\nError: \(error)\n\n", to: reportURL)
        }
    }

    let frontmostBeforeTranscript = frontmostAppName()
    try captureScreenshot(beforeURL)
    postTranscript(liveCase.transcript)
    Thread.sleep(forTimeInterval: waitSeconds)
    let frontmostAfterWait = frontmostAppName()
    try captureScreenshot(afterURL)
    let caseLogSlice = ipopLogSlice(after: logBeforeCase)
    try write(recentIpopLogTail(), to: logTailURL)
    try write(caseLogSlice, to: logSliceURL)
    try write(actionTrace(from: caseLogSlice), to: actionTraceURL)
    try write(frontmostAccessibilityTextSnapshot(), to: screenTextURL)
    try write("""
    Case: \(liveCase.id)
    Title: \(liveCase.title)
    Lane: \(liveCase.lane)
    Risk: \(liveCase.risk)
    Required apps: \((liveCase.requiredApps ?? []).isEmpty ? "(none)" : (liveCase.requiredApps ?? []).joined(separator: ", "))
    Expected frontmost app: \(liveCase.expectedFrontmostApp ?? "(none specified)")
    Frontmost before transcript: \(frontmostBeforeTranscript)
    Frontmost after wait: \(frontmostAfterWait)
    Transcript: \(liveCase.transcript)
    """, to: metadataURL)

    try append("""
    Evidence:
    - Before screenshot: \(beforeURL.path)
    - After screenshot: \(afterURL.path)
    - iPOP log tail: \(logTailURL.path)
    - iPOP case log slice: \(logSliceURL.path)
    - iPOP action trace: \(actionTraceURL.path)
    - Frontmost screen text: \(screenTextURL.path)
    - Case metadata: \(metadataURL.path)
    - Frontmost before transcript: \(frontmostBeforeTranscript)
    - Frontmost after wait: \(frontmostAfterWait)

    Manual verdict:
    - Pass/fail:
    - Notes:

    """, to: reportURL)
}

do {
    let options = try parseOptions(Array(CommandLine.arguments.dropFirst()))
    let manifest = try loadManifest(path: options.manifestPath)

    if options.listOnly {
        print("\(manifest.suite) v\(manifest.version)")
        for liveCase in manifest.cases {
            print("\(liveCase.id) [\(liveCase.lane), \(liveCase.risk)] - \(liveCase.title)")
        }
        exit(0)
    }

    let cases = try selectedCases(from: manifest, options: options)
    if options.dryRun {
        print("Dry run: \(cases.count) case(s) selected.")
    } else if !isIpopDebugAppLikelyRunning() {
        print("Warning: iPOP does not appear to be running. Launch from Xcode DEBUG first.")
    }

    let runDirectory = try makeRunDirectory(options.outputDirectory)
    let reportURL = runDirectory.appendingPathComponent("report.md")

    try write("""
    # iPOP Live Eval Report

    Suite: \(manifest.suite) v\(manifest.version)
    Started: \(Date())
    Dry run: \(options.dryRun)

    """, to: reportURL)

    for liveCase in cases {
        try runCase(liveCase, options: options, runDirectory: runDirectory, reportURL: reportURL)
    }

    print("Report: \(reportURL.path)")
} catch {
    fputs("live-eval-runner error: \(error)\n", stderr)
    printUsage()
    exit(1)
}
