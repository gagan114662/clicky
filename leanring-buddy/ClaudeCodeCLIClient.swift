//
//  ClaudeCodeCLIClient.swift
//  leanring-buddy
//
//  Calls the `claude` CLI as a subprocess to answer vision queries using
//  the user's existing Claude Code subscription. Images are passed as
//  base64 JSON via stdin using the stream-json input format.
//

import Foundation

enum ClaudeCodeCLIError: Error, LocalizedError {
    case binaryNotFound
    case processLaunchFailed(Error)
    case noResponseReceived

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "Claude Code CLI not found at ~/.local/bin/claude or /usr/local/bin/claude."
        case .processLaunchFailed(let underlying):
            return "Failed to launch claude CLI: \(underlying.localizedDescription)"
        case .noResponseReceived:
            return "claude CLI exited without producing a response."
        }
    }
}

private final class ClaudeCodeCLIStreamState: @unchecked Sendable {
    private let lock = NSLock()
    private var hasResumed = false
    private var accumulatedResponseText = ""
    private var lineBuffer = ""

    func appendStdoutChunk(_ chunk: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }

        lineBuffer += chunk
        var snapshots: [String] = []

        while let newlineIndex = lineBuffer.firstIndex(of: "\n") {
            let line = String(lineBuffer[lineBuffer.startIndex..<newlineIndex])
            lineBuffer = String(lineBuffer[lineBuffer.index(after: newlineIndex)...])

            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let eventType = event["type"] as? String
            else { continue }

            if eventType == "assistant",
               let message = event["message"] as? [String: Any],
               let contentArray = message["content"] as? [[String: Any]] {
                let deltaText = contentArray.compactMap { block -> String? in
                    guard block["type"] as? String == "text" else { return nil }
                    return block["text"] as? String
                }.joined()

                if !deltaText.isEmpty {
                    accumulatedResponseText += deltaText
                    snapshots.append(accumulatedResponseText)
                }
            }

            if eventType == "result",
               accumulatedResponseText.isEmpty,
               let resultText = event["result"] as? String,
               !resultText.isEmpty {
                accumulatedResponseText = resultText
                snapshots.append(resultText)
            }
        }

        return snapshots
    }

    func finishIfNeeded() -> String? {
        lock.lock()
        defer { lock.unlock() }

        guard !hasResumed else { return nil }
        hasResumed = true
        return accumulatedResponseText
    }
}

/// Calls the claude CLI subprocess using the user's Claude Code subscription.
/// Supports vision (screenshots passed as base64 JSON) and streaming output.
final class ClaudeCodeCLIClient: AnthropicChatClient {
    var model: String

    private static let candidateBinaryPaths = [
        "\(NSHomeDirectory())/.local/bin/claude",
        "/usr/local/bin/claude",
        "/opt/homebrew/bin/claude",
        "/usr/bin/claude",
    ]

    init(model: String = "claude-sonnet-4-6") {
        self.model = model
    }

    static func findBinaryPath() -> String? {
        candidateBinaryPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func isAvailable() -> Bool {
        findBinaryPath() != nil
    }

    private func detectImageMediaType(for imageData: Data) -> String {
        let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
        if [UInt8](imageData.prefix(4)) == pngSignature { return "image/png" }
        return "image/jpeg"
    }

    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()

        guard let binaryPath = Self.findBinaryPath() else {
            throw ClaudeCodeCLIError.binaryNotFound
        }

        // Build the stdin JSON: one user message containing all images + history + prompt
        var contentBlocks: [[String: Any]] = []

        for image in images {
            contentBlocks.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": detectImageMediaType(for: image.data),
                    "data": image.data.base64EncodedString()
                ]
            ])
            contentBlocks.append(["type": "text", "text": image.label])
        }

        if !conversationHistory.isEmpty {
            let historyText = conversationHistory.map {
                "User: \($0.userPlaceholder)\nAssistant: \($0.assistantResponse)"
            }.joined(separator: "\n\n")
            contentBlocks.append(["type": "text", "text": "Previous conversation:\n\(historyText)\n\n"])
        }

        contentBlocks.append(["type": "text", "text": userPrompt])

        let inputEvent: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": contentBlocks]
        ]
        let stdinData = try JSONSerialization.data(withJSONObject: inputEvent)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--system-prompt", systemPrompt,
            "--model", model,
            "--tools", "",                        // no file/code tools — faster, vision-only
            "--permission-mode", "bypassPermissions",
            "--no-session-persistence",
        ]

        // Ensure the binary can find node/npm regardless of macOS app PATH
        var env = ProcessInfo.processInfo.environment
        let extraPaths = "\(NSHomeDirectory())/.local/bin:/usr/local/bin:/opt/homebrew/bin"
        env["PATH"] = extraPaths + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        process.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw ClaudeCodeCLIError.processLaunchFailed(error)
        }

        // Write the input then close stdin so the CLI knows the message is complete
        stdinPipe.fileHandleForWriting.write(stdinData)
        stdinPipe.fileHandleForWriting.closeFile()

        return try await withCheckedThrowingContinuation { continuation in
            let streamState = ClaudeCodeCLIStreamState()

            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
                print("🟥 claude stderr: \(chunk.trimmingCharacters(in: .whitespacesAndNewlines))")
            }

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }

                let snapshots = streamState.appendStdoutChunk(chunk)
                for snapshot in snapshots {
                    Task { @MainActor in onTextChunk(snapshot) }
                }
            }

            process.terminationHandler = { terminatedProcess in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                guard let accumulatedResponseText = streamState.finishIfNeeded() else { return }

                let duration = Date().timeIntervalSince(startTime)
                if accumulatedResponseText.isEmpty {
                    continuation.resume(throwing: ClaudeCodeCLIError.noResponseReceived)
                } else {
                    continuation.resume(returning: (text: accumulatedResponseText, duration: duration))
                }
            }
        }
    }
}
