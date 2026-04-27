//
//  AnthropicChatClient.swift
//  leanring-buddy
//
//  Shared protocol for anything that can answer Claude vision queries.
//  Implemented by ClaudeAPI (direct HTTP) and ClaudeCodeCLIClient (subprocess).
//

import Foundation

protocol AnthropicChatClient: AnyObject {
    var model: String { get set }

    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval)
}
