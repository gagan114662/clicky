import Darwin
import Foundation

/// Runs a single shell command via `/bin/zsh -c`. Captures stdout, stderr, exit status.
/// Times out after a configurable interval (default 60s).
struct BashToolExecutor {
    let timeoutSeconds: TimeInterval

    init(timeoutSeconds: TimeInterval = 60) {
        self.timeoutSeconds = timeoutSeconds
    }

    func runShellCommand(_ shellCommandString: String) async -> ToolExecutionResult {
        // Tool input is wrapped — Claude sends {"command": "..."} or {"restart": true}.
        // The caller has already extracted the raw string here.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", shellCommandString]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        // Pipe an empty stdin and close it. Some tools (notably `codex exec`)
        // read stdin even when the prompt is passed as an argument; without
        // an explicit empty stdin closed at EOF they hang waiting for input
        // that never arrives, and the timeout eventually kills them. Setting
        // a Pipe and immediately closing the write end gives them EOF on
        // their first read.
        let emptyStdinPipe = Pipe()
        process.standardInput = emptyStdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let stdoutBuffer = LockedOutputBuffer(maxBytes: 512 * 1024)
        let stderrBuffer = LockedOutputBuffer(maxBytes: 512 * 1024)
        let timeoutState = LockedBool()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                stdoutBuffer.append(data)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                stderrBuffer.append(data)
            }
        }

        // Forward env so children find binaries like codex-clicky on PATH and
        // pick up CODEX_HOME for auth state.
        var env = ProcessInfo.processInfo.environment
        let extraPaths = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["PATH"] = extraPaths + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        if env["CODEX_HOME"] == nil {
            env["CODEX_HOME"] = "\(NSHomeDirectory())/.codex"
        }
        process.environment = env

        do {
            try process.run()
            try? emptyStdinPipe.fileHandleForWriting.close()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            try? emptyStdinPipe.fileHandleForWriting.close()
            return ToolExecutionResult(
                toolUseId: "",
                isError: true,
                textContent: "Failed to launch shell: \(error.localizedDescription)",
                imageDataIfAny: nil
            )
        }

        // Schedule a timeout. Cancelling the task does NOT terminate the process,
        // so we explicitly call terminate() if the deadline passes.
        let timeoutTask = Task { [process] in
            try? await Task.sleep(nanoseconds: UInt64(self.timeoutSeconds * 1_000_000_000))
            if process.isRunning {
                timeoutState.setTrue()
                process.terminate()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }

        await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in continuation.resume() }
        }
        timeoutTask.cancel()

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        stdoutBuffer.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
        stderrBuffer.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())

        let stdoutString = stdoutBuffer.stringValue()
        let stderrString = stderrBuffer.stringValue()
        let exitStatus = process.terminationStatus

        // Cap output size sent back to Claude. 8000 chars is enough for most tasks
        // and keeps the next turn cheap. Truncate from the start so the most
        // recent (usually most relevant) lines are kept.
        let timeoutLine = timeoutState.value ? " timeout_after=\(Int(timeoutSeconds))s" : ""
        let combinedOutput = "exit=\(exitStatus)\(timeoutLine)\n--- stdout ---\n\(stdoutString)\n--- stderr ---\n\(stderrString)"
        let truncatedOutput = combinedOutput.count > 8000
            ? "[truncated...]\n" + String(combinedOutput.suffix(8000))
            : combinedOutput

        return ToolExecutionResult(
            toolUseId: "",
            isError: exitStatus != 0 || timeoutState.value,
            textContent: truncatedOutput,
            imageDataIfAny: nil
        )
    }
}

private final class LockedOutputBuffer {
    private let lock = NSLock()
    private var data = Data()
    private let maxBytes: Int
    private var truncatedByteCount = 0

    init(maxBytes: Int) {
        self.maxBytes = maxBytes
    }

    func append(_ newData: Data) {
        guard !newData.isEmpty else { return }
        lock.lock()
        data.append(newData)
        if data.count > maxBytes {
            let overflow = data.count - maxBytes
            data.removeFirst(overflow)
            truncatedByteCount += overflow
        }
        lock.unlock()
    }

    func stringValue() -> String {
        lock.lock()
        let snapshot = data
        let droppedBytes = truncatedByteCount
        lock.unlock()

        let text = String(data: snapshot, encoding: .utf8) ?? ""
        guard droppedBytes > 0 else { return text }
        return "[truncated \(droppedBytes) bytes...]\n" + text
    }
}

private final class LockedBool {
    private let lock = NSLock()
    private var storedValue = false

    var value: Bool {
        lock.lock()
        let currentValue = storedValue
        lock.unlock()
        return currentValue
    }

    func setTrue() {
        lock.lock()
        storedValue = true
        lock.unlock()
    }
}
