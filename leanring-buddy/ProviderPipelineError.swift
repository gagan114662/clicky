//
//  ProviderPipelineError.swift
//  leanring-buddy
//
//  Normalized provider errors so the orchestration layer can distinguish
//  retryable rate limits/timeouts/parse failures from hard failures.
//

import Foundation

enum ProviderPipelineError: Error, LocalizedError {
    case invalidResponse(provider: String)
    case emptyResponse(provider: String)
    case apiError(provider: String, statusCode: Int, retryAfterSeconds: TimeInterval?, body: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let provider):
            return "\(provider) returned an invalid response."
        case .emptyResponse(let provider):
            return "\(provider) returned an empty response."
        case .apiError(let provider, let statusCode, _, let body):
            return "\(provider) API error (\(statusCode)): \(body)"
        }
    }

    var statusCode: Int? {
        guard case .apiError(_, let statusCode, _, _) = self else { return nil }
        return statusCode
    }

    var retryAfterSeconds: TimeInterval? {
        guard case .apiError(_, _, let retryAfterSeconds, _) = self else { return nil }
        return retryAfterSeconds
    }
}
