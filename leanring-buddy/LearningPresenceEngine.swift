import Foundation

enum LearningPresenceTempo: String, Equatable {
    case instant
    case careful
    case repair
    case stretch
    case situated
}

struct LearningPresenceFrame: Equatable {
    let tempo: LearningPresenceTempo
    let learnerRead: String
    let screenRead: String
    let agiMove: String
    let openingLine: String

    var promptBlock: String {
        """
        <learning-presence-frame>
        tempo: \(tempo.rawValue)
        learner_read: \(learnerRead)
        screen_read: \(screenRead)
        agi_move: \(agiMove)
        opening_line: \(openingLine)
        </learning-presence-frame>
        """
    }
}

enum LearningPresenceEngine {
    static func frame(
        transcript: String,
        lesson: LessonSession,
        assetContext: LearningAssetContext
    ) -> LearningPresenceFrame {
        let normalized = transcript.lowercased()
        let topicKind = topicKind(for: lesson, assetContext: assetContext)
        let screenRead = screenRead(for: assetContext, topicKind: topicKind)

        if let misconception = misconceptionFrame(
            transcript: normalized,
            lesson: lesson,
            topicKind: topicKind,
            screenRead: screenRead
        ) {
            return misconception
        }

        if lesson.phase == .repairingConfusion || containsConfusionSignal(normalized) {
            return LearningPresenceFrame(
                tempo: .repair,
                learnerRead: "the learner is not missing motivation; the current representation is too large",
                screenRead: screenRead,
                agiMove: "shrink the idea to one visible handle, then rebuild",
                openingLine: "This still feeling blurry is a signal to shrink the object, not repeat the definition."
            )
        }

        if lesson.mastery.confidence >= 82 {
            return LearningPresenceFrame(
                tempo: .stretch,
                learnerRead: "the learner is ready to own the idea instead of recognizing it",
                screenRead: screenRead,
                agiMove: "ask for a teach-back anchored to the artifact",
                openingLine: "You are past recognition now; the useful move is making the idea sound like yours."
            )
        }

        if lesson.mastery.confidence >= 55 || lesson.arcState.step == .transfer {
            return LearningPresenceFrame(
                tempo: .stretch,
                learnerRead: "the learner has a foothold and needs transfer, not another identical example",
                screenRead: screenRead,
                agiMove: "change one variable and ask what stays invariant",
                openingLine: "You have the foothold; now we should see whether the idea survives a small change."
            )
        }

        if lesson.phase == .evaluatingAnswer {
            return LearningPresenceFrame(
                tempo: .careful,
                learnerRead: "the learner just committed to an answer, so the answer is the new evidence",
                screenRead: screenRead,
                agiMove: "evaluate the answer, name the exact gap, then advance one notch",
                openingLine: "Your answer is the useful data now; I am going to use it instead of restarting."
            )
        }

        if assetContext.assetType == .code || topicKind == "code" {
            return LearningPresenceFrame(
                tempo: .situated,
                learnerRead: "the learner needs the mental model behind the visible error",
                screenRead: screenRead,
                agiMove: "read the error as a broken contract, then point to the smallest fix",
                openingLine: "The screen is giving us an error, but the lesson is the contract behind it."
            )
        }

        if assetContext.assetType == .youtube {
            return LearningPresenceFrame(
                tempo: .situated,
                learnerRead: "the learner wants the video turned into an active lesson",
                screenRead: screenRead,
                agiMove: "pause the idea, name the mechanism, then test it with a prediction",
                openingLine: "Let's treat the video like a specimen, not something to passively watch."
            )
        }

        return LearningPresenceFrame(
            tempo: .instant,
            learnerRead: "the learner needs a concrete first handle",
            screenRead: screenRead,
            agiMove: "make one visible part carry the whole idea",
            openingLine: "I am going to make one visible piece do the heavy lifting."
        )
    }

    static func promptBlock(
        transcript: String,
        lesson: LessonSession,
        assetContext: LearningAssetContext
    ) -> String {
        frame(
            transcript: transcript,
            lesson: lesson,
            assetContext: assetContext
        ).promptBlock
    }

    static func refinedMove(
        _ move: TeachingMove,
        transcript: String,
        lesson: LessonSession,
        assetContext: LearningAssetContext
    ) -> TeachingMove {
        let frame = frame(transcript: transcript, lesson: lesson, assetContext: assetContext)
        var refined = move

        if shouldAddOpeningLine(frame.openingLine, to: refined) {
            refined.spokenResponse = joinSentences(frame.openingLine, refined.spokenResponse)
        }

        let currentNextMove = refined.nextMove?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
        let presenceNextMove = "presence:\(frame.tempo.rawValue) -> \(frame.agiMove)"
        refined.nextMove = currentNextMove.isEmpty
            ? presenceNextMove
            : "\(currentNextMove); \(presenceNextMove)"
        refined.nextState = refined.nextMove

        if refined.memoryCandidate?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
           frame.tempo == .repair || frame.tempo == .stretch {
            refined.memoryCandidate = "User needs \(frame.tempo.rawValue) pacing: \(frame.learnerRead)."
        }

        return refined
    }

    private static func shouldAddOpeningLine(
        _ openingLine: String,
        to move: TeachingMove
    ) -> Bool {
        let trimmedOpening = openingLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOpening.isEmpty else { return false }
        let spoken = move.spokenResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { return true }

        let normalizedSpoken = spoken.lowercased()
        let normalizedOpening = trimmedOpening.lowercased()
        if normalizedSpoken.contains(normalizedOpening) { return false }
        if normalizedSpoken.hasPrefix("i am going to make one visible piece")
            || normalizedSpoken.hasPrefix("your answer is the useful data")
            || normalizedSpoken.hasPrefix("the screen is giving us an error") {
            return false
        }
        return true
    }

    private static func misconceptionFrame(
        transcript: String,
        lesson: LessonSession,
        topicKind: String,
        screenRead: String
    ) -> LearningPresenceFrame? {
        let learnerText = [
            transcript,
            lesson.recentAnswers.last,
            lesson.misconceptions.last,
            lesson.confusionSignals.last
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()

        switch topicKind {
        case "multiplication" where containsAny(learnerText, ["25", "twenty five", "twenty-five"]):
            return LearningPresenceFrame(
                tempo: .repair,
                learnerRead: "the learner saw the five rows, then reused five as the size of each row",
                screenRead: screenRead,
                agiMove: "turn the wrong answer into a row-versus-row-size diagnosis",
                openingLine: "That 25 is useful: it tells me you saw the 5 rows and accidentally reused 5 as the row size."
            )
        case "fractions" where containsAny(learnerText, ["empty doesn't matter", "empty does not matter", "only the shaded", "just shaded"]):
            return LearningPresenceFrame(
                tempo: .repair,
                learnerRead: "the learner is dropping unshaded parts from the whole",
                screenRead: screenRead,
                agiMove: "make the empty space part of the evidence",
                openingLine: "That answer tells me the empty space disappeared from the story, so we need to put the whole back on screen."
            )
        case "derivatives" where containsAny(learnerText, ["height", "y value", "where the curve is"]):
            return LearningPresenceFrame(
                tempo: .repair,
                learnerRead: "the learner is reading function height instead of local slope",
                screenRead: screenRead,
                agiMove: "separate height from tangent tilt",
                openingLine: "That sounds like you are reading the curve's height; the derivative lives in the tangent's tilt."
            )
        default:
            return nil
        }
    }

    private static func screenRead(
        for assetContext: LearningAssetContext,
        topicKind: String
    ) -> String {
        if let browserTitle = assetContext.browserTitle, !browserTitle.isEmpty {
            return "current browser material: \(browserTitle)"
        }
        if let firstPath = assetContext.selectedFilePaths.first {
            return "selected local material: \(URL(fileURLWithPath: firstPath).lastPathComponent)"
        }

        switch assetContext.assetType {
        case .whiteboard:
            return "a visible whiteboard can become the manipulable lesson artifact"
        case .code:
            return "the visible code/error can become the source of truth"
        case .youtube:
            return "the video can become an active prediction surface"
        case .browserPage:
            return "the page can be turned into a worked example"
        case .localDocument:
            return "the document can be marked up as the lesson surface"
        case .screen, .unknown:
            return topicKind == "generic"
                ? "the current screen can anchor the explanation"
                : "the current screen can be connected to \(topicKind)"
        }
    }

    private static func topicKind(
        for lesson: LessonSession,
        assetContext: LearningAssetContext
    ) -> String {
        let haystack = "\(lesson.topic) \(assetContext.candidateTopic ?? "") \(assetContext.browserTitle ?? "")"
            .lowercased()
        if containsAny(haystack, ["fraction", "numerator", "denominator", "fourth", "equal part"]) {
            return "fractions"
        }
        if containsAny(haystack, ["derivative", "slope", "tangent", "calculus"]) {
            return "derivatives"
        }
        if containsAny(haystack, ["multiplication", "multiply", "array", "row", "column", "times"]) {
            return "multiplication"
        }
        if assetContext.assetType == .code || containsAny(haystack, ["xcode", "error", "code"]) {
            return "code"
        }
        return "generic"
    }

    private static func containsConfusionSignal(_ text: String) -> Bool {
        containsAny(text, [
            "i don't get",
            "dont get",
            "do not get",
            "confused",
            "confusing",
            "lost",
            "stuck",
            "no idea"
        ])
    }

    private static func joinSentences(_ first: String, _ second: String) -> String {
        let trimmedFirst = first.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSecond = second.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedSecond.isEmpty { return trimmedFirst }
        if trimmedSecond.lowercased().contains(trimmedFirst.lowercased()) {
            return trimmedSecond
        }
        return "\(trimmedFirst) \(trimmedSecond)"
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }
}
