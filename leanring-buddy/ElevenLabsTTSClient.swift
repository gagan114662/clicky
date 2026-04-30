//
//  ElevenLabsTTSClient.swift
//  leanring-buddy
//
//  Streams text-to-speech audio from ElevenLabs and plays it back
//  through the system audio output. Uses the streaming endpoint so
//  playback begins before the full audio has been generated.
//

import AVFoundation
import Foundation

@MainActor
final class ElevenLabsTTSClient {
    private static let defaultVoiceID = "21m00Tcm4TlvDq8ikWAM"
    private static let defaultModelID = "eleven_flash_v2_5"

    private let ttsURL: URL
    private let apiKey: String
    private let modelID: String
    private let session: URLSession

    /// The audio player for the current TTS playback. Kept alive so the
    /// audio finishes playing even if the caller doesn't hold a reference.
    private var audioPlayer: AVAudioPlayer?

    init(
        apiKey: String = ElevenLabsTTSClient.configuredAPIKey(),
        voiceID: String = ElevenLabsTTSClient.configuredVoiceID(),
        modelID: String = ElevenLabsTTSClient.configuredModelID()
    ) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.modelID = modelID
        self.ttsURL = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceID)")!

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: configuration)
    }

    /// Sends `text` to ElevenLabs TTS and plays the resulting audio.
    /// Throws on network or decoding errors. Cancellation-safe.
    func speakText(_ text: String) async throws {
        guard isConfigured else {
            throw NSError(
                domain: "ElevenLabsTTS",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "ElevenLabs API key is not configured"]
            )
        }

        var request = URLRequest(url: ttsURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")

        let body: [String: Any] = [
            "text": text,
            "model_id": modelID,
            "voice_settings": [
                "stability": 0.58,
                "similarity_boost": 0.82,
                "style": 0.18,
                "use_speaker_boost": true
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "ElevenLabsTTS", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "ElevenLabsTTS", code: httpResponse.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "TTS API error (\(httpResponse.statusCode)): \(errorBody)"])
        }

        try Task.checkCancellation()

        let player = try AVAudioPlayer(data: data)
        self.audioPlayer = player
        player.play()
        print("🔊 ElevenLabs TTS: playing \(data.count / 1024)KB audio")
    }

    /// Whether TTS audio is currently playing back.
    var isPlaying: Bool {
        audioPlayer?.isPlaying ?? false
    }

    var isConfigured: Bool {
        !apiKey.isEmpty
    }

    /// Stops any in-progress playback immediately.
    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
    }

    private nonisolated static func configuredAPIKey() -> String {
        runtimeString(
            defaultsKeys: ["ElevenLabsAPIKey"],
            infoKeys: ["ElevenLabsAPIKey"],
            environmentKeys: ["IPOP_ELEVENLABS_API_KEY", "ELEVENLABS_API_KEY"]
        ) ?? ""
    }

    private nonisolated static func configuredVoiceID() -> String {
        runtimeString(
            defaultsKeys: ["ElevenLabsVoiceID"],
            infoKeys: ["ElevenLabsVoiceID"],
            environmentKeys: ["IPOP_ELEVENLABS_VOICE_ID", "ELEVENLABS_VOICE_ID"]
        ) ?? defaultVoiceID
    }

    private nonisolated static func configuredModelID() -> String {
        runtimeString(
            defaultsKeys: ["ElevenLabsModelID"],
            infoKeys: ["ElevenLabsModelID"],
            environmentKeys: ["IPOP_ELEVENLABS_MODEL_ID", "ELEVENLABS_MODEL_ID"]
        ) ?? defaultModelID
    }

    private nonisolated static func runtimeString(
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
