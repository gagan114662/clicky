//
//  ActionTagParser.swift
//  leanring-buddy
//
//  Parses structured tags Claude embeds in its response text — currently
//  the [POINT:x,y:label:screenN] coordinate tag, with future native action
//  tags ([CLICK], [TYPE], [KEY], etc.) to be added in subsequent phases.
//
//  This file is the single source of truth for tag syntax so CompanionManager
//  doesn't need to know how the tag grammar works.
//

import CoreGraphics
import Foundation

/// Result of parsing a [POINT:...] tag from Claude's response.
struct PointingParseResult {
    /// The response text with the [POINT:...] tag removed — this is what gets spoken.
    let spokenText: String
    /// The parsed pixel coordinate, or nil if Claude said "none" or no tag was found.
    let coordinate: CGPoint?
    /// Short label describing the element (e.g. "run button"), or "none".
    let elementLabel: String?
    /// Which screen the coordinate refers to (1-based), or nil to default to cursor screen.
    let screenNumber: Int?
}

/// Result of parsing the full set of structured tags Claude can emit:
/// `[POINT:...]`, `[OPEN_APP:...]`, `[QUIT_APP:...]`, `[CLICK:...]`,
/// `[TYPE:...]`, `[KEY:...]`, `[SCROLL:...]`.
///
/// `actions` is in the order Claude emitted the tags, so they can be
/// executed sequentially.
struct CompoundActionParseResult {
    /// Response text with ALL tags stripped — what gets spoken.
    let spokenText: String
    /// Pointing tag (if any) — drives the existing cursor-flight animation.
    let pointResult: PointingParseResult
    /// Action tags in source order, ready to feed into LocalIntentExecutor.
    let actions: [LocalIntent]
}

/// Namespace for parsing structured tags Claude embeds in its responses.
/// Behaviour is intentionally identical to the previous implementation that
/// lived as `CompanionManager.parsePointingCoordinates` — this is a phase 1
/// relocation only, no logic changes.
enum ActionTagParser {

    /// Parses a [POINT:x,y:label:screenN] or [POINT:none] tag from the end of Claude's response.
    /// Returns the spoken text (tag removed) and the optional coordinate + label + screen number.
    static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        // Match [POINT:none] or [POINT:123,456:label] or [POINT:123,456:label:screen2]
        let pattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)) else {
            // No tag found at all
            return PointingParseResult(
                spokenText: responseText.trimmingCharacters(in: .whitespacesAndNewlines),
                coordinate: nil,
                elementLabel: nil,
                screenNumber: nil
            )
        }

        // Remove the tag from the spoken text
        let tagRange = Range(match.range, in: responseText)!
        let spokenText = String(responseText[..<tagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if it's [POINT:none]
        guard match.numberOfRanges >= 3,
              let xRange = Range(match.range(at: 1), in: responseText),
              let yRange = Range(match.range(at: 2), in: responseText),
              let x = Double(responseText[xRange]),
              let y = Double(responseText[yRange]) else {
            return PointingParseResult(spokenText: spokenText, coordinate: nil, elementLabel: "none", screenNumber: nil)
        }

        var elementLabel: String? = nil
        if match.numberOfRanges >= 4, let labelRange = Range(match.range(at: 3), in: responseText) {
            elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
        }

        var screenNumber: Int? = nil
        if match.numberOfRanges >= 5, let screenRange = Range(match.range(at: 4), in: responseText) {
            screenNumber = Int(responseText[screenRange])
        }

        return PointingParseResult(
            spokenText: spokenText,
            coordinate: CGPoint(x: x, y: y),
            elementLabel: elementLabel,
            screenNumber: screenNumber
        )
    }

    // MARK: - Compound action tags

    /// Parses every supported tag from Claude's response and returns:
    /// 1) the cleaned-up text to speak,
    /// 2) the optional pointing result (existing flow),
    /// 3) the sequence of executable LocalIntent actions.
    ///
    /// Tags supported: [OPEN_APP:Name], [QUIT_APP:Name], [CLICK:Target],
    /// [TYPE:Literal text], [KEY:cmd+s], [SCROLL:up|down|left|right],
    /// plus the existing [POINT:x,y:label].
    static func parseAllActionTags(from responseText: String) -> CompoundActionParseResult {
        let nsResponse = responseText as NSString
        var actionMatches: [(range: NSRange, intent: LocalIntent)] = []

        // Each pattern captures the tag's argument in group 1. The argument
        // may contain anything except `]`, which means the inner brackets
        // would break parsing — Claude is told in the prompt not to use
        // brackets inside tag values.
        let patterns: [(name: String, regex: String)] = [
            ("OPEN_APP", #"\[OPEN_APP:([^\]]+)\]"#),
            ("QUIT_APP", #"\[QUIT_APP:([^\]]+)\]"#),
            ("CLICK", #"\[CLICK:([^\]]+)\]"#),
            ("TYPE", #"\[TYPE:([^\]]+)\]"#),
            ("KEY", #"\[KEY:([^\]]+)\]"#),
            ("SCROLL", #"\[SCROLL:([^\]]+)\]"#),
        ]

        for (tagName, regexPattern) in patterns {
            // Case-insensitive — Claude's "all lowercase casual" style means
            // it might emit [open_app:freeform] instead of [OPEN_APP:Freeform].
            // Both are valid; the parser shouldn't care.
            guard let regex = try? NSRegularExpression(pattern: regexPattern, options: [.caseInsensitive]) else { continue }
            let allMatches = regex.matches(
                in: responseText,
                range: NSRange(location: 0, length: nsResponse.length)
            )
            for match in allMatches {
                guard match.numberOfRanges >= 2 else { continue }
                let argument = nsResponse
                    .substring(with: match.range(at: 1))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !argument.isEmpty else { continue }
                if let intent = makeIntent(forTagName: tagName, argument: argument) {
                    actionMatches.append((range: match.range, intent: intent))
                }
            }
        }

        // Sort by source position so tags execute in the order Claude wrote
        // them ("[OPEN_APP:Notes] [CLICK:New Note] [TYPE:hello]").
        actionMatches.sort { $0.range.location < $1.range.location }

        // Strip every action tag from the response, working back-to-front
        // so the indices we collected stay valid as we delete.
        let mutableText = NSMutableString(string: responseText)
        for range in actionMatches.map({ $0.range }).sorted(by: { $0.location > $1.location }) {
            mutableText.replaceCharacters(in: range, with: "")
        }
        let textWithActionTagsRemoved = mutableText as String

        // Now run the existing point parser on the action-cleaned text.
        let pointResult = parsePointingCoordinates(from: textWithActionTagsRemoved)

        return CompoundActionParseResult(
            spokenText: pointResult.spokenText,
            pointResult: pointResult,
            actions: actionMatches.map { $0.intent }
        )
    }

    /// Maps a tag name + raw argument string to a typed `LocalIntent`.
    /// Returns nil for malformed arguments (e.g. an unknown scroll direction)
    /// so we silently drop them rather than executing junk.
    private static func makeIntent(forTagName tagName: String, argument: String) -> LocalIntent? {
        switch tagName {
        case "OPEN_APP":
            return .launchOrActivateApp(name: argument)
        case "QUIT_APP":
            return .quitApp(name: argument)
        case "CLICK":
            return .clickByName(targetName: argument)
        case "TYPE":
            // Preserve whatever casing/whitespace Claude emitted inside [TYPE:...]
            return .typeText(text: argument)
        case "KEY":
            return .pressKeyChord(chord: argument.lowercased())
        case "SCROLL":
            switch argument.lowercased() {
            case "up": return .scroll(direction: .up)
            case "down": return .scroll(direction: .down)
            case "left": return .scroll(direction: .left)
            case "right": return .scroll(direction: .right)
            default: return nil
            }
        default:
            return nil
        }
    }
}
