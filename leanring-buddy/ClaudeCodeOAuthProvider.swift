//
//  ClaudeCodeOAuthProvider.swift
//  leanring-buddy
//
//  Reads the Claude Code OAuth token from the macOS Keychain so ipop.ai can
//  call the Anthropic API directly without needing a separate API key.
//  Claude Code stores its credentials under the "Claude Code-credentials"
//  keychain service after the user runs `claude login`.
//

import Foundation
import Security

enum ClaudeCodeOAuthError: Error, LocalizedError {
    case credentialsNotFound
    case credentialsParseFailed

    var errorDescription: String? {
        switch self {
        case .credentialsNotFound:
            return "Claude Code credentials not found in Keychain. Run 'claude login' in Terminal first."
        case .credentialsParseFailed:
            return "Failed to parse Claude Code credentials from Keychain."
        }
    }
}

struct ClaudeCodeOAuthProvider {
    /// Returns true when Claude Code credentials exist in the Keychain.
    /// Use this to decide whether to use OAuth or fall back to the API proxy.
    static func isAvailable() -> Bool {
        return (try? readAccessToken()) != nil
    }

    /// Reads the current OAuth access token from the macOS Keychain.
    /// Claude Code refreshes this token automatically in the background, so
    /// reading it fresh each request ensures we always get the valid token.
    static func readAccessToken() throws -> String {
        guard let rawData = readKeychainData() else {
            throw ClaudeCodeOAuthError.credentialsNotFound
        }

        guard let parsedJSON = try? JSONSerialization.jsonObject(with: rawData) as? [String: Any],
              let oauthSection = parsedJSON["claudeAiOauth"] as? [String: Any],
              let accessToken = oauthSection["accessToken"] as? String else {
            throw ClaudeCodeOAuthError.credentialsParseFailed
        }

        return accessToken
    }

    private static func readKeychainData() -> Data? {
        let keychainQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var keychainResult: AnyObject?
        let status = SecItemCopyMatching(keychainQuery as CFDictionary, &keychainResult)

        guard status == errSecSuccess, let tokenData = keychainResult as? Data else {
            return nil
        }

        return tokenData
    }
}
