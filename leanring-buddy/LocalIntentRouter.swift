//
//  LocalIntentRouter.swift
//  leanring-buddy
//
//  Recognizes voice transcripts as deterministic Mac actions and dispatches
//  them via macOS-native APIs in ~50-200ms — no LLM, no screenshot, no
//  TTS round-trip. The grammar is verb-driven and intentionally GENERAL:
//  "click X" / "type X" / "press X" / "scroll up" / "open X" all work for
//  arbitrary X, not a hardcoded enumeration.
//
//  Anything we can't classify deterministically falls through to the
//  existing Claude pipeline so the user always gets some response.
//

import Foundation

/// Direction of a scroll-wheel synthesis.
enum ScrollDirection: Equatable {
    case up
    case down
    case left
    case right
}

/// One concrete action that can be executed locally without a Claude call.
enum LocalIntent: Equatable {
    /// Launch the named app (or activate it if already running).
    case launchOrActivateApp(name: String)
    /// Send a graceful Quit to the named app.
    case quitApp(name: String)
    /// Close the frontmost window without quitting the app.
    case closeFrontmostWindow
    /// Activate the named app, then close its frontmost window without quitting it.
    case closeWindowInApp(name: String)
    /// Open Calculator and enter a simple arithmetic expression.
    case calculateInCalculator(expression: String)
    /// Create a new Apple Notes note with the given text.
    case createNote(text: String)
    /// Click any element in the frontmost app's accessibility tree whose
    /// title matches `targetName`. Generic — covers menu bar items, buttons,
    /// menu items, links, checkboxes, anything labeled.
    case clickByName(targetName: String)
    /// Type a literal string at the current keyboard focus.
    case typeText(text: String)
    /// Synthesize a key chord (modifiers + a single key) at the current focus.
    /// `chord` is the human-readable form, e.g. "cmd+s", "cmd+shift+t".
    case pressKeyChord(chord: String)
    /// Scroll the wheel at the current cursor position.
    case scroll(direction: ScrollDirection)
    /// Speak the current local time.
    case currentTime
    /// No fast path — caller falls through to the LLM pipeline.
    case unmatched
}

enum LocalIntentRouter {

    // MARK: - Public entry point

    static func route(transcript: String) -> LocalIntent {
        let normalized = normalize(transcript)
        guard !normalized.isEmpty else { return .unmatched }

        // Agent-session requests are handled before local intents in
        // CompanionManager. If Codex is unavailable, leave them for Claude
        // instead of treating "launch two parallel cortex sessions" as an
        // app named "two parallel cortex sessions".
        if looksLikeAgentSessionRequest(normalized) {
            return .unmatched
        }

        // Order: most-specific first so e.g. "scroll up" doesn't get
        // misparsed as a generic verb-object pair.

        if let direction = scrollDirection(from: normalized) {
            return .scroll(direction: direction)
        }

        if isCurrentTimeQuery(normalized) {
            return .currentTime
        }

        if let calculatorExpression = parseCalculatorExpressionCommand(normalized) {
            return .calculateInCalculator(expression: calculatorExpression)
        }

        if let targetAppName = parseCloseWindowInAppCommand(normalized) {
            return .closeWindowInApp(name: targetAppName)
        }

        if isCloseFrontmostWindowCommand(normalized) {
            return .closeFrontmostWindow
        }

        if parseCreateNoteCommand(normalized) != nil {
            // Creating or editing Apple Notes persists user content. Keep
            // the deterministic router out of this path so the super-app /
            // agent confirmation layer can preview the note instead of
            // silently writing it.
            return .unmatched
        }

        // "navigate to <X>" / "go to the <X> icon" / "show me the <X> menu"
        // — these are click intents on UI elements, not app launches. Match
        // them BEFORE the loose-app-command parser so "go to apple icon"
        // doesn't get mis-routed as launching an app called "apple icon".
        if let navTargetName = parseNavigateOrShowCommand(normalized) {
            return .clickByName(targetName: navTargetName)
        }

        // LOOSE WORD-ORDER MATCHING for app commands. Voice transcripts often
        // come back with the verb at the end ("freeform open", "safari please")
        // or no verb at all (just the bare app name). Rather than enumerate
        // every word order, we scan the words for any open/quit/switch verb
        // and treat the rest as the app name.
        //
        // This runs BEFORE the strict verb-prefix matcher because a strict
        // match for "open" with junk after it would otherwise pre-empt this.
        if let looseAppIntent = parseLooseAppCommand(normalized) {
            return looseAppIntent
        }

        if let (verb, remainder) = splitLeadingVerb(in: normalized) {
            switch verb {
            case .click:
                if !remainder.isEmpty {
                    return .clickByName(targetName: remainder)
                }
            case .type:
                if !remainder.isEmpty {
                    return .typeText(text: preserveOriginalCasing(of: remainder, from: transcript))
                }
            case .press, .hit:
                // "press" / "hit" is ambiguous — could be a key chord
                // ("press cmd s") or a click target ("press the save
                // button"). Disambiguate by checking if the remainder
                // starts with a modifier word or names a known key.
                if let chord = parseKeyChord(remainder) {
                    return .pressKeyChord(chord: chord)
                }
                if !remainder.isEmpty {
                    return .clickByName(targetName: remainder)
                }
            case .open:
                // "open" is also ambiguous — could be an app launch
                // ("open Freeform") or a UI element click ("open the file
                // menu"). If the remainder ends with a UI noun ("menu",
                // "tab", "window", "panel"), treat as click. Otherwise
                // assume app.
                if endsWithUIElementNoun(remainder) {
                    return .clickByName(targetName: remainder)
                }
                if !remainder.isEmpty {
                    return .launchOrActivateApp(name: remainder)
                }
            case .launch, .start:
                if !remainder.isEmpty {
                    return .launchOrActivateApp(name: remainder)
                }
            case .switchTo, .focusOn, .goTo:
                if !remainder.isEmpty {
                    return .launchOrActivateApp(name: remainder)
                }
            case .quit, .close, .exit:
                if !remainder.isEmpty {
                    if verb == .close, let targetAppName = parseCloseWindowRemainder(remainder) {
                        return .closeWindowInApp(name: targetAppName)
                    }
                    return .quitApp(name: remainder)
                }
            }
        }

        return .unmatched
    }

    private static func isCloseFrontmostWindowCommand(_ normalized: String) -> Bool {
        let closePhrases = [
            "close this window",
            "close the window",
            "close current window",
            "close front window",
            "close active window"
        ]
        if closePhrases.contains(where: { normalized.contains($0) }) {
            return true
        }

        let words = Set(normalized.split(separator: " ").map(String.init))
        return words.contains("close")
            && words.contains("window")
            && (words.contains("this") || words.contains("current") || words.contains("active") || words.contains("frontmost"))
    }

    private static func parseCloseWindowInAppCommand(_ normalized: String) -> String? {
        guard normalized.hasPrefix("close "), normalized.contains("window") else {
            return nil
        }

        return parseCloseWindowRemainder(String(normalized.dropFirst("close ".count)))
    }

    private static func parseCloseWindowRemainder(_ remainder: String) -> String? {
        var candidate = remainder
        candidate = stripDeterminerPrefix(candidate)
        candidate = stripLeadingWindowQualifier(candidate)

        if candidate.hasPrefix("window in ") {
            candidate = String(candidate.dropFirst("window in ".count))
        } else if candidate.hasPrefix("window for ") {
            candidate = String(candidate.dropFirst("window for ".count))
        } else if candidate.hasPrefix("window of ") {
            candidate = String(candidate.dropFirst("window of ".count))
        } else if candidate.hasSuffix(" window") {
            candidate = String(candidate.dropLast(" window".count))
        } else {
            return nil
        }

        candidate = stripTrailingFillerAndPunctuation(stripDeterminerPrefix(candidate))
        let untargetedNames: Set<String> = ["", "window", "this", "current", "active", "front", "frontmost"]
        return untargetedNames.contains(candidate) ? nil : candidate
    }

    private static func stripLeadingWindowQualifier(_ text: String) -> String {
        var cleaned = text
        let prefixes = ["this ", "that ", "current ", "active ", "frontmost ", "front "]
        var didStrip = true
        while didStrip {
            didStrip = false
            for prefix in prefixes where cleaned.hasPrefix(prefix) {
                cleaned = String(cleaned.dropFirst(prefix.count))
                didStrip = true
            }
        }
        return cleaned
    }

    // MARK: - Verb table

    private enum Verb {
        case click
        case type
        case press
        case hit
        case open
        case launch
        case start
        case switchTo
        case focusOn
        case goTo
        case quit
        case close
        case exit
    }

    /// Ordered longest-prefix-first so e.g. "switch to " matches before "switch ".
    private static let verbPrefixes: [(prefix: String, verb: Verb)] = [
        ("switch over to ", .switchTo),
        ("switch to ", .switchTo),
        ("focus on ", .focusOn),
        ("go to ", .goTo),
        ("click on ", .click),
        ("click the ", .click),
        ("click ", .click),
        ("tap on ", .click),
        ("tap the ", .click),
        ("tap ", .click),
        ("select the ", .click),
        ("select ", .click),
        ("press the ", .press),
        ("press ", .press),
        ("hit the ", .hit),
        ("hit ", .hit),
        ("type out ", .type),
        ("type in ", .type),
        ("type ", .type),
        ("write out ", .type),
        ("write ", .type),
        ("open the ", .open),
        ("open ", .open),
        ("launch ", .launch),
        ("start ", .start),
        ("boot up ", .launch),
        ("fire up ", .launch),
        ("quit ", .quit),
        ("close ", .close),
        ("exit ", .exit),
        ("kill ", .quit),
        ("shut down ", .quit),
        ("bring up ", .switchTo),
    ]

    /// Returns the matched verb and the cleaned-up remainder (target/text/chord).
    private static func splitLeadingVerb(in normalized: String) -> (Verb, String)? {
        for (prefix, verb) in verbPrefixes {
            if normalized.hasPrefix(prefix) {
                let remainder = String(normalized.dropFirst(prefix.count))
                let cleaned = stripTrailingFillerAndPunctuation(stripDeterminerPrefix(remainder))
                return (verb, cleaned)
            }
        }
        return nil
    }

    // MARK: - Loose word-order app command parsing

    /// Common verbs that mean "launch/activate this app", regardless of
    /// where they appear in the sentence.
    private static let looseLaunchVerbWords: Set<String> = [
        "open", "launch", "start", "boot", "run", "fire",
    ]
    /// Common verbs that mean "quit this app".
    private static let looseQuitVerbWords: Set<String> = [
        "quit", "close", "exit", "kill",
    ]
    /// Filler words that should be discarded when extracting the app name.
    private static let looseAppCommandFillerWords: Set<String> = [
        "the", "my", "this", "that", "an", "a",
        "please", "now", "for", "me",
        "uh", "um", "umm", "uhh",
        "up", "down",  // "boot up", "shut down"
        "to", "of",
        "app", "application", "program",
    ]

    /// Tries to recognize an app-launch / app-quit intent regardless of word
    /// order. Returns nil if the transcript doesn't contain a launch/quit
    /// verb word.
    ///
    /// Examples that this matches but the strict verb-prefix matcher would not:
    ///   "freeform open"        → launchOrActivateApp("freeform")
    ///   "open up freeform"     → launchOrActivateApp("freeform")
    ///   "please open freeform" → launchOrActivateApp("freeform")  (wrappers
    ///                            stripped by normalize, but extra defense)
    ///   "freeform quit"        → quitApp("freeform")
    private static func parseLooseAppCommand(_ text: String) -> LocalIntent? {
        let words = text
            .split(whereSeparator: { $0.isWhitespace || ",.!?—-".contains($0) })
            .map(String.init)
        guard !words.isEmpty else { return nil }

        // Find the verb word's position so we can ignore noise on the WRONG
        // side of it. Real-world example: "Wiki, open Freeform, the app on
        // my Mac" — "Wiki" is wake-word noise that came BEFORE the verb,
        // and shouldn't be part of the app name.
        var detectedVerb: LooseAppVerb? = nil
        var verbWordIndex: Int? = nil
        for (index, word) in words.enumerated() {
            let lowercased = word.lowercased()
            if looseLaunchVerbWords.contains(lowercased) {
                detectedVerb = .launch
                verbWordIndex = index
                break
            }
            if looseQuitVerbWords.contains(lowercased) {
                detectedVerb = .quit
                verbWordIndex = index
                break
            }
        }

        guard let verb = detectedVerb, let verbIndex = verbWordIndex else { return nil }
        if verb == .quit && words.contains(where: { $0.lowercased() == "window" }) {
            return nil
        }

        // Words AFTER the verb are the app name, unless the verb is at the
        // very end (e.g. "freeform open") in which case the words BEFORE
        // the verb are the app name.
        let candidateNameWords: ArraySlice<String>
        if verbIndex + 1 < words.count {
            candidateNameWords = words[(verbIndex + 1)...]
        } else if verbIndex > 0 {
            candidateNameWords = words[..<verbIndex]
        } else {
            return nil
        }

        // Stop app-name capture at a clause boundary. Speech transcripts often
        // include a cut-off tail like "open Google for me and—"; without this,
        // the app name becomes "google and" and misses the fast path.
        let boundedNameWords = candidateNameWords.prefix { word in
            !["and", "then", "but"].contains(word.lowercased())
        }

        // Drop pure filler tokens but keep substantive words.
        let filteredNameWords = boundedNameWords.filter {
            !looseAppCommandFillerWords.contains($0.lowercased())
        }
        let rawJoinedName = filteredNameWords.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip "on my mac" / "on the screen" / "for me" tails that voice
        // users append after the actual app name.
        let cleanedAppName = stripTrailingContextPhrases(rawJoinedName)
        guard !cleanedAppName.isEmpty else { return nil }

        switch verb {
        case .launch:
            return .launchOrActivateApp(name: cleanedAppName)
        case .quit:
            return .quitApp(name: cleanedAppName)
        }
    }

    private enum LooseAppVerb {
        case launch
        case quit
    }

    // MARK: - Calculator matching

    private static func parseCalculatorExpressionCommand(_ text: String) -> String? {
        guard text.contains("calculator")
            || text.hasPrefix("calculate ")
            || text.hasPrefix("what is ")
            || text.hasPrefix("what's ") else {
            return nil
        }

        let triggerPhrases = [
            "show me ",
            "calculate ",
            "what is ",
            "what's ",
            "work out ",
            "compute ",
        ]
        var candidates: [String] = []
        for phrase in triggerPhrases {
            if let range = text.range(of: phrase) {
                candidates.append(String(text[range.upperBound...]))
            }
        }

        // "open calculator 17 times 24" is less natural, but cheap to support.
        if let range = text.range(of: "calculator ") {
            candidates.append(String(text[range.upperBound...]))
        }

        for candidate in candidates {
            if let expression = normalizeCalculatorExpression(candidate) {
                return expression
            }
        }
        return nil
    }

    private static func normalizeCalculatorExpression(_ text: String) -> String? {
        var candidate = text
            .replacingOccurrences(of: "multiplied by", with: "*")
            .replacingOccurrences(of: "times", with: "*")
            .replacingOccurrences(of: "x", with: "*")
            .replacingOccurrences(of: "plus", with: "+")
            .replacingOccurrences(of: "minus", with: "-")
            .replacingOccurrences(of: "divided by", with: "/")
            .replacingOccurrences(of: "divide by", with: "/")
            .replacingOccurrences(of: "over", with: "/")
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "×", with: "*")

        let trailingPhrases = [
            " in calculator", " on calculator", " using calculator",
            " in the calculator", " on the calculator", " with calculator",
            " please", " for me", " on screen", " on the screen",
        ]
        var changed = true
        while changed {
            changed = false
            for phrase in trailingPhrases where candidate.hasSuffix(phrase) {
                candidate = String(candidate.dropLast(phrase.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                changed = true
                break
            }
        }

        candidate = candidate.replacingOccurrences(of: ",", with: "")
        let pattern = #"(-?\d+(?:\.\d+)?)\s*([+\-*/])\s*(-?\d+(?:\.\d+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
        guard let match = regex.firstMatch(in: candidate, range: range),
              match.numberOfRanges == 4,
              let leftRange = Range(match.range(at: 1), in: candidate),
              let opRange = Range(match.range(at: 2), in: candidate),
              let rightRange = Range(match.range(at: 3), in: candidate)
        else {
            return nil
        }

        return "\(candidate[leftRange])\(candidate[opRange])\(candidate[rightRange])"
    }

    /// Recognizes "navigate to <X>", "go to the <X> icon", "show me the <X>
    /// menu" and similar phrasings, returning the bare element name. These
    /// are CLICK intents (not app launches) because the user is referring
    /// to a UI element on screen, usually with a UI-noun suffix (icon, menu,
    /// button, tab, etc.).
    ///
    /// Returns nil if the transcript doesn't begin with a navigate/show verb.
    private static func parseNavigateOrShowCommand(_ text: String) -> String? {
        let navigateVerbs: [String] = [
            "navigate to ", "navigate to the ", "navigate to my ",
            "show me the ", "show me my ",
            "go to the ", "go to my ",
            "to the ", "to my ",
        ]
        var matchedVerbPrefix: String? = nil
        for verbPrefix in navigateVerbs {
            if text.hasPrefix(verbPrefix) {
                matchedVerbPrefix = verbPrefix
                break
            }
        }
        guard let verbPrefix = matchedVerbPrefix else { return nil }

        let remainder = String(text.dropFirst(verbPrefix.count))
        let cleaned = stripTrailingFillerAndPunctuation(remainder)
        // Drop trailing context like " on my mac" / " on my screen" that
        // people add to voice commands but isn't part of the target name.
        let stripped = stripTrailingContextPhrases(cleaned)
        // Drop trailing UI noun ("icon" / "menu" / "button") — clickByName
        // does that itself, but doing it here makes the matched name cleaner.
        let withoutNoun = stripTrailingUINoun(stripped)
        return withoutNoun.isEmpty ? nil : withoutNoun
    }

    /// Recognizes common note-taking requests so they do not have to wait
    /// for Claude to emit OPEN_APP/KEY/TYPE tags.
    private static func parseCreateNoteCommand(_ text: String) -> String? {
        let patterns = [
            #"(?:^|\b)(?:make|create|write|take|add|draft|jot(?:\s+down)?)\s+(?:a\s+)?note(?:\s+for\s+me)?(?:\s+(?:to|that\s+says|saying|about|of|called|titled))?\s+(.+)$"#,
            #"(?:^|\b)(?:jot\s+down)\s+(?:that\s+)?(.+)$"#,
            #"(?:^|\b)(?:note\s+down)\s+(?:that\s+)?(.+)$"#,
            #"(?:^|\b)(?:notes?|notes\s+app)\s+(?:and\s+)?(?:make|create|write|take|add|draft|jot(?:\s+down)?)\s+(?:a\s+)?note(?:\s+for\s+me)?(?:\s+(?:to|that\s+says|saying|about|of|called|titled))?\s+(.+)$"#,
            #"(?:^|\b)(?:notes?|notes\s+app)\s+(?:and\s+)?(?:jot\s+down)\s+(?:that\s+)?(.+)$"#,
            #"(?:^|\b)(?:notes?|notes\s+app)\s+(?:and\s+)?(?:note\s+down)\s+(?:that\s+)?(.+)$"#,
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                  match.numberOfRanges >= 2,
                  let noteRange = Range(match.range(at: 1), in: text)
            else { continue }

            let rawNoteText = String(text[noteRange])
            let cleanedNoteText = stripTrailingFillerAndPunctuation(rawNoteText)
                .trimmingCharacters(in: CharacterSet(charactersIn: " -—:,.!?"))
            guard !cleanedNoteText.isEmpty else { continue }
            return cleanedNoteText
        }

        return nil
    }

    /// Strips noisy trailing phrases voice users often append: " on my mac",
    /// " on the screen", " right now", etc. Anything that doesn't refer to
    /// a real target.
    private static func stripTrailingContextPhrases(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let trailers = [
            " on my mac", " on my screen", " on the screen", " on screen",
            " on mac", " on the mac",
            " on this app", " on this", " in this app",
            " right now", " for me", " thanks", " thank you",
        ]
        var changed = true
        while changed {
            changed = false
            for trailer in trailers {
                if result.hasSuffix(trailer) {
                    result = String(result.dropLast(trailer.count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    changed = true
                    break
                }
            }
        }
        return result
    }

    /// Drops a trailing UI-noun word so "apple icon" → "apple", "file menu"
    /// → "file". `clickByName` already does this in the executor, but doing
    /// it here keeps the matched intent name cleaner in logs.
    private static func stripTrailingUINoun(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffixes = [" icon", " menu", " button", " tab", " window", " panel", " link", " field", " checkbox"]
        for suffix in suffixes {
            if trimmed.hasSuffix(suffix) {
                return String(trimmed.dropLast(suffix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return trimmed
    }

    // MARK: - Scroll matching

    private static func scrollDirection(from text: String) -> ScrollDirection? {
        let stripped = stripTrailingFillerAndPunctuation(text)
        switch stripped {
        case "scroll up", "scroll upward", "scroll upwards", "page up":
            return .up
        case "scroll down", "scroll downward", "scroll downwards", "page down":
            return .down
        case "scroll left":
            return .left
        case "scroll right":
            return .right
        default:
            return nil
        }
    }

    // MARK: - Key chord parsing

    private static let modifierWords: Set<String> = [
        "cmd", "command", "ctrl", "control", "opt", "option", "alt",
        "shift", "fn", "function",
    ]

    private static let namedKeys: Set<String> = [
        "return", "enter", "escape", "esc", "space", "spacebar", "tab",
        "up", "down", "left", "right",
        "delete", "backspace", "forward delete",
        "home", "end", "pageup", "pagedown",
        "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10",
        "f11", "f12",
    ]

    /// Parses things like:
    ///   "cmd s"        → "cmd+s"
    ///   "command s"    → "cmd+s"
    ///   "command shift t" → "cmd+shift+t"
    ///   "return"       → "return"
    /// Returns nil if the input doesn't look like a key chord.
    private static func parseKeyChord(_ text: String) -> String? {
        let words = text
            .lowercased()
            .replacingOccurrences(of: "+", with: " ")
            .split(separator: " ")
            .map { String($0) }
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }

        var modifiers: [String] = []
        var keyName: String? = nil

        for word in words {
            if modifierWords.contains(word) {
                modifiers.append(canonicalModifier(word))
            } else if namedKeys.contains(word) || word.count == 1 {
                // Single-character keys ("s", "t", etc.) plus named keys
                // ("return", "escape", "f1", etc.) are valid chord targets.
                guard keyName == nil else { return nil }  // two key names → not a chord
                keyName = word
            } else {
                // Unknown token in a chord position — bail out so this is
                // treated as a click target instead.
                return nil
            }
        }

        guard let key = keyName else { return nil }

        // De-dup modifiers while preserving canonical order.
        let canonicalOrder = ["cmd", "ctrl", "opt", "shift", "fn"]
        let uniqueMods = canonicalOrder.filter { modifiers.contains($0) }

        if uniqueMods.isEmpty {
            return key  // bare key like "return"
        }
        return uniqueMods.joined(separator: "+") + "+" + key
    }

    private static func canonicalModifier(_ word: String) -> String {
        switch word {
        case "command", "cmd": return "cmd"
        case "control", "ctrl": return "ctrl"
        case "option", "opt", "alt": return "opt"
        case "shift": return "shift"
        case "function", "fn": return "fn"
        default: return word
        }
    }

    // MARK: - Helpers

    private static func endsWithUIElementNoun(_ text: String) -> Bool {
        let nouns = [" menu", " tab", " window", " panel", " sidebar", " toolbar", " dialog", " popup", " dropdown"]
        for noun in nouns {
            if text.hasSuffix(noun) { return true }
        }
        return false
    }

    private static func looksLikeAgentSessionRequest(_ text: String) -> Bool {
        var normalizedAgentText = text
        let codexSpeechAliases = [
            #"\bcortex\b"#,
            #"\bcode\s*x\b"#,
            #"\bcodecs\b"#,
            #"\bcodec\b"#,
            #"\bcode\s+exchange\b"#,
        ]
        for alias in codexSpeechAliases {
            normalizedAgentText = normalizedAgentText.replacingOccurrences(
                of: alias,
                with: "codex",
                options: [.regularExpression]
            )
        }

        let words = Set(
            normalizedAgentText
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
        )
        let hasLaunchVerb = !words.isDisjoint(with: ["launch", "start", "spawn", "run", "fire", "fork"])
        let hasSessionNoun = !words.isDisjoint(with: ["session", "sessions", "agent", "agents", "sibling", "siblings", "codex"])
        let hasAgentContext = normalizedAgentText.contains("parallel")
            || normalizedAgentText.contains("codex")
            || words.contains("agent")
            || words.contains("agents")

        return hasLaunchVerb && hasSessionNoun && hasAgentContext
    }

    private static func stripDeterminerPrefix(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let determiners = ["the ", "my ", "this ", "that ", "an ", "a "]
        for det in determiners {
            if result.hasPrefix(det) {
                result = String(result.dropFirst(det.count))
                break
            }
        }
        return result
    }

    /// Looks up the normalized substring in the original transcript and
    /// returns the casing-preserved version. Used so "type Hello World"
    /// doesn't get downcased to "hello world" before being typed out.
    private static func preserveOriginalCasing(of normalizedRemainder: String, from originalTranscript: String) -> String {
        let lowercaseOriginal = originalTranscript.lowercased()
        guard let range = lowercaseOriginal.range(of: normalizedRemainder) else {
            return normalizedRemainder
        }
        // Map the lowercased range back to the original transcript's indices.
        let startOffset = lowercaseOriginal.distance(from: lowercaseOriginal.startIndex, to: range.lowerBound)
        let length = lowercaseOriginal.distance(from: range.lowerBound, to: range.upperBound)
        let originalStart = originalTranscript.index(originalTranscript.startIndex, offsetBy: startOffset)
        let originalEnd = originalTranscript.index(originalStart, offsetBy: length)
        return String(originalTranscript[originalStart..<originalEnd])
    }

    /// Lowercases, trims, and removes filler/wake-word prefixes so a noisy
    /// transcript like "Um, hey ipop, can you click the file menu, please?"
    /// becomes "click the file menu" for matching.
    private static func normalize(_ transcript: String) -> String {
        var result = transcript
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let leadingFillers: [String] = [
            "um ", "uh ", "uhh ", "umm ", "okay ", "ok ", "alright ",
            "please ", "hey ", "hi ", "yo ", "yeah ",
            "ipop ", "ipop, ", "ipop.", "ipop.ai ", "ipop.ai, ",
            "buddy ", "learning buddy ", "learning buddy, ",
            "leanring buddy ", "leanring buddy, ",
        ]

        var changed = true
        while changed {
            changed = false
            for filler in leadingFillers {
                if result.hasPrefix(filler) {
                    result = String(result.dropFirst(filler.count))
                    changed = true
                    break
                }
            }
            while let first = result.first, ",.!?".contains(first) {
                result = String(result.dropFirst())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                changed = true
            }
        }

        let politenessWrappers = [
            "can you ", "could you ", "would you ", "please can you ",
            "i want to ", "i'd like to ", "i'd like you to ", "i need to ",
            "let's ", "lets ",
        ]
        for wrapper in politenessWrappers {
            if result.hasPrefix(wrapper) {
                result = String(result.dropFirst(wrapper.count))
                break
            }
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripTrailingFillerAndPunctuation(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)

        while let last = result.last, ",.!?".contains(last) {
            result = String(result.dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let trailers = [" for me", " please", " now", " right now", " thanks", " thank you"]
        var changed = true
        while changed {
            changed = false
            for trailer in trailers {
                if result.hasSuffix(trailer) {
                    result = String(result.dropLast(trailer.count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    changed = true
                    break
                }
                if result.hasSuffix("," + trailer) {
                    result = String(result.dropLast(trailer.count + 1))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    changed = true
                    break
                }
            }
        }

        while let last = result.last, ",.!?".contains(last) {
            result = String(result.dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return result
    }

    private static func isCurrentTimeQuery(_ text: String) -> Bool {
        let stripped = stripTrailingFillerAndPunctuation(text)
        let timePhrases: Set<String> = [
            "what time is it",
            "what's the time",
            "what is the time",
            "current time",
            "tell me the time",
            "give me the time",
            "the time",
        ]
        return timePhrases.contains(stripped)
    }
}
