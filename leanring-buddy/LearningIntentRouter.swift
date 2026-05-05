import Foundation

enum LearningIntentRoute: Equatable {
    case notLearning
    case teacherMode
    case endLesson
}

enum LearningIntentRouter {
    static func route(
        transcript: String,
        isTeacherModeEnabled: Bool,
        hasActiveLesson: Bool
    ) -> LearningIntentRoute {
        guard isTeacherModeEnabled else { return .notLearning }

        let normalized = normalize(transcript)
        guard !normalized.isEmpty else { return .notLearning }

        if isEndLessonRequest(normalized) {
            return hasActiveLesson ? .endLesson : .notLearning
        }

        if isExplicitLearningRequest(normalized) {
            return .teacherMode
        }

        guard hasActiveLesson else { return .notLearning }

        if looksLikeUnrelatedDirectAction(normalized) {
            return .notLearning
        }

        if isLessonFollowUp(normalized) || looksLikeLearnerAnswer(normalized) {
            return .teacherMode
        }

        return .notLearning
    }

    static func shouldRouteToTeacherMode(
        transcript: String,
        isTeacherModeEnabled: Bool,
        hasActiveLesson: Bool
    ) -> Bool {
        route(
            transcript: transcript,
            isTeacherModeEnabled: isTeacherModeEnabled,
            hasActiveLesson: hasActiveLesson
        ) == .teacherMode
    }

    static func isEndLessonRequest(_ transcript: String) -> Bool {
        let normalized = normalize(transcript)
        let phraseSafeNormalized = phraseSafeNormalize(transcript)
        let endPhrases = [
            "end lesson",
            "end the lesson",
            "stop lesson",
            "stop teaching",
            "stop right there",
            "stop there",
            "pause lesson",
            "pause teaching",
            "that's enough",
            "thats enough",
            "exit teacher mode",
            "leave teacher mode",
            "wrap up the lesson",
            "we are done learning",
            "we're done learning"
        ]
        return endPhrases.contains { phrase in
            phraseAppears(phrase, in: normalized)
                || phraseAppears(phrase, in: phraseSafeNormalized)
        }
    }

    static func isExplicitLearningRequest(_ transcript: String) -> Bool {
        let normalized = normalize(transcript)
        if normalized.contains("teacher") {
            return true
        }
        if normalized.hasPrefix("teach ") || normalized.contains(" teach ") {
            return true
        }
        if normalized.hasPrefix("explain ") || normalized.contains(" explain ") {
            return true
        }
        if normalized.contains(" learn ")
            && (normalized.contains("help") || normalized.contains("teach") || normalized.contains("explain") || normalized.contains("quiz")) {
            return true
        }

        let phrases = [
            "teach me",
            "teach this",
            "teach me this",
            "explain this",
            "explain what",
            "explain the",
            "help me understand",
            "help me learn",
            "i am confused",
            "i'm confused",
            "im confused",
            "i don't get",
            "i dont get",
            "walk me through",
            "quiz me",
            "test me",
            "what am i missing",
            "what should i learn",
            "make this a lesson",
            "turn this into a lesson",
            "use this video as the lesson",
            "use this youtube",
            "as the lesson",
            "learning asset",
            "be my teacher",
            "teacher mode"
        ]
        return phrases.contains { normalized.contains($0) }
    }

    static func isLessonFollowUp(_ transcript: String) -> Bool {
        let normalized = normalize(transcript)
        let exactFollowUps: Set<String> = [
            "why",
            "why is that",
            "how",
            "how so",
            "show me",
            "show me again",
            "again",
            "next",
            "continue",
            "keep going",
            "tell me more",
            "go deeper",
            "deeper",
            "quiz me",
            "test me",
            "give me another",
            "i get it",
            "got it",
            "i don't get it",
            "i dont get it",
            "i don't know",
            "i dont know",
            "not sure",
            "what about this",
            "what does that mean"
        ]
        if exactFollowUps.contains(normalized) { return true }

        let followUpPrefixes = [
            "why ",
            "how ",
            "can you show",
            "show me",
            "tell me",
            "continue",
            "keep going",
            "quiz me",
            "test me",
            "give me",
            "what about",
            "what does",
            "i don't understand",
            "i dont understand",
            "i don't know",
            "i dont know",
            "not sure",
            "i am stuck",
            "i'm stuck",
            "im stuck"
        ]
        return followUpPrefixes.contains { normalized.hasPrefix($0) }
    }

    static func looksLikeLearnerAnswer(_ transcript: String) -> Bool {
        let normalized = normalize(transcript)
        let wordCount = normalized.split(separator: " ").count

        let answerPrefixes = [
            "i think",
            "i guess",
            "because",
            "it means",
            "this means",
            "the answer",
            "my answer",
            "so it",
            "maybe",
            "probably",
            "yes",
            "no"
        ]
        if answerPrefixes.contains(where: { normalized.hasPrefix($0) }) { return true }

        // During an active lesson, short natural utterances are usually answers
        // to the active learner move rather than brand-new commands.
        return wordCount <= 18 && !looksLikeUnrelatedDirectAction(normalized)
    }

    private static func looksLikeUnrelatedDirectAction(_ normalized: String) -> Bool {
        if normalized == "tell me" || normalized.hasPrefix("tell me ") {
            return false
        }

        let destructiveOrExternalPrefixes = [
            "delete ",
            "remove ",
            "rm ",
            "run ",
            "sudo ",
            "install ",
            "force ",
            "git ",
            "send ",
            "message ",
            "dm ",
            "text ",
            "tell ",
            "reply ",
            "respond ",
            "email ",
            "apply ",
            "submit ",
            "bid ",
            "pay ",
            "buy ",
            "purchase ",
            "checkout ",
            "post ",
            "publish ",
            "share ",
            "schedule ",
            "reschedule ",
            "invite ",
            "shut down",
            "restart ",
            "quit "
        ]
        if destructiveOrExternalPrefixes.contains(where: { normalized.hasPrefix($0) }) {
            return true
        }

        if normalized.hasPrefix("open ") {
            let persistentDraftSignals = [
                "draft a note",
                "make a note",
                "create a note",
                "write a note",
                "take a note",
                "jot down",
                "note down",
                "notes and draft",
                "notes and jot"
            ]
            if persistentDraftSignals.contains(where: { normalized.contains($0) }) {
                return true
            }

            let learningTargets = [
                "video",
                "youtube",
                "lesson",
                "article",
                "paper",
                "pdf",
                "page",
                "slide",
                "whiteboard",
                "freeform"
            ]
            return !learningTargets.contains(where: { normalized.contains($0) })
        }

        let directActionPrefixes = [
            "click ",
            "type ",
            "press ",
            "close ",
            "switch to ",
            "navigate to "
        ]
        return directActionPrefixes.contains { normalized.hasPrefix($0) }
    }

    private static func normalize(_ transcript: String) -> String {
        var normalized = transcript
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "ʼ", with: "'")
            .replacingOccurrences(of: "“", with: "\"")
            .replacingOccurrences(of: "”", with: "\"")
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let leadingFillers = ["and, ", "and ", "um, ", "um ", "uh, ", "uh ", "so, ", "so "]
        var didStripSomething = true
        while didStripSomething {
            didStripSomething = false
            for filler in leadingFillers where normalized.hasPrefix(filler) {
                normalized = String(normalized.dropFirst(filler.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                didStripSomething = true
            }
        }

        while let last = normalized.last, ".?!".contains(last) {
            normalized.removeLast()
        }
        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func phraseAppears(_ phrase: String, in normalized: String) -> Bool {
        normalized == phrase
            || normalized.hasPrefix(phrase + " ")
            || normalized.contains(" " + phrase + " ")
            || normalized.hasSuffix(" " + phrase)
    }

    private static func phraseSafeNormalize(_ transcript: String) -> String {
        let punctuationFolded = normalize(transcript)
            .replacingOccurrences(
                of: #"[^a-z0-9']+"#,
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return punctuationFolded
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
    }
}
