//
//  CodexAppServerClient.swift
//  leanring-buddy
//
//  Long-lived JSON-RPC 2.0 client for `codex app-server` (the same protocol
//  the official Codex VS Code extension uses). Replaces the old `codex exec`
//  subprocess-per-task model with a single persistent server that hosts
//  multiple concurrent "threads" — one per ipop.ai sibling.
//
//  Protocol (newline-delimited JSON over stdio):
//    1. App sends `initialize` with clientInfo  → server returns hello
//    2. App sends `thread/start` per sibling    → server returns thread ID
//    3. App sends `turn/start` with the prompt  → server streams agent_message
//       deltas via notifications, plus item.completed events for shell
//       commands and file changes.
//    4. App sends `turn/interrupt` to cancel    (used when user dismisses)
//
//  Each agent message / shell command / file change arrives as a JSON-RPC
//  notification (no `id` field). The client routes those to the per-thread
//  callbacks set up by AgentSessionManager.
//

import Foundation

// MARK: - Errors

enum CodexAppServerError: LocalizedError {
    case binaryNotFound
    case processLaunchFailed(Error)
    case serverDied
    case rpcError(code: Int, message: String)
    case unexpectedResponse(String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "Codex CLI binary not found."
        case .processLaunchFailed(let err):
            return "Failed to launch codex app-server: \(err.localizedDescription)"
        case .serverDied:
            return "codex app-server exited unexpectedly."
        case .rpcError(let code, let message):
            return "Codex RPC error \(code): \(message)"
        case .unexpectedResponse(let detail):
            return "Unexpected response from codex app-server: \(detail)"
        }
    }
}

// MARK: - Stream events surfaced to AgentSessionManager

/// A single delta emitted by codex while a turn is in progress.
/// AgentSessionManager translates these into the panel's live output.
enum CodexThreadEvent: Sendable {
    case agentMessageDelta(String)
    case agentMessageComplete(String)
    case shellCommand(command: String, output: String?)
    case fileChange(paths: [String], kinds: [String])
    case turnCompleted(finalText: String)
    case turnFailed(message: String)
    case info(String)
}

// MARK: - Client

@MainActor
final class CodexAppServerClient {

    // MARK: - Singleton (one server for the whole app)

    static let shared = CodexAppServerClient()

    // MARK: - Private state

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?

    private var isInitialized = false
    private var initializeTask: Task<Void, Error>?

    /// Buffer for incoming JSON lines — stdout chunks may not align to newlines.
    private var stdoutBuffer = ""

    private var nextRequestID: Int = 1
    /// Pending request ID → continuation. When a JSON-RPC response arrives
    /// with a matching id, we resume the awaiting caller.
    private var pendingRequests: [Int: CheckedContinuation<[String: Any], Error>] = [:]

    /// Per-thread event handlers. Notifications carry a thread ID; we route
    /// them to the right sibling's callback.
    private var threadEventHandlers: [String: @MainActor @Sendable (CodexThreadEvent) -> Void] = [:]
    /// Per-thread active turn continuations. Closing a sibling while a turn is
    /// running must resume this continuation, otherwise the Swift Task waits
    /// forever even after the UI is gone.
    private var threadTurnContinuations: [String: CheckedContinuation<String, Error>] = [:]
    /// Tracks which threads are currently running a turn (for interrupt).
    private var threadRunning: [String: Bool] = [:]
    /// Active turn ID per thread. `turn/interrupt` requires both threadId and
    /// turnId, so we capture it from the turn/start response or turn/started
    /// notification before attempting cancellation.
    private var activeTurnIDs: [String: String] = [:]

    // MARK: - Public surface

    /// Whether the codex binary exists and the server CAN be launched.
    /// Mirrors CodexCLIClient.isAvailable() so existing call sites keep working.
    static func isAvailable() -> Bool {
        return findBinaryPath() != nil
    }

    /// Starts a fresh thread and returns its ID. If the server hasn't been
    /// initialized yet, initializes it lazily.
    func startThread(
        cwd: String,
        sandbox: String = "workspace-write",
        approvalPolicy: String = "never"
    ) async throws -> String {
        try await ensureInitialized()
        let params: [String: Any] = [
            "cwd": cwd,
            "sandbox": sandbox,
            "approvalPolicy": approvalPolicy,
        ]
        let result = try await sendRequest(method: "thread/start", params: params)
        guard let thread = result["thread"] as? [String: Any],
              let threadID = thread["id"] as? String else {
            throw CodexAppServerError.unexpectedResponse("thread/start: missing thread.id")
        }
        return threadID
    }

    /// Sends a user prompt as a new turn on the given thread. Streams events
    /// (deltas, shell commands, file changes) via `onEvent`. Returns when
    /// the turn completes (successfully or with an error event).
    func startTurn(
        threadID: String,
        prompt: String,
        onEvent: @escaping @MainActor @Sendable (CodexThreadEvent) -> Void
    ) async throws -> String {
        try await ensureInitialized()
        threadRunning[threadID] = true

        // Install the terminal-event-aware handler BEFORE sending turn/start,
        // so notifications that arrive between submission and the response
        // can't be lost. Both the user's onEvent and our terminal-event
        // tracker run from the same callback.
        return try await withCheckedThrowingContinuation { continuation in
            var accumulatedText = ""
            self.threadTurnContinuations[threadID] = continuation

            self.threadEventHandlers[threadID] = { [weak self] event in
                onEvent(event)
                switch event {
                case .agentMessageDelta(let delta):
                    accumulatedText += delta
                case .agentMessageComplete(let text):
                    if !text.isEmpty { accumulatedText = text }
                case .turnCompleted(let finalText):
                    let finalValue = !finalText.isEmpty ? finalText : accumulatedText
                    self?.finishTurn(threadID: threadID, result: .success(finalValue))
                case .turnFailed(let message):
                    self?.finishTurn(
                        threadID: threadID,
                        result: .failure(CodexAppServerError.rpcError(code: -1, message: message))
                    )
                default:
                    break
                }
            }

            let params: [String: Any] = [
                "threadId": threadID,
                "input": [["type": "text", "text": prompt]],
            ]

            Task { [weak self] in
                guard let self else { return }
                do {
                    let response = try await self.sendRequest(method: "turn/start", params: params)
                    if let turn = response["turn"] as? [String: Any],
                       let turnID = turn["id"] as? String,
                       self.threadRunning[threadID] == true {
                        self.activeTurnIDs[threadID] = turnID
                    }
                } catch {
                    self.finishTurn(threadID: threadID, result: .failure(error))
                }
            }
        }
    }

    /// Interrupts a running turn so the codex agent stops mid-execution.
    /// Used by AgentSessionManager.removeSession() when the user dismisses
    /// a sibling that's still working.
    func interruptTurn(threadID: String) async {
        guard threadRunning[threadID] == true || threadTurnContinuations[threadID] != nil else { return }
        if activeTurnIDs[threadID] == nil {
            for _ in 0..<10 where activeTurnIDs[threadID] == nil {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        guard let turnID = activeTurnIDs[threadID] else {
            print("⚠️ turn/interrupt skipped for thread \(threadID.prefix(8)): no active turn id yet")
            return
        }
        let params: [String: Any] = ["threadId": threadID, "turnId": turnID]
        _ = try? await sendRequest(method: "turn/interrupt", params: params)
        print("🛑 turn/interrupt sent for thread \(threadID.prefix(8)) turn \(turnID.prefix(8))")
    }

    /// Archives a thread so the server frees its resources. Called after
    /// the user dismisses a sibling — without this, threads leak on the
    /// app-server even after their turn completes/interrupts.
    func archiveThread(threadID: String) async {
        cancelLocalTurnWaiter(threadID: threadID, reason: "Codex session was closed.")
        let params: [String: Any] = ["threadId": threadID]
        _ = try? await sendRequest(method: "thread/archive", params: params)
        _ = try? await sendRequest(method: "thread/unsubscribe", params: params)
        threadEventHandlers.removeValue(forKey: threadID)
        threadRunning.removeValue(forKey: threadID)
        activeTurnIDs.removeValue(forKey: threadID)
        print("🗑️ thread/archive + thread/unsubscribe sent for thread \(threadID.prefix(8))")
    }

    private func finishTurn(threadID: String, result: Result<String, Error>) {
        guard let continuation = threadTurnContinuations.removeValue(forKey: threadID) else { return }
        threadRunning[threadID] = false
        activeTurnIDs.removeValue(forKey: threadID)
        threadEventHandlers.removeValue(forKey: threadID)
        switch result {
        case .success(let value):
            continuation.resume(returning: value)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    private func cancelLocalTurnWaiter(threadID: String, reason: String) {
        finishTurn(
            threadID: threadID,
            result: .failure(CodexAppServerError.rpcError(code: -1, message: reason))
        )
    }

    /// Synchronously terminates the codex app-server subprocess AND every
    /// descendant (the node wrapper, the actual codex binary, any child
    /// shells codex spawned). Called from NSApplicationWillTerminate so
    /// codex doesn't outlive ipop.ai. Without this, every app restart
    /// leaks an app-server tree — they end up running indefinitely
    /// consuming the user's quota.
    func shutdownSync() {
        guard let p = process else { return }
        let rootPID = p.processIdentifier
        guard rootPID > 0 else { return }
        print("🛑 Shutting down codex app-server tree starting at pid \(rootPID) on app exit")

        // Walk the live ps table and collect every descendant of rootPID.
        let descendants = Self.descendantPIDs(of: rootPID)
        let allPIDs = [rootPID] + descendants
        print("🛑 Killing \(allPIDs.count) process(es) in tree: \(allPIDs)")

        // SIGTERM first for graceful shutdown.
        for pid in allPIDs { kill(pid, SIGTERM) }
        usleep(300_000) // 300ms grace period
        // SIGKILL anyone still alive.
        for pid in allPIDs {
            if Self.isPIDAlive(pid) { kill(pid, SIGKILL) }
        }

        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: CodexAppServerError.serverDied)
        }
        for (_, continuation) in threadTurnContinuations {
            continuation.resume(throwing: CodexAppServerError.serverDied)
        }
        pendingRequests.removeAll()
        threadTurnContinuations.removeAll()
        threadEventHandlers.removeAll()
        threadRunning.removeAll()
        activeTurnIDs.removeAll()

        process = nil
        stdinHandle = nil
        stdoutHandle = nil
        stderrHandle = nil
    }

    /// Returns every descendant PID of the given root, traversing the live
    /// `ps -axo pid,ppid` table. Synchronous — safe to call from
    /// applicationWillTerminate.
    private static func descendantPIDs(of root: Int32) -> [Int32] {
        // Build pid → [child pids] map from `ps`
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "pid=,ppid="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return [] }
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let s = String(data: data, encoding: .utf8) else { return [] }

        var children: [Int32: [Int32]] = [:]
        for line in s.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2,
                  let pid = Int32(fields[0]),
                  let ppid = Int32(fields[1]) else { continue }
            children[ppid, default: []].append(pid)
        }

        // BFS from root to collect all descendants.
        var collected: [Int32] = []
        var queue: [Int32] = children[root] ?? []
        while !queue.isEmpty {
            let pid = queue.removeFirst()
            collected.append(pid)
            if let kids = children[pid] { queue.append(contentsOf: kids) }
        }
        return collected
    }

    private static func isPIDAlive(_ pid: Int32) -> Bool {
        // kill(pid, 0) returns 0 if the process exists and we can signal it.
        return kill(pid, 0) == 0
    }

    // MARK: - Lifecycle

    private static func findBinaryPath() -> String? {
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/codex-ipop",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Idempotent — first caller starts the server and runs `initialize`,
    /// subsequent callers wait on the same task.
    private func ensureInitialized() async throws {
        if isInitialized { return }
        if let existing = initializeTask {
            try await existing.value
            return
        }
        let task = Task<Void, Error> {
            try self.launchProcess()
            try await self.runInitializeHandshake()
            self.isInitialized = true
        }
        initializeTask = task
        do {
            try await task.value
        } catch {
            initializeTask = nil
            throw error
        }
    }

    private func launchProcess() throws {
        guard let binaryPath = Self.findBinaryPath() else {
            throw CodexAppServerError.binaryNotFound
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [
            "-lc",
            Self.parentWatchdogWrapperScript,
            "codex-app-server-watchdog",
            binaryPath,
            String(ProcessInfo.processInfo.processIdentifier),
            "app-server",
            "--listen",
            "stdio://"
        ]

        var env = ProcessInfo.processInfo.environment
        let extraPaths = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["PATH"] = extraPaths + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        env["CODEX_HOME"] = "\(NSHomeDirectory())/.codex"
        p.environment = env

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stderr

        // Handle server crash or watchdog cleanup — clear state so next call relaunches.
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                print("🟥 codex app-server exited (cleanup)")
                self.process = nil
                self.stdinHandle = nil
                self.stdoutHandle = nil
                self.stderrHandle = nil
                self.isInitialized = false
                self.initializeTask = nil
                // Fail any pending requests
                for (_, cont) in self.pendingRequests {
                    cont.resume(throwing: CodexAppServerError.serverDied)
                }
                for (_, cont) in self.threadTurnContinuations {
                    cont.resume(throwing: CodexAppServerError.serverDied)
                }
                self.pendingRequests.removeAll()
                self.threadTurnContinuations.removeAll()
                self.threadEventHandlers.removeAll()
                self.threadRunning.removeAll()
                self.activeTurnIDs.removeAll()
            }
        }

        do {
            try p.run()
        } catch {
            throw CodexAppServerError.processLaunchFailed(error)
        }

        process = p
        stdinHandle = stdin.fileHandleForWriting
        stdoutHandle = stdout.fileHandleForReading
        stderrHandle = stderr.fileHandleForReading

        // Continuously read stdout — JSON-RPC frames are newline-delimited.
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                self?.handleStdoutChunk(chunk)
            }
        }

        // stderr → console for debugging server issues
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                print("🟥 codex app-server stderr: \(trimmed)")
            }
        }

        print("🚀 codex app-server launched (pid \(p.processIdentifier))")
    }

    private func runInitializeHandshake() async throws {
        let params: [String: Any] = [
            "clientInfo": ["name": "ipop.ai", "version": "0.1"]
        ]
        _ = try await sendRequest(method: "initialize", params: params)
        try sendNotification(method: "initialized")
        print("🤝 codex app-server initialized")
    }

    // MARK: - JSON-RPC framing

    /// Sends a request and waits for its matched response.
    private func sendRequest(method: String, params: [String: Any]) async throws -> [String: Any] {
        let id = nextRequestID
        nextRequestID += 1
        let frame: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        ]
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: Any], Error>) in
            pendingRequests[id] = continuation
            do {
                try writeFrame(frame)
            } catch {
                pendingRequests.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }
    }

    private func sendNotification(method: String, params: [String: Any] = [:]) throws {
        try writeFrame([
            "method": method,
            "params": params,
        ])
    }

    /// Runs codex under a tiny shell watchdog. Xcode's Stop button can kill the
    /// ipop.ai without delivering normal app-termination notifications, so
    /// `shutdownSync()` never gets a chance to run. This wrapper keeps a small
    /// parent-PID monitor alive next to codex; if the app PID disappears, it
    /// kills the codex app-server subtree and exits.
    private static let parentWatchdogWrapperScript = #"""
codex_bin="$1"
parent_pid="$2"
shift 2

kill_tree() {
  local target="$1"
  local signal="$2"
  for child in $(/usr/bin/pgrep -P "$target" 2>/dev/null); do
    kill_tree "$child" "$signal"
  done
  /bin/kill "$signal" "$target" 2>/dev/null
}

"$codex_bin" "$@" &
codex_pid="$!"

(
  while /bin/kill -0 "$parent_pid" 2>/dev/null; do
    /bin/sleep 0.5
  done
  kill_tree "$codex_pid" -TERM
  /bin/sleep 0.5
  kill_tree "$codex_pid" -KILL
) &
watchdog_pid="$!"

wait "$codex_pid"
status="$?"
/bin/kill "$watchdog_pid" 2>/dev/null
exit "$status"
"""#

    private func writeFrame(_ frame: [String: Any]) throws {
        guard let stdin = stdinHandle else {
            throw CodexAppServerError.serverDied
        }
        let json = try JSONSerialization.data(withJSONObject: frame, options: [])
        var line = json
        line.append(0x0A) // newline terminator
        try stdin.write(contentsOf: line)
    }

    /// Parse newline-delimited JSON-RPC frames from accumulating stdout chunks.
    private func handleStdoutChunk(_ chunk: String) {
        stdoutBuffer += chunk
        while let newlineIndex = stdoutBuffer.firstIndex(of: "\n") {
            let line = String(stdoutBuffer[stdoutBuffer.startIndex..<newlineIndex])
            stdoutBuffer = String(stdoutBuffer[stdoutBuffer.index(after: newlineIndex)...])
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            handleFrame(frame)
        }
    }

    private func handleFrame(_ frame: [String: Any]) {
        // Response (has `id` and either `result` or `error`)
        if let id = frame["id"] as? Int,
           let cont = pendingRequests.removeValue(forKey: id) {
            if let error = frame["error"] as? [String: Any] {
                let code = error["code"] as? Int ?? -1
                let message = error["message"] as? String ?? "unknown"
                cont.resume(throwing: CodexAppServerError.rpcError(code: code, message: message))
            } else if let result = frame["result"] as? [String: Any] {
                cont.resume(returning: result)
            } else {
                cont.resume(returning: [:])
            }
            return
        }

        // Notification (has `method`, no matching `id`)
        guard let method = frame["method"] as? String else { return }
        let params = frame["params"] as? [String: Any] ?? [:]
        handleNotification(method: method, params: params)
    }

    private func handleNotification(method: String, params: [String: Any]) {
        // Most thread-bound notifications carry a top-level threadId. Route
        // them to the right per-sibling callback.
        let threadID = params["threadId"] as? String

        switch method {
        case "item/agentMessage/delta":
            // {threadId, turnId, itemId, delta}
            if let tid = threadID,
               let handler = threadEventHandlers[tid],
               let delta = params["delta"] as? String {
                handler(.agentMessageDelta(delta))
            }

        case "turn/started":
            // {threadId, turn: {id, status, ...}}
            if let tid = threadID,
               let turn = params["turn"] as? [String: Any],
               let turnID = turn["id"] as? String {
                activeTurnIDs[tid] = turnID
                threadRunning[tid] = true
            }

        case "item/completed":
            // {threadId, turnId, item: {type, ...}}
            guard let tid = threadID,
                  let handler = threadEventHandlers[tid],
                  let item = params["item"] as? [String: Any] else { return }
            let itemType = (item["type"] as? String) ?? ""
            switch itemType {
            case "agentMessage", "agent_message", "message":
                let text = (item["text"] as? String)
                    ?? extractTextBlocks(from: item["content"])
                if !text.isEmpty {
                    handler(.agentMessageComplete(text))
                }
            case "commandExecution", "command_execution", "shell_command":
                let cmd = (item["command"] as? String)
                    ?? ((item["command"] as? [String])?.joined(separator: " ") ?? "")
                let output = (item["aggregatedOutput"] as? String)
                    ?? (item["aggregated_output"] as? String)
                if !cmd.isEmpty {
                    handler(.shellCommand(command: cmd, output: output))
                }
            case "fileChange", "file_change":
                if let changes = item["changes"] as? [[String: Any]] {
                    let paths = changes.compactMap { $0["path"] as? String }
                    let kinds = changes.map { change -> String in
                        if let kind = change["kind"] as? String { return kind }
                        if let kind = change["kind"] as? [String: Any],
                           let type = kind["type"] as? String {
                            return type == "update" ? "edit" : type
                        }
                        return "edit"
                    }
                    if !paths.isEmpty {
                        handler(.fileChange(paths: paths, kinds: kinds))
                    }
                }
            default:
                break
            }

        case "turn/completed":
            // Terminal — surface whatever assembled text the turn produced.
            // The notification body has {threadId, turn: {id, status, ...}}.
            if let tid = threadID, let handler = threadEventHandlers[tid] {
                let turn = params["turn"] as? [String: Any]
                if let turnID = turn?["id"] as? String,
                   activeTurnIDs[tid] == turnID {
                    activeTurnIDs.removeValue(forKey: tid)
                }
                let status = (turn?["status"] as? String) ?? "completed"
                if status == "failed" {
                    let error = turn?["error"] as? [String: Any]
                    let message = (error?["message"] as? String) ?? "Codex turn failed"
                    handler(.turnFailed(message: message))
                } else if status == "interrupted" {
                    handler(.turnFailed(message: "Codex turn was interrupted."))
                } else {
                    handler(.turnCompleted(finalText: ""))
                }
            }

        case "turn/failed", "error":
            if let tid = threadID, let handler = threadEventHandlers[tid] {
                let message = (params["message"] as? String)
                    ?? ((params["error"] as? [String: Any])?["message"] as? String)
                    ?? "Codex turn failed"
                handler(.turnFailed(message: message))
            }

        default:
            // Useful for diagnosis: thread/started, turn/started,
            // thread/tokenUsage/updated, account/rateLimits/updated, etc.
            // Comment in if you need to see notifications you're not handling.
            // print("📨 codex notification: \(method)")
            break
        }
    }

    private func extractTextBlocks(from content: Any?) -> String {
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.compactMap { block -> String? in
            guard let t = block["type"] as? String,
                  t == "output_text" || t == "text" else { return nil }
            return block["text"] as? String
        }.joined()
    }
}
