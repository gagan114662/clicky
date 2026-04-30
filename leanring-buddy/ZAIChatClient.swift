//
//  ZAIChatClient.swift
//  leanring-buddy
//
//  Optional direct Z.ai provider for fast text and screenshot turns.
//  Enabled only when runtime config selects provider "zai".
//

import Foundation

enum ZAIChatClientError: Error, LocalizedError {
    case notConfigured
    case invalidResponse
    case emptyResponse
    case apiError(statusCode: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Z.ai is not configured. Set AIProvider=zai and ZAIAPIKey."
        case .invalidResponse:
            return "Z.ai returned an invalid response."
        case .emptyResponse:
            return "Z.ai returned an empty response."
        case .apiError(let statusCode, let body):
            return "Z.ai API error (\(statusCode)): \(body)"
        }
    }
}

final class ZAIChatClient: AnthropicChatClient {
    private static let defaultEndpoint = "https://api.z.ai/api/coding/paas/v4/chat/completions"
    private static let defaultTextModel = "glm-4.5"
    private static let defaultVisionModel = "glm-4.5v"

    private let apiKey: String
    private let endpointURL: URL
    private let textModel: String
    private let visionModel: String
    var model: String
    private let session: URLSession

    init(
        apiKey: String,
        endpointURL: URL = URL(string: ZAIChatClient.defaultEndpoint)!,
        selectedModel: String,
        textModel: String = ZAIChatClient.defaultTextModel,
        visionModel: String = ZAIChatClient.defaultVisionModel,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.endpointURL = endpointURL
        self.model = selectedModel
        self.textModel = textModel
        self.visionModel = visionModel
        self.session = session
    }

    static func configuredIfEnabled(selectedModel: String) -> ZAIChatClient? {
        guard let provider = runtimeString(
            defaultsKeys: ["AIProvider"],
            infoKeys: ["AIProvider"],
            environmentKeys: ["IPOP_AI_PROVIDER", "AI_PROVIDER"]
        )?.lowercased(),
              provider == "zai" || provider == "z.ai" else {
            return nil
        }

        guard let apiKey = runtimeString(
            defaultsKeys: ["ZAIAPIKey"],
            infoKeys: ["ZAIAPIKey"],
            environmentKeys: ["IPOP_ZAI_API_KEY", "ZAI_API_KEY"]
        ) else {
            return nil
        }

        let endpointString = runtimeString(
            defaultsKeys: ["ZAIEndpointURL"],
            infoKeys: ["ZAIEndpointURL"],
            environmentKeys: ["IPOP_ZAI_ENDPOINT_URL", "ZAI_ENDPOINT_URL"]
        ) ?? defaultEndpoint

        guard let endpointURL = URL(string: endpointString) else { return nil }

        let textModel = runtimeString(
            defaultsKeys: ["ZAITextModel"],
            infoKeys: ["ZAITextModel"],
            environmentKeys: ["IPOP_ZAI_TEXT_MODEL", "ZAI_TEXT_MODEL"]
        ) ?? defaultTextModel

        let visionModel = runtimeString(
            defaultsKeys: ["ZAIVisionModel"],
            infoKeys: ["ZAIVisionModel"],
            environmentKeys: ["IPOP_ZAI_VISION_MODEL", "ZAI_VISION_MODEL"]
        ) ?? defaultVisionModel

        return ZAIChatClient(
            apiKey: apiKey,
            endpointURL: endpointURL,
            selectedModel: selectedModel,
            textModel: textModel,
            visionModel: visionModel
        )
    }

    nonisolated static func resolvedModel(
        selectedModel: String,
        hasImages: Bool,
        textModel: String = defaultTextModel,
        visionModel: String = defaultVisionModel
    ) -> String {
        if selectedModel.lowercased().hasPrefix("glm-") {
            return selectedModel
        }
        return hasImages ? visionModel : textModel
    }

    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()
        let request = try makeRequest(
            images: images,
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt
        )

        let payloadMB = Double(request.httpBody?.count ?? 0) / 1_048_576.0
        print("🌐 Z.ai streaming request: \(String(format: "%.1f", payloadMB))MB, \(images.count) image(s)")

        let (byteStream, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderPipelineError.invalidResponse(provider: "Z.ai")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            var errorLines: [String] = []
            for try await line in byteStream.lines {
                errorLines.append(line)
            }
            throw ProviderPipelineError.apiError(
                provider: "Z.ai",
                statusCode: httpResponse.statusCode,
                retryAfterSeconds: Self.retryAfterSeconds(from: httpResponse),
                body: errorLines.joined(separator: "\n")
            )
        }

        var accumulatedResponseText = ""
        for try await line in byteStream.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }

            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let firstChoice = choices.first,
                  let delta = firstChoice["delta"] as? [String: Any] else {
                continue
            }

            if let textChunk = delta["content"] as? String, !textChunk.isEmpty {
                accumulatedResponseText += textChunk
                await onTextChunk(accumulatedResponseText)
            }
        }

        guard !accumulatedResponseText.isEmpty else {
            throw ProviderPipelineError.emptyResponse(provider: "Z.ai")
        }

        return (text: accumulatedResponseText, duration: Date().timeIntervalSince(startTime))
    }

    private func makeRequest(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String
    ) throws -> URLRequest {
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("en-US,en", forHTTPHeaderField: "Accept-Language")

        var messages: [[String: Any]] = [
            ["role": "system", "content": adaptedSystemPrompt(systemPrompt)]
        ]

        for (userPlaceholder, assistantResponse) in conversationHistory {
            messages.append(["role": "user", "content": userPlaceholder])
            messages.append(["role": "assistant", "content": assistantResponse])
        }

        if images.isEmpty {
            messages.append(["role": "user", "content": userPrompt])
        } else {
            var contentBlocks: [[String: Any]] = []
            for image in images {
                let mediaType = detectImageMediaType(for: image.data)
                let dataURL = "data:\(mediaType);base64,\(image.data.base64EncodedString())"
                contentBlocks.append([
                    "type": "image_url",
                    "image_url": ["url": dataURL]
                ])
                contentBlocks.append([
                    "type": "text",
                    "text": image.label
                ])
            }
            contentBlocks.append(["type": "text", "text": userPrompt])
            messages.append(["role": "user", "content": contentBlocks])
        }

        let body: [String: Any] = [
            "model": Self.resolvedModel(
                selectedModel: model,
                hasImages: !images.isEmpty,
                textModel: textModel,
                visionModel: visionModel
            ),
            "messages": messages,
            "max_tokens": 1024,
            "temperature": 0.1,
            "stream": true,
            "thinking": ["type": "disabled"]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func adaptedSystemPrompt(_ systemPrompt: String) -> String {
        systemPrompt + """

        z.ai provider compatibility:
        - if you use mac action tags, output only this exact bracket grammar: [OPEN_APP:Name] [QUIT_APP:Name] [CLICK:Target] [TYPE:literal text] [KEY:cmd+n] [SCROLL:down].
        - do not output xml, json, markdown fences, LAUNCH(...), CLICK(box=...), or tool-call shaped text for mac actions.
        - never emit no-op tags like [CLICK:none]. omit the action instead.
        - for creating a note, prefer [OPEN_APP:Notes] [KEY:cmd+n] [TYPE:literal note text].
        - if the user asks for a notes/action task and the tags fully complete it, output only the tags.
        """
    }

    private func detectImageMediaType(for imageData: Data) -> String {
        let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
        if [UInt8](imageData.prefix(4)) == pngSignature {
            return "image/png"
        }
        return "image/jpeg"
    }

    private static func retryAfterSeconds(from response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }

        if let seconds = TimeInterval(value) {
            return seconds
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        guard let retryDate = formatter.date(from: value) else { return nil }
        return max(0, retryDate.timeIntervalSinceNow)
    }

    private static func runtimeString(
        defaultsKeys: [String],
        infoKeys: [String],
        environmentKeys: [String]
    ) -> String? {
        for key in environmentKeys {
            if let value = ProcessInfo.processInfo.environment[key]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }

        for key in defaultsKeys {
            if let value = UserDefaults.standard.string(forKey: key)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }

        for key in infoKeys {
            if let value = AppBundleConfiguration.stringValue(forKey: key) {
                return value
            }
        }

        return nil
    }
}
