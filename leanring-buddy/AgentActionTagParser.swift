//
//  AgentActionTagParser.swift
//  leanring-buddy
//
//  Pure parser that turns Claude's chat response into a sequence of agent actions.
//  Used by ComputerUseAgent's tag-based loop (built on top of the free Claude
//  Code CLI chat path, since OAuth tokens cannot use Anthropic's tool_use API).
//

import Foundation

/// One concrete action the agent should perform on this turn.
/// Coordinates are in Claude's viewport space (top-left origin, in pixels of
/// whatever resolution we sent the screenshot at).
enum AgentAction: Equatable {
    case mouseMove(x: Int, y: Int)
    case click(x: Int, y: Int)
    case doubleClick(x: Int, y: Int)
    case rightClick(x: Int, y: Int)
    case drag(startX: Int, startY: Int, endX: Int, endY: Int)
    case type(text: String)
    case key(combo: String)
    case scroll(direction: ScrollDirection, amount: Int)
    case accessibilityClick(name: String)
    case openApp(name: String)
    case quitApp(name: String)
    case closeWindow
    case bash(command: String)
    case fileView(path: String)
    case fileCreate(path: String, contents: String)
    case fileReplace(path: String, oldString: String, newString: String)
    case upworkPreworkProof(summary: String)
    case wait(milliseconds: Int)
    case screenshot
    case done(finalMessage: String)

    enum ScrollDirection: String, Equatable {
        case up
        case down
    }
}

enum AgentActionTagParser {

    /// Parse Claude's text response into a sequence of agent actions.
    /// Unknown / malformed tags are ignored. Plain text outside tags is also
    /// ignored — only bracketed tag content drives behavior.
    static func parse(_ responseText: String) -> [AgentAction] {
        var actions: [AgentAction] = []
        var scanner = ResponseScanner(source: responseText)
        while let openBracketIndex = scanner.indexOfNext("[") {
            scanner.advance(past: openBracketIndex)
            // Find the matching close bracket. Quoted strings inside the tag
            // can contain `]`, so we must skip over balanced quotes.
            guard let closeBracketIndex = scanner.indexOfMatchingCloseBracket() else {
                break
            }
            let rawTagBody = String(scanner.source[scanner.cursor..<closeBracketIndex])
            scanner.cursor = scanner.source.index(after: closeBracketIndex)
            if let parsedAction = parseSingleTagBody(rawTagBody) {
                actions.append(parsedAction)
                if case .done = parsedAction {
                    // Anything after a [DONE] tag is meaningless for the loop.
                    break
                }
            }
        }
        return actions
    }

    /// Parses one tag body (text BETWEEN the [ and ]). Returns nil for unknown tags.
    private static func parseSingleTagBody(_ tagBody: String) -> AgentAction? {
        let trimmedBody = tagBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstSpaceIndex = trimmedBody.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
            // No-arg tag like [SCREENSHOT].
            return parseTagWithName(trimmedBody.uppercased(), arguments: "")
        }
        let tagName = String(trimmedBody[trimmedBody.startIndex..<firstSpaceIndex]).uppercased()
        let argumentsString = String(trimmedBody[trimmedBody.index(after: firstSpaceIndex)...])
            .trimmingCharacters(in: .whitespaces)
        return parseTagWithName(tagName, arguments: argumentsString)
    }

    private static func parseTagWithName(_ tagName: String, arguments: String) -> AgentAction? {
        switch tagName {
        case "MOUSE_MOVE", "MOVE":
            guard let (x, y) = parseTwoCoordinates(arguments) else { return nil }
            return .mouseMove(x: x, y: y)
        case "CLICK":
            guard let (x, y) = parseTwoCoordinates(arguments) else { return nil }
            return .click(x: x, y: y)
        case "DOUBLECLICK", "DOUBLE_CLICK":
            guard let (x, y) = parseTwoCoordinates(arguments) else { return nil }
            return .doubleClick(x: x, y: y)
        case "RIGHTCLICK", "RIGHT_CLICK":
            guard let (x, y) = parseTwoCoordinates(arguments) else { return nil }
            return .rightClick(x: x, y: y)
        case "DRAG", "CLICK_DRAG":
            guard let (startX, startY, endX, endY) = parseFourCoordinates(arguments) else { return nil }
            return .drag(startX: startX, startY: startY, endX: endX, endY: endY)
        case "AX_CLICK", "CLICK_NAME":
            let name = parseQuotedOrRawString(arguments)
            return name.isEmpty ? nil : .accessibilityClick(name: name)
        case "OPEN_APP", "LAUNCH_APP":
            let name = parseQuotedOrRawString(arguments)
            return name.isEmpty ? nil : .openApp(name: name)
        case "QUIT_APP":
            let name = parseQuotedOrRawString(arguments)
            return name.isEmpty ? nil : .quitApp(name: name)
        case "CLOSE_WINDOW", "CLOSE_FRONTMOST_WINDOW":
            return .closeWindow
        case "TYPE":
            // Argument is a quoted string OR raw text.
            let unquoted = parseQuotedOrRawString(arguments)
            return unquoted.isEmpty ? nil : .type(text: unquoted)
        case "KEY":
            return arguments.isEmpty ? nil : .key(combo: arguments)
        case "SCROLL":
            return parseScrollArguments(arguments)
        case "BASH":
            let unquoted = parseQuotedOrRawString(arguments)
            return unquoted.isEmpty ? nil : .bash(command: unquoted)
        case "FILE_VIEW":
            return arguments.isEmpty ? nil : .fileView(path: arguments)
        case "FILE_CREATE":
            return parseFileCreateArguments(arguments)
        case "FILE_REPLACE":
            return parseFileReplaceArguments(arguments)
        case "UPWORK_PREWORK_PROOF":
            let summary = parseQuotedOrRawString(arguments)
            return summary.isEmpty ? nil : .upworkPreworkProof(summary: summary)
        case "WAIT":
            return Int(arguments).map { .wait(milliseconds: $0) }
        case "SCREENSHOT":
            return .screenshot
        case "DONE":
            return .done(finalMessage: arguments)
        default:
            return nil
        }
    }

    // MARK: - Argument parsing helpers

    /// Parses "x,y" (with optional spaces) → (x, y).
    private static func parseTwoCoordinates(_ argumentsString: String) -> (Int, Int)? {
        let cleaned = argumentsString.replacingOccurrences(of: " ", with: "")
        let components = cleaned.split(separator: ",")
        guard components.count == 2,
              let x = Int(components[0]),
              let y = Int(components[1]) else { return nil }
        return (x, y)
    }

    /// Parses four integers from forms like "x1,y1 x2,y2" or "x1,y1 -> x2,y2".
    private static func parseFourCoordinates(_ argumentsString: String) -> (Int, Int, Int, Int)? {
        guard let regex = try? NSRegularExpression(pattern: #"-?\d+"#) else { return nil }
        let nsRange = NSRange(argumentsString.startIndex..., in: argumentsString)
        let numbers = regex.matches(in: argumentsString, range: nsRange).compactMap { match -> Int? in
            guard let range = Range(match.range, in: argumentsString) else { return nil }
            return Int(argumentsString[range])
        }
        guard numbers.count >= 4 else { return nil }
        return (numbers[0], numbers[1], numbers[2], numbers[3])
    }

    /// Strips one layer of surrounding quotes if present and unescapes \" and \\.
    private static func parseQuotedOrRawString(_ argumentsString: String) -> String {
        let trimmed = argumentsString.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.count >= 2 else {
            return trimmed
        }
        let inner = String(trimmed.dropFirst().dropLast())
        return inner
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
            .replacingOccurrences(of: "\\n", with: "\n")
    }

    /// "up 3", "down 5"
    private static func parseScrollArguments(_ argumentsString: String) -> AgentAction? {
        let parts = argumentsString.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 1,
              let direction = AgentAction.ScrollDirection(rawValue: String(parts[0]).lowercased()) else {
            return nil
        }
        let amount: Int = (parts.count >= 2) ? (Int(parts[1]) ?? 3) : 3
        return .scroll(direction: direction, amount: amount)
    }

    /// `path "contents"` — first whitespace-separated token is the path,
    /// then a quoted contents block.
    private static func parseFileCreateArguments(_ argumentsString: String) -> AgentAction? {
        guard let firstQuoteIndex = argumentsString.firstIndex(of: "\"") else {
            return nil
        }
        let path = String(argumentsString[argumentsString.startIndex..<firstQuoteIndex])
            .trimmingCharacters(in: .whitespaces)
        let quotedRemainder = String(argumentsString[firstQuoteIndex...])
        let contents = parseQuotedOrRawString(quotedRemainder)
        guard !path.isEmpty else { return nil }
        return .fileCreate(path: path, contents: contents)
    }

    /// `path "old" "new"` — path, then two quoted strings.
    private static func parseFileReplaceArguments(_ argumentsString: String) -> AgentAction? {
        guard let firstQuoteIndex = argumentsString.firstIndex(of: "\"") else {
            return nil
        }
        let path = String(argumentsString[argumentsString.startIndex..<firstQuoteIndex])
            .trimmingCharacters(in: .whitespaces)
        let remainder = String(argumentsString[firstQuoteIndex...])
        // Find the FIRST quoted string and the SECOND quoted string.
        guard let firstQuotedRange = findQuotedRange(in: remainder, startingAt: remainder.startIndex) else {
            return nil
        }
        let oldString = parseQuotedOrRawString(String(remainder[firstQuotedRange]))
        let afterFirstQuote = firstQuotedRange.upperBound
        guard afterFirstQuote < remainder.endIndex,
              let secondQuotedRange = findQuotedRange(in: remainder, startingAt: afterFirstQuote) else {
            return nil
        }
        let newString = parseQuotedOrRawString(String(remainder[secondQuotedRange]))
        guard !path.isEmpty, !oldString.isEmpty else { return nil }
        return .fileReplace(path: path, oldString: oldString, newString: newString)
    }

    /// Finds the next `"..."` substring (handling \" escapes) in `text`,
    /// starting from `startIndex`. Returns the inclusive range of the quotes.
    private static func findQuotedRange(in text: String, startingAt startIndex: String.Index) -> Range<String.Index>? {
        var current = startIndex
        while current < text.endIndex {
            if text[current] == "\"" {
                let openQuoteIndex = current
                var scanIndex = text.index(after: openQuoteIndex)
                while scanIndex < text.endIndex {
                    if text[scanIndex] == "\\" {
                        scanIndex = text.index(scanIndex, offsetBy: 2, limitedBy: text.endIndex) ?? text.endIndex
                        continue
                    }
                    if text[scanIndex] == "\"" {
                        return openQuoteIndex..<text.index(after: scanIndex)
                    }
                    scanIndex = text.index(after: scanIndex)
                }
                return nil  // unterminated quote
            }
            current = text.index(after: current)
        }
        return nil
    }
}

// MARK: - Bracket-aware scanner

/// Tracks position through a string while scanning for `[...]` tags. Knows how to
/// skip `]` inside quoted strings so `[TYPE "wrong]bracket"]` doesn't terminate
/// at the inner `]`.
private struct ResponseScanner {
    let source: String
    var cursor: String.Index

    init(source: String) {
        self.source = source
        self.cursor = source.startIndex
    }

    mutating func advance(past index: String.Index) {
        cursor = (index < source.endIndex) ? source.index(after: index) : source.endIndex
    }

    func indexOfNext(_ character: Character) -> String.Index? {
        var scanIndex = cursor
        while scanIndex < source.endIndex {
            if source[scanIndex] == character { return scanIndex }
            scanIndex = source.index(after: scanIndex)
        }
        return nil
    }

    /// Finds the matching `]` for an open `[` whose position is `cursor - 1`.
    /// Skips `]` characters inside quoted strings (handling `\"` escapes).
    func indexOfMatchingCloseBracket() -> String.Index? {
        var scanIndex = cursor
        var insideQuote = false
        while scanIndex < source.endIndex {
            let character = source[scanIndex]
            if character == "\\" {
                scanIndex = source.index(scanIndex, offsetBy: 2, limitedBy: source.endIndex) ?? source.endIndex
                continue
            }
            if character == "\"" {
                insideQuote.toggle()
            } else if character == "]", !insideQuote {
                return scanIndex
            }
            scanIndex = source.index(after: scanIndex)
        }
        return nil
    }
}
