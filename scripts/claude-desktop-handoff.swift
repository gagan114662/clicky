#!/usr/bin/env swift

import Foundation

enum Mode: String {
    case review
    case battle
    case both

    var startMarker: String {
        switch self {
        case .review: return "<!-- CLAUDE_REVIEW_PROMPT_START -->"
        case .battle: return "<!-- CLAUDE_BATTLE_PROMPT_START -->"
        case .both: return "<!-- CLAUDE_BOTH_PROMPT_START -->"
        }
    }

    var endMarker: String {
        switch self {
        case .review: return "<!-- CLAUDE_REVIEW_PROMPT_END -->"
        case .battle: return "<!-- CLAUDE_BATTLE_PROMPT_END -->"
        case .both: return "<!-- CLAUDE_BOTH_PROMPT_END -->"
        }
    }
}

struct Options {
    var mode: Mode = .both
    var copyToClipboard = false
    var openClaude = false
    var promptPath = "docs/live-evals/claude-desktop-battle-test.md"
}

enum HandoffError: Error, CustomStringConvertible {
    case missingValue(String)
    case unknownArgument(String)
    case unknownMode(String)
    case markerNotFound(String)

    var description: String {
        switch self {
        case .missingValue(let flag):
            return "Missing value after \(flag)"
        case .unknownArgument(let argument):
            return "Unknown argument: \(argument)"
        case .unknownMode(let mode):
            return "Unknown mode: \(mode)"
        case .markerNotFound(let marker):
            return "Could not find marker \(marker)"
        }
    }
}

func printUsage() {
    print("""
    Usage:
      scripts/claude-desktop-handoff.swift --mode both
      scripts/claude-desktop-handoff.swift --mode review --copy
      scripts/claude-desktop-handoff.swift --mode battle --copy --open-claude

    Modes:
      review  Code review prompt only.
      battle  Live Cowork-style battle test prompt only.
      both    Combined review + battle test prompt.
    """)
}

func parseOptions(_ arguments: [String]) throws -> Options {
    var options = Options()
    var index = 0

    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--mode":
            index += 1
            guard index < arguments.count else { throw HandoffError.missingValue(argument) }
            guard let mode = Mode(rawValue: arguments[index]) else {
                throw HandoffError.unknownMode(arguments[index])
            }
            options.mode = mode
        case "--copy":
            options.copyToClipboard = true
        case "--open-claude":
            options.openClaude = true
        case "--prompt":
            index += 1
            guard index < arguments.count else { throw HandoffError.missingValue(argument) }
            options.promptPath = arguments[index]
        case "--help", "-h":
            printUsage()
            exit(0)
        default:
            throw HandoffError.unknownArgument(argument)
        }
        index += 1
    }

    return options
}

func extractPrompt(from text: String, mode: Mode) throws -> String {
    guard let startRange = text.range(of: mode.startMarker) else {
        throw HandoffError.markerNotFound(mode.startMarker)
    }
    guard let endRange = text.range(of: mode.endMarker) else {
        throw HandoffError.markerNotFound(mode.endMarker)
    }

    return text[startRange.upperBound..<endRange.lowerBound]
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func runProcess(_ executable: String, _ arguments: [String], stdin: String? = nil) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments

    if let stdin {
        let inputPipe = Pipe()
        process.standardInput = inputPipe
        try process.run()
        try inputPipe.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
        try inputPipe.fileHandleForWriting.close()
    } else {
        try process.run()
    }

    process.waitUntilExit()
    if process.terminationStatus != 0 {
        throw NSError(
            domain: "ClaudeDesktopHandoff",
            code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: "\(executable) exited \(process.terminationStatus)"]
        )
    }
}

do {
    let options = try parseOptions(Array(CommandLine.arguments.dropFirst()))
    let promptDocument = try String(contentsOfFile: options.promptPath, encoding: .utf8)
    let prompt = try extractPrompt(from: promptDocument, mode: options.mode)

    if options.copyToClipboard {
        try runProcess("/usr/bin/pbcopy", [], stdin: prompt)
        print("Copied \(options.mode.rawValue) prompt to clipboard.")
    } else {
        print(prompt)
    }

    if options.openClaude {
        try runProcess("/usr/bin/open", ["-a", "Claude"])
        print("Opened Claude Desktop.")
    }
} catch {
    fputs("claude-desktop-handoff error: \(error)\n", stderr)
    printUsage()
    exit(1)
}
