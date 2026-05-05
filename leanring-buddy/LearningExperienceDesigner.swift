import Foundation

enum LearningExperienceMode: String, Equatable {
    case livingModel
    case predictionLab
    case misconceptionLab
    case transferLab
    case teachBackStudio
    case screenToSelf

    var displayName: String {
        switch self {
        case .livingModel: return "living model"
        case .predictionLab: return "prediction lab"
        case .misconceptionLab: return "misconception lab"
        case .transferLab: return "transfer lab"
        case .teachBackStudio: return "teach-back studio"
        case .screenToSelf: return "screen-to-self bridge"
        }
    }
}

struct LearningExperienceBrief: Equatable {
    let mode: LearningExperienceMode
    let learnerPromise: String
    let visibleMove: String
    let feedbackLoop: String
    let surfaceCue: String

    var promptBlock: String {
        """
        <learning-experience-brief>
        mode: \(mode.rawValue)
        learner_promise: \(learnerPromise)
        visible_move: \(visibleMove)
        feedback_loop: \(feedbackLoop)
        surface_cue: \(surfaceCue)
        </learning-experience-brief>
        """
    }

    func boardNote(for move: TeachingMove) -> String {
        let candidate = (move.studentMove ?? move.question ?? visibleMove)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let moveText = candidate.isEmpty ? visibleMove : candidate
        switch mode {
        case .livingModel:
            return "Try: \(moveText)"
        case .predictionLab:
            return "Predict first: \(moveText)"
        case .misconceptionLab:
            return "Repair move: \(moveText)"
        case .transferLab:
            return "Transfer: \(moveText)"
        case .teachBackStudio:
            return "Say it back: \(moveText)"
        case .screenToSelf:
            return "Connect it: \(moveText)"
        }
    }
}

enum LearningExperienceDesigner {
    static func brief(
        for lesson: LessonSession,
        assetContext: LearningAssetContext
    ) -> LearningExperienceBrief {
        let mode = mode(for: lesson, assetContext: assetContext)
        let topicKind = topicKind(for: lesson, assetContext: assetContext)
        return LearningExperienceBrief(
            mode: mode,
            learnerPromise: learnerPromise(mode: mode, topicKind: topicKind, lesson: lesson),
            visibleMove: visibleMove(mode: mode, topicKind: topicKind, lesson: lesson),
            feedbackLoop: feedbackLoop(mode: mode, topicKind: topicKind),
            surfaceCue: surfaceCue(mode: mode, topicKind: topicKind, assetContext: assetContext)
        )
    }

    static func promptBlock(
        for lesson: LessonSession,
        assetContext: LearningAssetContext
    ) -> String {
        brief(for: lesson, assetContext: assetContext).promptBlock
    }

    static func refinedMove(
        _ move: TeachingMove,
        lesson: LessonSession,
        assetContext: LearningAssetContext
    ) -> TeachingMove {
        let brief = brief(for: lesson, assetContext: assetContext)
        var refined = move

        let currentNextMove = refined.nextMove?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
        let experienceNextMove = "experience:\(brief.mode.rawValue) -> \(brief.feedbackLoop)"
        refined.nextMove = currentNextMove.isEmpty
            ? experienceNextMove
            : "\(currentNextMove); \(experienceNextMove)"
        refined.nextState = refined.nextMove

        if refined.visualAnchor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            refined.visualAnchor = brief.surfaceCue
        }

        if shouldPinVisibleMove(move: refined, lesson: lesson, assetContext: assetContext) {
            refined.surfaceAction = .writeFreeformText(brief.boardNote(for: refined))
        }

        if refined.memoryCandidate?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
           shouldRememberExperience(brief.mode) {
            refined.memoryCandidate = "User is in \(brief.mode.displayName); future turns should keep learning active and visible."
        }

        return refined
    }

    private static func shouldPinVisibleMove(
        move: TeachingMove,
        lesson: LessonSession,
        assetContext: LearningAssetContext
    ) -> Bool {
        if let surfaceAction = move.surfaceAction, surfaceAction != .none {
            return false
        }
        let hasLearnerMove = (move.studentMove ?? move.question)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        guard hasLearnerMove else { return false }
        return assetContext.assetType == .whiteboard
            || lesson.assetType == .whiteboard
            || assetContext.frontmostAppName?.lowercased().contains("freeform") == true
    }

    private static func shouldRememberExperience(_ mode: LearningExperienceMode) -> Bool {
        switch mode {
        case .misconceptionLab, .transferLab, .teachBackStudio:
            return true
        case .livingModel, .predictionLab, .screenToSelf:
            return false
        }
    }

    private static func mode(
        for lesson: LessonSession,
        assetContext: LearningAssetContext
    ) -> LearningExperienceMode {
        let topicKind = topicKind(for: lesson, assetContext: assetContext)
        if lesson.phase == .repairingConfusion || !lesson.confusionSignals.isEmpty {
            return .misconceptionLab
        }
        if hasKnownMisconception(in: lesson, topicKind: topicKind) {
            return .misconceptionLab
        }
        if lesson.mastery.confidence >= 82 {
            return .teachBackStudio
        }
        if lesson.mastery.confidence >= 55 || lesson.arcState.step == .transfer {
            return .transferLab
        }
        if lesson.phase == .evaluatingAnswer || lesson.phase == .awaitingAnswer {
            return .predictionLab
        }
        if assetContext.assetType == .screen || assetContext.assetType == .code {
            return .screenToSelf
        }
        return .livingModel
    }

    private static func hasKnownMisconception(
        in lesson: LessonSession,
        topicKind: String
    ) -> Bool {
        let learnerText = [
            lesson.recentAnswers.last,
            lesson.misconceptions.last,
            lesson.confusionSignals.last
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()

        switch topicKind {
        case "multiplication":
            return containsAny(learnerText, ["25", "twenty five", "twenty-five"])
        case "fractions":
            return containsAny(learnerText, ["empty doesn't matter", "empty does not matter", "only the shaded", "just shaded"])
        case "derivatives":
            return containsAny(learnerText, ["height", "y value", "where the curve is"])
        default:
            return false
        }
    }

    private static func learnerPromise(
        mode: LearningExperienceMode,
        topicKind: String,
        lesson: LessonSession
    ) -> String {
        switch mode {
        case .livingModel:
            return "turn the concept into something the learner can inspect, not just hear"
        case .predictionLab:
            return "make the learner commit to a visible prediction before iPOP explains more"
        case .misconceptionLab:
            return "treat the mistake as useful data and rebuild with a smaller visible move"
        case .transferLab:
            return "move the idea into a nearby case so the learner sees what stays invariant"
        case .teachBackStudio:
            return "make the learner produce the idea in their own words, using the artifact"
        case .screenToSelf:
            let topic = lesson.topic.isEmpty ? topicKind : lesson.topic
            return "connect \(topic) to the user's actual screen so the lesson feels situated"
        }
    }

    private static func visibleMove(
        mode: LearningExperienceMode,
        topicKind: String,
        lesson: LessonSession
    ) -> String {
        switch (mode, topicKind) {
        case (.misconceptionLab, "multiplication"):
            return "cover everything except one row, then count that row before naming the total"
        case (.misconceptionLab, "fractions"):
            return "count the whole partition before counting the shaded pieces"
        case (.misconceptionLab, "derivatives"):
            return "ignore the whole curve and read only the tangent's tilt"
        case (.transferLab, "multiplication"):
            return "flip rows and columns and decide what changed"
        case (.transferLab, "fractions"):
            return "change the shaded count while keeping the same whole visible"
        case (.transferLab, "derivatives"):
            return "tilt the tangent the other way and predict the sign"
        case (.teachBackStudio, _):
            return "explain the idea back from the picture, not from a memorized definition"
        case (.predictionLab, _):
            return "make one visible prediction, then compare it with the artifact"
        case (.screenToSelf, "code"):
            return "point to the exact contract the error message says broke"
        default:
            return "touch one visible part, predict what it controls, then explain why"
        }
    }

    private static func feedbackLoop(
        mode: LearningExperienceMode,
        topicKind: String
    ) -> String {
        switch mode {
        case .livingModel:
            return "see -> predict -> reveal"
        case .predictionLab:
            return "predict -> check -> repair"
        case .misconceptionLab:
            return "mistake -> smaller visual -> rebuild"
        case .transferLab:
            return "same idea -> changed case -> invariant"
        case .teachBackStudio:
            return "learner words -> tighten -> consolidate"
        case .screenToSelf:
            return topicKind == "code"
                ? "error text -> mental model -> smallest fix"
                : "screen detail -> concept -> next action"
        }
    }

    private static func surfaceCue(
        mode: LearningExperienceMode,
        topicKind: String,
        assetContext: LearningAssetContext
    ) -> String {
        if let browserTitle = assetContext.browserTitle, !browserTitle.isEmpty {
            return browserTitle
        }
        if let firstPath = assetContext.selectedFilePaths.first {
            return URL(fileURLWithPath: firstPath).lastPathComponent
        }

        switch topicKind {
        case "multiplication":
            return "the array rows, dots-per-row, and total"
        case "fractions":
            return "the whole bar, equal spaces, shaded pieces, and empty pieces"
        case "derivatives":
            return "the point, tangent line, and curve around that point"
        case "code":
            return "the visible error text and the line or symbol it names"
        default:
            switch mode {
            case .screenToSelf:
                return "the user's current screen"
            default:
                return "the visible lesson artifact"
            }
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

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }
}
