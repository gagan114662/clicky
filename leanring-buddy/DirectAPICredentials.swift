//
//  DirectAPICredentials.swift
//  leanring-buddy
//
//  Add your own API keys here. These are read directly by the app
//  without needing the Cloudflare Worker proxy.
//  Claude calls go through the Claude Code CLI (see ClaudeCodeCLIClient.swift).
//

enum DirectAPICredentials {
    static let assemblyAIAPIKey = ""     // get one at assemblyai.com
    static let elevenLabsAPIKey = ""     // get one at elevenlabs.io
    static let elevenLabsVoiceID = "21m00Tcm4TlvDq8ikWAM"
}
