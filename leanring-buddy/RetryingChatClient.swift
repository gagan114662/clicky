//
//  RetryingChatClient.swift
//  leanring-buddy
//
//  Retries only the provider call inside a turn. The transcript, screenshots,
//  routing decision, and conversation context are already captured by the time
//  this wrapper runs, so retries do not restart the whole workflow.
//

import Foundation

struct ChatProviderRetryDecision: Equatable {
    let reason: String
    let delaySeconds: TimeInterval
}

enum ChatProviderRetryPolicy {
    static let maxAttempts = 3

    private static let retryableHTTPStatusCodes: Set<Int> = [
        408, 409, 425, 429, 500, 502, 503, 504
    ]

    private static let retryableURLErrorCodes: Set<URLError.Code> = [
        .timedOut,
        .cannotFindHost,
        .cannotConnectToHost,
        .dnsLookupFailed,
        .networkConnectionLost,
        .notConnectedToInternet,
        .secureConnectionFailed,
        .cannotLoadFromNetwork
    ]

    nonisolated static func decision(for error: Error, attempt: Int) -> ChatProviderRetryDecision? {
        guard attempt < maxAttempts else { return nil }

        if error is CancellationError {
            return nil
        }

        if let providerError = error as? ProviderPipelineError {
            switch providerError {
            case .emptyResponse:
                return ChatProviderRetryDecision(
                    reason: "empty provider response",
                    delaySeconds: backoffDelay(for: attempt, retryAfterSeconds: nil)
                )
            case .invalidResponse:
                return ChatProviderRetryDecision(
                    reason: "provider response parse failure",
                    delaySeconds: backoffDelay(for: attempt, retryAfterSeconds: nil)
                )
            case .apiError(_, let statusCode, let retryAfterSeconds, _):
                guard retryableHTTPStatusCodes.contains(statusCode) else { return nil }
                let reason = statusCode == 429 ? "rate limited" : "temporary HTTP \(statusCode)"
                return ChatProviderRetryDecision(
                    reason: reason,
                    delaySeconds: backoffDelay(for: attempt, retryAfterSeconds: retryAfterSeconds)
                )
            }
        }

        if let urlError = error as? URLError,
           retryableURLErrorCodes.contains(urlError.code) {
            return ChatProviderRetryDecision(
                reason: "network timeout/interruption",
                delaySeconds: backoffDelay(for: attempt, retryAfterSeconds: nil)
            )
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain,
           retryableURLErrorCodes.contains(URLError.Code(rawValue: nsError.code)) {
            return ChatProviderRetryDecision(
                reason: "network timeout/interruption",
                delaySeconds: backoffDelay(for: attempt, retryAfterSeconds: nil)
            )
        }

        if retryableHTTPStatusCodes.contains(nsError.code) {
            let retryAfterSeconds = nsError.userInfo["RetryAfterSeconds"] as? TimeInterval
            let reason = nsError.code == 429 ? "rate limited" : "temporary HTTP \(nsError.code)"
            return ChatProviderRetryDecision(
                reason: reason,
                delaySeconds: backoffDelay(for: attempt, retryAfterSeconds: retryAfterSeconds)
            )
        }

        if case ClaudeCodeCLIError.noResponseReceived = error {
            return ChatProviderRetryDecision(
                reason: "provider response parse failure",
                delaySeconds: backoffDelay(for: attempt, retryAfterSeconds: nil)
            )
        }

        return nil
    }

    private nonisolated static func backoffDelay(
        for attempt: Int,
        retryAfterSeconds: TimeInterval?
    ) -> TimeInterval {
        if let retryAfterSeconds, retryAfterSeconds > 0 {
            return min(retryAfterSeconds, 8)
        }

        let base = pow(2.0, Double(max(0, attempt - 1))) * 0.75
        return min(base, 6)
    }
}

final class RetryingChatClient: AnthropicChatClient {
    private let wrapped: any AnthropicChatClient
    private let providerName: String

    var model: String {
        get { wrapped.model }
        set { wrapped.model = newValue }
    }

    init(_ wrapped: any AnthropicChatClient, providerName: String) {
        self.wrapped = wrapped
        self.providerName = providerName
    }

    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let workflowStart = Date()
        var attempt = 1
        var lastError: Error?

        while attempt <= ChatProviderRetryPolicy.maxAttempts {
            do {
                if attempt > 1 {
                    FileLogger.log("🔁 \(providerName) retry attempt \(attempt)/\(ChatProviderRetryPolicy.maxAttempts)")
                }

                let result = try await wrapped.analyzeImageStreaming(
                    images: images,
                    systemPrompt: systemPrompt,
                    conversationHistory: conversationHistory,
                    userPrompt: userPrompt,
                    onTextChunk: onTextChunk
                )
                return (text: result.text, duration: Date().timeIntervalSince(workflowStart))
            } catch {
                if error is CancellationError {
                    throw error
                }

                lastError = error
                guard let decision = ChatProviderRetryPolicy.decision(for: error, attempt: attempt) else {
                    throw error
                }

                FileLogger.log(
                    "⚠️ \(providerName) \(decision.reason); retrying in \(String(format: "%.1f", decision.delaySeconds))s"
                )
                try await Task.sleep(nanoseconds: UInt64(decision.delaySeconds * 1_000_000_000))
                attempt += 1
            }
        }

        throw lastError ?? ProviderPipelineError.emptyResponse(provider: providerName)
    }
}
