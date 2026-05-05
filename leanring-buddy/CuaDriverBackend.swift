import AppKit
import Foundation

enum CuaDriverBackendAttempt: Equatable {
    case handled(String)
    case unavailable(String)
    case failed(String)
}

struct CuaDriverCommand: Equatable {
    let executablePath: String
    let arguments: [String]
}

struct CuaDriverCommandResult: Equatable {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var combinedOutput: String {
        [stdout, stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

enum CuaDriverKeyCommand: Equatable {
    case pressKey(key: String)
    case hotkey(keys: [String])
}

struct CuaDriverBackend {
    static let userDefaultsKey = "cuaDriverEnabled"

    let isEnabled: Bool
    private let client: CuaDriverClient

    init(
        isEnabled: Bool,
        client: CuaDriverClient = CuaDriverClient()
    ) {
        self.isEnabled = isEnabled
        self.client = client
    }

    static var defaultEnabled: Bool {
        false
    }

    static func statusSubtitle(isEnabled: Bool) -> String {
        guard isEnabled else {
            return "Optional background keyboard backend"
        }
        return CuaDriverClient.defaultExecutablePath() == nil
            ? "Install Cua Driver to enable"
            : "Background type/key when available"
    }

    @MainActor
    func typeText(_ text: String) async -> CuaDriverBackendAttempt {
        guard isEnabled else { return .unavailable("Cua Driver disabled") }
        guard !text.isEmpty else { return .handled("ok (empty text)") }
        guard let pid = frontmostTargetPID() else {
            return .unavailable("No frontmost target app")
        }

        let result = await client.call(
            toolName: "type_text",
            jsonArguments: [
                "pid": Int(pid),
                "text": text,
                "delay_ms": 20
            ]
        )
        return attemptResult(result, successMessage: "ok (cua-driver type_text)")
    }

    @MainActor
    func pressKeyCombo(_ keyComboString: String) async -> CuaDriverBackendAttempt {
        guard isEnabled else { return .unavailable("Cua Driver disabled") }
        guard let keyCommand = Self.keyCommand(from: keyComboString) else {
            return .unavailable("Unknown Cua key combo: \(keyComboString)")
        }
        guard let pid = frontmostTargetPID() else {
            return .unavailable("No frontmost target app")
        }

        let result: CuaDriverCommandResult
        switch keyCommand {
        case .pressKey(let key):
            result = await client.call(
                toolName: "press_key",
                jsonArguments: [
                    "pid": Int(pid),
                    "key": key
                ]
            )
        case .hotkey(let keys):
            result = await client.call(
                toolName: "hotkey",
                jsonArguments: [
                    "pid": Int(pid),
                    "keys": keys
                ]
            )
        }
        return attemptResult(result, successMessage: "ok (cua-driver key)")
    }

    static func keyCommand(from keyComboString: String) -> CuaDriverKeyCommand? {
        let segments = keyComboString
            .split(separator: "+")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !segments.isEmpty else { return nil }

        var modifiers: [String] = []
        var nonModifierKey: String?

        for segment in segments {
            let normalized = normalizedKeySegment(segment)
            switch normalized {
            case "cmd", "shift", "option", "ctrl", "fn":
                modifiers.append(normalized)
            default:
                guard nonModifierKey == nil else { return nil }
                nonModifierKey = normalized
            }
        }

        guard let key = nonModifierKey, isSupportedNonModifierKey(key) else {
            return nil
        }

        if modifiers.isEmpty {
            return .pressKey(key: key)
        }
        return .hotkey(keys: modifiers + [key])
    }

    private static func normalizedKeySegment(_ segment: String) -> String {
        switch segment.lowercased() {
        case "command", "meta": return "cmd"
        case "control": return "ctrl"
        case "alt", "opt": return "option"
        case "enter": return "return"
        case "esc": return "escape"
        default: return segment.lowercased()
        }
    }

    private static func isSupportedNonModifierKey(_ key: String) -> Bool {
        let namedKeys: Set<String> = [
            "return", "tab", "escape", "up", "down", "left", "right",
            "space", "delete", "home", "end", "pageup", "pagedown",
            "f1", "f2", "f3", "f4", "f5", "f6",
            "f7", "f8", "f9", "f10", "f11", "f12"
        ]
        if namedKeys.contains(key) { return true }
        return key.count == 1 && key.range(of: #"^[a-z0-9]$"#, options: .regularExpression) != nil
    }

    @MainActor
    private func frontmostTargetPID() -> pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    private func attemptResult(
        _ result: CuaDriverCommandResult,
        successMessage: String
    ) -> CuaDriverBackendAttempt {
        guard result.exitCode == 0 else {
            return .failed(result.combinedOutput.isEmpty
                ? "cua-driver exited \(result.exitCode)"
                : result.combinedOutput)
        }
        return .handled(successMessage)
    }
}

struct CuaDriverClient {
    var executablePath: String?
    var timeoutSeconds: TimeInterval

    init(
        executablePath: String? = CuaDriverClient.defaultExecutablePath(),
        timeoutSeconds: TimeInterval = 4
    ) {
        self.executablePath = executablePath
        self.timeoutSeconds = timeoutSeconds
    }

    static func defaultExecutablePath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> String? {
        if let configuredPath = environment["IPOP_CUA_DRIVER_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !configuredPath.isEmpty,
           fileManager.isExecutableFile(atPath: configuredPath) {
            return configuredPath
        }

        let candidatePaths = [
            "/Applications/CuaDriver.app/Contents/MacOS/cua-driver",
            "\(NSHomeDirectory())/.local/bin/cua-driver",
            "/opt/homebrew/bin/cua-driver",
            "/usr/local/bin/cua-driver"
        ]
        return candidatePaths.first { fileManager.isExecutableFile(atPath: $0) }
    }

    static func makeCommand(
        executablePath: String,
        toolName: String,
        jsonArguments: [String: Any]
    ) -> CuaDriverCommand? {
        guard JSONSerialization.isValidJSONObject(jsonArguments),
              let data = try? JSONSerialization.data(withJSONObject: jsonArguments, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return CuaDriverCommand(executablePath: executablePath, arguments: [toolName, json])
    }

    func call(toolName: String, jsonArguments: [String: Any]) async -> CuaDriverCommandResult {
        guard let executablePath else {
            return CuaDriverCommandResult(
                exitCode: 127,
                stdout: "",
                stderr: "cua-driver executable not found"
            )
        }
        guard let command = Self.makeCommand(
            executablePath: executablePath,
            toolName: toolName,
            jsonArguments: jsonArguments
        ) else {
            return CuaDriverCommandResult(
                exitCode: 64,
                stdout: "",
                stderr: "invalid cua-driver JSON arguments"
            )
        }

        return await Task.detached(priority: .userInitiated) {
            runCuaDriverCommand(command, timeoutSeconds: timeoutSeconds)
        }.value
    }
}

private func runCuaDriverCommand(
    _ command: CuaDriverCommand,
    timeoutSeconds: TimeInterval
) -> CuaDriverCommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: command.executablePath)
    process.arguments = command.arguments

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    let didExit = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in didExit.signal() }

    do {
        try process.run()
    } catch {
        return CuaDriverCommandResult(exitCode: 127, stdout: "", stderr: error.localizedDescription)
    }

    let timeoutResult = didExit.wait(timeout: .now() + timeoutSeconds)
    if timeoutResult == .timedOut {
        process.terminate()
        if didExit.wait(timeout: .now() + 0.5) == .timedOut {
            process.interrupt()
        }
    }

    let stdout = String(
        data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
    ) ?? ""
    let stderr = String(
        data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
    ) ?? ""

    return CuaDriverCommandResult(
        exitCode: timeoutResult == .timedOut ? 124 : process.terminationStatus,
        stdout: stdout,
        stderr: timeoutResult == .timedOut ? "cua-driver timed out" : stderr
    )
}
