import Foundation

enum LessonArcStep: String, Equatable {
    case orient
    case reveal
    case predict
    case repair
    case transfer
    case teachBack
    case consolidate
}

struct LearnerMasteryState: Equatable {
    var topic: String
    var confidence: Int
    var evidence: [String]
    var nextMilestone: String

    init(
        topic: String,
        confidence: Int = 0,
        evidence: [String] = [],
        nextMilestone: String = "make the first visible connection"
    ) {
        self.topic = topic
        self.confidence = max(0, min(100, confidence))
        self.evidence = evidence
        self.nextMilestone = nextMilestone
    }
}

struct LessonArcState: Equatable {
    var step: LessonArcStep
    var completedSteps: [LessonArcStep]
    var lastExplanationStyle: TeacherExplanationStyle

    init(
        step: LessonArcStep = .orient,
        completedSteps: [LessonArcStep] = [],
        lastExplanationStyle: TeacherExplanationStyle = .concrete
    ) {
        self.step = step
        self.completedSteps = completedSteps
        self.lastExplanationStyle = lastExplanationStyle
    }
}

enum TeacherExplanationStyle: String, Equatable {
    case concrete
    case coverUp
    case contrast
    case analogy
    case transfer
    case teachBack
}

enum TeacherQualityFlag: String, Equatable {
    case missingAhaBridge
    case weakLearnerMove
    case noDiagnosis
    case needsStyleSwitch
    case readyForTransfer
    case readyForTeachBack
}

struct TeacherQualityAssessment: Equatable {
    var flags: [TeacherQualityFlag]
    var score: Int
    var chosenStyle: TeacherExplanationStyle
}

struct LessonCurriculumPlan: Equatable {
    var topic: String
    var currentMilestone: String
    var upcomingMilestones: [String]
    var diagnosticQuestion: String
    var ahaTarget: String
    var repetitionPlan: String

    var promptBlock: String {
        let upcoming = upcomingMilestones.isEmpty
            ? "(none)"
            : upcomingMilestones.joined(separator: " -> ")
        return """
        Curriculum arc:
        topic: \(topic)
        current_milestone: \(currentMilestone)
        upcoming_milestones: \(upcoming)
        diagnostic_question: \(diagnosticQuestion)
        aha_target: \(ahaTarget)
        repetition_plan: \(repetitionPlan)
        """
    }
}

enum TeacherQualityLoop {
    static func curriculumPlan(for lesson: LessonSession) -> LessonCurriculumPlan {
        let assetContext = LearningAssetContext(
            assetType: lesson.assetType,
            frontmostAppName: lesson.activeAppName,
            candidateTopic: lesson.topic,
            browserTitle: nil,
            browserURL: nil,
            selectedFilePaths: [],
            selectedFilePreview: nil,
            screenContextLines: []
        )
        let topicKind = topicKindFor(
            lesson: lesson,
            assetContext: assetContext,
            move: TeachingMove(spokenResponse: "")
        )
        let milestones = curriculumMilestones(topicKind: topicKind)
        let currentMilestone = currentCurriculumMilestone(for: lesson, milestones: milestones)
        let upcomingMilestones = upcomingCurriculumMilestones(
            after: currentMilestone,
            milestones: milestones,
            lesson: lesson
        )

        return LessonCurriculumPlan(
            topic: lesson.topic.isEmpty ? topicKind : lesson.topic,
            currentMilestone: currentMilestone,
            upcomingMilestones: upcomingMilestones,
            diagnosticQuestion: diagnosticQuestion(topicKind: topicKind, lesson: lesson),
            ahaTarget: ahaBridge(topicKind: topicKind, style: lesson.arcState.lastExplanationStyle, lesson: lesson),
            repetitionPlan: repetitionPlan(topicKind: topicKind, lesson: lesson)
        )
    }

    static func assess(
        move: TeachingMove,
        lesson: LessonSession,
        assetContext: LearningAssetContext
    ) -> TeacherQualityAssessment {
        let spoken = move.combinedSpokenText.lowercased()
        var flags: [TeacherQualityFlag] = []

        if !hasAhaBridge(spoken) {
            flags.append(.missingAhaBridge)
        }
        if !hasStrongLearnerMove(move.studentMove ?? move.question) {
            flags.append(.weakLearnerMove)
        }
        if move.learnerGap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            flags.append(.noDiagnosis)
        }
        if lesson.phase == .repairingConfusion || lesson.confusionSignals.count >= 2 {
            let style = explanationStyle(for: move, lesson: lesson, assetContext: assetContext)
            if style == lesson.arcState.lastExplanationStyle {
                flags.append(.needsStyleSwitch)
            }
        }
        if lesson.mastery.confidence >= 55,
           lesson.mastery.confidence < 82,
           lesson.phase == .evaluatingAnswer,
           !mentionsTransfer(spoken, studentMove: move.studentMove ?? move.question) {
            flags.append(.readyForTransfer)
        }
        if lesson.mastery.confidence >= 82,
           lesson.phase == .evaluatingAnswer,
           !mentionsTeachBack(spoken, studentMove: move.studentMove ?? move.question) {
            flags.append(.readyForTeachBack)
        }

        let score = max(0, 100 - flags.count * 15)
        return TeacherQualityAssessment(
            flags: flags,
            score: score,
            chosenStyle: explanationStyle(for: move, lesson: lesson, assetContext: assetContext)
        )
    }

    static func refinedMove(
        _ move: TeachingMove,
        lesson: LessonSession,
        assetContext: LearningAssetContext
    ) -> TeachingMove {
        let assessment = assess(move: move, lesson: lesson, assetContext: assetContext)
        guard !assessment.flags.isEmpty else { return move }

        var refined = move
        let topicKind = topicKindFor(lesson: lesson, assetContext: assetContext, move: move)
        let visualAnchor = refined.visualAnchor.trimmingCharacters(in: .whitespacesAndNewlines)
        if visualAnchor.isEmpty {
            refined.visualAnchor = fallbackVisualAnchor(topicKind: topicKind, lesson: lesson, assetContext: assetContext)
        }

        if assessment.flags.contains(.noDiagnosis) {
            refined.learnerGap = fallbackLearnerGap(topicKind: topicKind, lesson: lesson)
        }

        if assessment.flags.contains(.missingAhaBridge) {
            refined.spokenResponse = joinSentences(
                ahaBridge(topicKind: topicKind, style: assessment.chosenStyle, lesson: lesson),
                refined.spokenResponse
            )
        }

        if assessment.flags.contains(.needsStyleSwitch) {
            refined.spokenResponse = joinSentences(
                styleSwitchLine(topicKind: topicKind),
                refined.spokenResponse
            )
            refined.nextMove = "switch explanation style, then rebuild from the learner's answer"
            refined.nextState = refined.nextMove
        }

        if assessment.flags.contains(.weakLearnerMove) {
            refined.studentMove = fallbackStudentMove(topicKind: topicKind, lesson: lesson, assetContext: assetContext)
            refined.question = refined.studentMove
        }

        if assessment.flags.contains(.readyForTransfer) {
            refined.studentMove = transferMove(topicKind: topicKind, lesson: lesson)
            refined.question = refined.studentMove
            refined.nextMove = "transfer the idea to a nearby example, then ask for teach-back"
            refined.nextState = refined.nextMove
        }

        if assessment.flags.contains(.readyForTeachBack) {
            refined.studentMove = teachBackMove(topicKind: topicKind, lesson: lesson)
            refined.question = refined.studentMove
            refined.nextMove = "ask for teach-back, then consolidate the learner's wording"
            refined.nextState = refined.nextMove
        }

        if refined.coreIdea.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            refined.coreIdea = coreIdea(topicKind: topicKind, lesson: lesson)
        }

        if refined.memoryCandidate?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
           let memory = memoryCandidate(topicKind: topicKind, assessment: assessment, lesson: lesson) {
            refined.memoryCandidate = memory
        }

        return refined
    }

    static func updatedMasteryState(
        lesson: LessonSession,
        userTranscript: String,
        teachingMove: TeachingMove
    ) -> LearnerMasteryState {
        var mastery = lesson.mastery
        if mastery.topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            mastery.topic = lesson.topic
        }

        let userText = userTranscript.lowercased()
        let teacherEvidenceText = "\(teachingMove.memoryCandidate ?? "") \(teachingMove.nextMove ?? "")".lowercased()
        let isAnswerTurn = lesson.phase == .evaluatingAnswer || lesson.lastCheckpointQuestion != nil
        var delta = 0

        let confused = containsConfusionSignal(userText)
        if confused {
            delta -= 10
            appendEvidence("signaled confusion that needs repair", to: &mastery.evidence)
        }

        if isAnswerTurn && !confused {
            if showsTopicProgress(userText, topic: lesson.topic) {
                delta += 18
                appendEvidence("answered the current learner move correctly", to: &mastery.evidence)
            } else if containsAny(userText, ["because", "so ", "means", "equals", "there are", "it would"]) {
                delta += 8
                appendEvidence("started explaining the reason, not only the answer", to: &mastery.evidence)
            }

            if containsAny(teacherEvidenceText, [
                "user can",
                "user connected",
                "user answered",
                "mastered",
                "ready to transfer"
            ]) {
                delta += 6
            }
        }
        if isAnswerTurn,
           teachingMove.nextMove?.lowercased().contains("transfer") == true
            || teachingMove.question?.lowercased().contains("would the total change") == true {
            delta += 6
        }

        mastery.confidence = max(0, min(100, mastery.confidence + delta))
        mastery.nextMilestone = nextMilestone(for: mastery.confidence, topic: lesson.topic)
        if mastery.evidence.count > 8 {
            mastery.evidence.removeFirst(mastery.evidence.count - 8)
        }
        return mastery
    }

    static func updatedArcState(
        lesson: LessonSession,
        teachingMove: TeachingMove
    ) -> LessonArcState {
        var arc = lesson.arcState
        appendCompleted(arc.step, to: &arc.completedSteps)

        let text = "\(teachingMove.combinedSpokenText) \(teachingMove.nextMove ?? "") \(teachingMove.question ?? "")".lowercased()
        if lesson.phase == .repairingConfusion || containsAny(text, ["repair", "mistake", "confus", "cover"]) {
            arc.step = .repair
        } else if containsAny(text, ["would the total change", "another example", "transfer", "flip the idea"]) {
            arc.step = .transfer
        } else if containsAny(text, ["explain back", "say it back", "teach it back", "in your own words"]) {
            arc.step = .teachBack
        } else if lesson.turnCount == 0 {
            arc.step = .reveal
        } else if teachingMove.question != nil {
            arc.step = .predict
        } else {
            arc.step = .consolidate
        }
        arc.lastExplanationStyle = explanationStyle(
            for: teachingMove,
            lesson: lesson,
            assetContext: LearningAssetContext(
                assetType: lesson.assetType,
                frontmostAppName: lesson.activeAppName,
                candidateTopic: lesson.topic,
                browserTitle: nil,
                browserURL: nil,
                selectedFilePaths: [],
                selectedFilePreview: nil,
                screenContextLines: []
            )
        )
        return arc
    }

    private static func hasAhaBridge(_ spoken: String) -> Bool {
        containsAny(spoken, [
            "the trick",
            "the aha",
            "notice",
            "instead of",
            "that is the move",
            "the real power",
            "what changes",
            "what stays"
        ])
    }

    private static func hasStrongLearnerMove(_ move: String?) -> Bool {
        guard let move = move?.trimmingCharacters(in: .whitespacesAndNewlines),
              !move.isEmpty,
              move.count <= 220 else {
            return false
        }
        let normalized = move.lowercased()
        if containsAny(normalized, [
            "make sense",
            "do you understand",
            "any questions",
            "want me to",
            "what is the answer",
            "what's the answer",
            "try again",
            "can you solve",
            "can you answer",
            "got it?"
        ]) {
            return false
        }
        return containsAny(normalized, [
            "look",
            "count",
            "predict",
            "name",
            "point",
            "shade",
            "which",
            "what",
            "why",
            "how many",
            "say",
            "try"
        ])
    }

    private static func mentionsTransfer(_ spoken: String, studentMove: String?) -> Bool {
        let combined = "\(spoken) \(studentMove ?? "")".lowercased()
        return containsAny(combined, ["another", "new example", "transfer", "flip", "same idea", "would it change"])
    }

    private static func mentionsTeachBack(_ spoken: String, studentMove: String?) -> Bool {
        let combined = "\(spoken) \(studentMove ?? "")".lowercased()
        return containsAny(combined, ["teach it back", "explain back", "say it back", "in your own words"])
    }

    private static func explanationStyle(
        for move: TeachingMove,
        lesson: LessonSession,
        assetContext: LearningAssetContext
    ) -> TeacherExplanationStyle {
        let text = "\(move.combinedSpokenText) \(move.nextMove ?? "")".lowercased()
        if containsAny(text, ["cover", "hide every", "only the top"]) { return .coverUp }
        if containsAny(text, ["instead of", "not ", "but "]) { return .contrast }
        if containsAny(text, ["like ", "imagine", "pretend"]) { return .analogy }
        if mentionsTransfer(text, studentMove: move.studentMove ?? move.question) { return .transfer }
        if containsAny(text, ["explain back", "say it back", "own words"]) { return .teachBack }
        return .concrete
    }

    private static func topicKindFor(
        lesson: LessonSession,
        assetContext: LearningAssetContext,
        move: TeachingMove
    ) -> String {
        let haystack = "\(lesson.topic) \(assetContext.candidateTopic ?? "") \(move.visualAnchor) \(move.coreIdea)"
            .lowercased()
        if containsAny(haystack, ["fraction", "numerator", "denominator", "fourth", "equal part"]) {
            return "fractions"
        }
        if containsAny(haystack, ["derivative", "slope", "tangent", "calculus"]) {
            return "derivatives"
        }
        if containsAny(haystack, ["multiplication", "array", "row", "column", "times"]) {
            return "multiplication"
        }
        if assetContext.assetType == .code || containsAny(haystack, ["xcode", "error", "code"]) {
            return "code"
        }
        return "generic"
    }

    private static func ahaBridge(
        topicKind: String,
        style: TeacherExplanationStyle,
        lesson: LessonSession
    ) -> String {
        switch topicKind {
        case "multiplication":
            return "The aha is that multiplication is not faster counting; it is seeing one row repeat."
        case "fractions":
            return "The aha is that the denominator names the whole space, including the parts you did not shade."
        case "derivatives":
            return "The aha is that a derivative is the slope the curve is pretending to have when you zoom in until it looks straight."
        case "code":
            return "The aha is that the error is pointing at a broken contract, not scolding the code."
        default:
            let topic = lesson.topic.isEmpty ? "this idea" : lesson.topic
            return "The aha is to connect one visible piece of \(topic) to the whole pattern."
        }
    }

    private static func styleSwitchLine(topicKind: String) -> String {
        switch topicKind {
        case "multiplication":
            return "Let's switch moves: use a cover-up instead of trying to hold the whole array in your head."
        case "fractions":
            return "Let's switch moves: use the empty space as evidence instead of focusing only on the shaded part."
        case "derivatives":
            return "Let's switch moves: ignore the whole curve and zoom into one tiny straight-line moment."
        case "code":
            return "Let's switch moves: read the error as a contract mismatch and trace only the first broken promise."
        default:
            return "Let's switch moves and use a smaller visible piece first."
        }
    }

    private static func fallbackStudentMove(
        topicKind: String,
        lesson: LessonSession,
        assetContext: LearningAssetContext
    ) -> String {
        let latestLearnerText = latestLearnerText(for: lesson)
        switch topicKind {
        case "multiplication":
            if containsAny(latestLearnerText, ["25", "twenty five", "twenty-five"]) {
                return "Cover the lower rows in your mind and count only the top row: how many dots are in that one row?"
            }
            return "Cover every row except the top one in your mind: how many dots are in that one row?"
        case "fractions":
            if containsAny(latestLearnerText, ["empty doesn't matter", "empty does not matter", "only the shaded", "just shaded"]) {
                return "Point your eyes at the empty space too: how many total equal spaces does the whole bar have?"
            }
            return "Look at the whole bar first: how many equal spaces are there, including the empty ones?"
        case "derivatives":
            if containsAny(latestLearnerText, ["height", "y value", "where the curve is"]) {
                return "Ignore the height of the point for one second: does the tangent line tilt up, down, or flat?"
            }
            return "Look only at the tangent line: is its slope positive, negative, or zero?"
        case "code":
            return "Point to the first word in the error that names what kind of contract broke."
        default:
            let anchor = fallbackVisualAnchor(topicKind: topicKind, lesson: lesson, assetContext: assetContext)
            return "Look at \(anchor) and name the one part that seems to control the rest."
        }
    }

    private static func transferMove(topicKind: String, lesson: LessonSession) -> String {
        switch topicKind {
        case "multiplication":
            return "Now flip the array in your head: if it were 6 rows of 5 instead, would the total change or only the story?"
        case "fractions":
            return "Now transfer it: if two of the four equal spaces were shaded, what fraction would the same bar show?"
        case "derivatives":
            return "Now transfer it: if the tangent line tilted downward instead, what would happen to the derivative's sign?"
        case "code":
            return "Now transfer it: where else in this code could the same contract break?"
        default:
            return "Now try the same idea on a nearby example and say what stays the same."
        }
    }

    private static func teachBackMove(topicKind: String, lesson: LessonSession) -> String {
        switch topicKind {
        case "multiplication":
            return "Say it back in your own words: how does the array let you know the total without counting every dot?"
        case "fractions":
            return "Say it back in your own words: what does the numerator count, and what does the denominator keep visible?"
        case "derivatives":
            return "Say it back in your own words: why does the tangent line tell us the derivative at one point?"
        case "code":
            return "Say it back in your own words: what contract broke, and what kind of fix would respect that contract?"
        default:
            let topic = lesson.topic.isEmpty ? "this idea" : lesson.topic
            return "Say \(topic) back in your own words using the visible example, not a memorized definition."
        }
    }

    private static func fallbackLearnerGap(topicKind: String, lesson: LessonSession) -> String {
        let latestLearnerText = latestLearnerText(for: lesson)
        switch topicKind {
        case "multiplication":
            if containsAny(latestLearnerText, ["25", "twenty five", "twenty-five"]) {
                return "The learner may be using rows as both the number of groups and the size of each group."
            }
            return "The learner may be counting objects one by one instead of seeing repeated structure."
        case "fractions":
            if containsAny(latestLearnerText, ["empty doesn't matter", "empty does not matter", "only the shaded", "just shaded"]) {
                return "The learner may be dropping unshaded parts from the whole, which makes the denominator disappear."
            }
            return "The learner may be counting shaded parts without keeping the whole partition visible."
        case "derivatives":
            if containsAny(latestLearnerText, ["height", "y value", "where the curve is"]) {
                return "The learner may be reading the function's height instead of the tangent's slope."
            }
            return "The learner may be thinking about the whole curve instead of the local tangent."
        case "code":
            return "The learner may be trying fixes before identifying the broken contract."
        default:
            return lesson.phase == .repairingConfusion
                ? "The learner needs a smaller concrete handle before the abstraction."
                : "The learner needs the visible anchor connected to the abstract idea."
        }
    }

    private static func coreIdea(topicKind: String, lesson: LessonSession) -> String {
        switch topicKind {
        case "multiplication": return "multiplication as repeated visible structure"
        case "fractions": return "fractions as shaded parts inside one equal partition"
        case "derivatives": return "derivative as local slope"
        case "code": return "error as a violated contract"
        default: return lesson.topic.isEmpty ? "make the visible idea concrete" : "make \(lesson.topic) visible"
        }
    }

    private static func fallbackVisualAnchor(
        topicKind: String,
        lesson: LessonSession,
        assetContext: LearningAssetContext
    ) -> String {
        if let browserTitle = assetContext.browserTitle, !browserTitle.isEmpty { return browserTitle }
        if let firstFile = assetContext.selectedFilePaths.first {
            return URL(fileURLWithPath: firstFile).lastPathComponent
        }
        switch topicKind {
        case "multiplication": return "the rows and dots on the array"
        case "fractions": return "the whole bar and its equal spaces"
        case "derivatives": return "the tangent line touching the curve"
        case "code": return "the visible error and the line it points to"
        default: return lesson.topic.isEmpty ? "the visible screen" : lesson.topic
        }
    }

    private static func memoryCandidate(
        topicKind: String,
        assessment: TeacherQualityAssessment,
        lesson: LessonSession
    ) -> String? {
        if assessment.flags.contains(.needsStyleSwitch) {
            return "User benefits from a different explanation style when the first pass does not land."
        }
        if assessment.flags.contains(.readyForTransfer) {
            return "User is ready to transfer \(topicKind) to a nearby example."
        }
        if assessment.flags.contains(.readyForTeachBack) {
            return "User is ready to explain \(topicKind) back in their own words."
        }
        return nil
    }

    private static func curriculumMilestones(topicKind: String) -> [String] {
        switch topicKind {
        case "multiplication":
            return [
                "make the first visible connection",
                "separate number of groups from size of each group",
                "answer one prediction from the visual anchor",
                "repair the smallest misconception with a changed explanation style",
                "transfer the idea to a nearby example",
                "explain the idea back in their own words",
                "consolidate the learner's wording into a durable memory"
            ]
        case "fractions":
            return [
                "make the first visible connection",
                "keep the whole partition visible",
                "answer one prediction from the visual anchor",
                "repair the smallest misconception with a changed explanation style",
                "transfer the idea to a nearby example",
                "explain the idea back in their own words",
                "consolidate the learner's wording into a durable memory"
            ]
        case "derivatives":
            return [
                "make the first visible connection",
                "separate height from local slope",
                "answer one prediction from the visual anchor",
                "repair the smallest misconception with a changed explanation style",
                "transfer the idea to a nearby example",
                "explain the idea back in their own words",
                "consolidate the learner's wording into a durable memory"
            ]
        case "code":
            return [
                "make the first visible connection",
                "name the broken contract",
                "answer one prediction from the visual anchor",
                "repair the smallest misconception with a changed explanation style",
                "transfer the idea to a nearby example",
                "explain the idea back in their own words",
                "consolidate the learner's wording into a durable memory"
            ]
        default:
            return [
                "make the first visible connection",
                "answer one prediction from the visual anchor",
                "repair the smallest misconception with a changed explanation style",
                "transfer the idea to a nearby example",
                "explain the idea back in their own words",
                "consolidate the learner's wording into a durable memory"
            ]
        }
    }

    private static func currentCurriculumMilestone(
        for lesson: LessonSession,
        milestones: [String]
    ) -> String {
        let repairMilestone = "repair the smallest misconception with a changed explanation style"
        if lesson.phase == .repairingConfusion || !lesson.confusionSignals.isEmpty {
            return repairMilestone
        }

        let masteryMilestone = lesson.mastery.nextMilestone.trimmingCharacters(in: .whitespacesAndNewlines)
        if !masteryMilestone.isEmpty,
           let matchingMilestone = milestones.first(where: { $0 == masteryMilestone }) {
            return matchingMilestone
        }

        switch lesson.mastery.confidence {
        case 0..<25:
            return "make the first visible connection"
        case 25..<55:
            return milestones.contains("answer one prediction from the visual anchor")
                ? "answer one prediction from the visual anchor"
                : milestones[min(1, milestones.count - 1)]
        case 55..<80:
            return "transfer the idea to a nearby example"
        default:
            return "explain the idea back in their own words"
        }
    }

    private static func upcomingCurriculumMilestones(
        after currentMilestone: String,
        milestones: [String],
        lesson: LessonSession
    ) -> [String] {
        let currentIndex = milestones.firstIndex(of: currentMilestone) ?? 0
        var upcoming = Array(milestones.dropFirst(currentIndex + 1))
        if lesson.phase == .repairingConfusion || !lesson.confusionSignals.isEmpty {
            let transferMilestone = "transfer the idea to a nearby example"
            if !upcoming.contains(transferMilestone) {
                upcoming.insert(transferMilestone, at: 0)
            }
        }
        return Array(upcoming.prefix(4))
    }

    private static func diagnosticQuestion(topicKind: String, lesson: LessonSession) -> String {
        switch topicKind {
        case "multiplication":
            return "Which number is the number of groups, and which number is the size of one group?"
        case "fractions":
            return "Which spaces count as the whole, including the unshaded parts?"
        case "derivatives":
            return "Is the learner reading the point's height, or the tangent line's local slope?"
        case "code":
            return "What contract did the error say was broken, and where is the first mismatch?"
        default:
            let topic = lesson.topic.isEmpty ? "the idea" : lesson.topic
            return "What visible part of \(topic) can the learner explain before the abstraction?"
        }
    }

    private static func repetitionPlan(topicKind: String, lesson: LessonSession) -> String {
        if lesson.phase == .repairingConfusion || !lesson.confusionSignals.isEmpty {
            return "Change style away from \(lesson.arcState.lastExplanationStyle.rawValue), shrink to one visible anchor, then ask one repair question before moving on."
        }
        if lesson.mastery.confidence >= 82 {
            return "Ask for teach-back, preserve the learner's wording, and consolidate the useful phrasing."
        }
        if lesson.mastery.confidence >= 55 {
            return "Use one transfer example and compare what changes against what stays the same."
        }
        if lesson.turnCount == 0 {
            return "Start concrete: show the object, name the hidden pattern, and ask one prediction."
        }
        return "Alternate visible anchor, prediction, feedback, and one-sentence recap until evidence improves."
    }

    private static func nextMilestone(for confidence: Int, topic: String) -> String {
        switch confidence {
        case 0..<25:
            return "make the first visible connection"
        case 25..<55:
            return "answer one prediction from the visual anchor"
        case 55..<80:
            return "transfer the idea to a nearby example"
        default:
            return "explain the idea back in their own words"
        }
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

    private static func appendEvidence(_ evidence: String, to list: inout [String]) {
        if !list.contains(evidence) {
            list.append(evidence)
        }
    }

    private static func appendCompleted(_ step: LessonArcStep, to list: inout [LessonArcStep]) {
        if !list.contains(step) {
            list.append(step)
        }
    }

    private static func latestLearnerText(for lesson: LessonSession) -> String {
        let pieces = [
            lesson.recentAnswers.last,
            lesson.confusionSignals.last,
            lesson.misconceptions.last
        ]
        return pieces.compactMap { $0 }.joined(separator: " ").lowercased()
    }

    private static func showsTopicProgress(_ text: String, topic: String) -> Bool {
        let normalizedTopic = topic.lowercased()
        if containsAny(normalizedTopic, ["multiplication", "multiply", "times", "array"]) {
            return containsAny(text, ["30", "thirty", "row", "rows", "groups", "times", "5 x 6", "5 times 6", "six rows", "stays 30"])
        }
        if containsAny(normalizedTopic, ["fraction", "numerator", "denominator"]) {
            return containsAny(text, ["denominator", "numerator", "whole", "equal", "four", "fourths", "2/4", "two fourths", "half"])
        }
        if containsAny(normalizedTopic, ["derivative", "slope", "tangent", "calculus"]) {
            return containsAny(text, ["slope", "tangent", "positive", "negative", "zero", "steeper", "rate"])
        }
        if containsAny(normalizedTopic, ["code", "xcode", "error"]) {
            return containsAny(text, ["because", "type", "nil", "contract", "expected", "actual", "signature"])
        }
        return containsAny(text, ["because", "so ", "means", "therefore", "same idea"])
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
            "wrong",
            "no idea"
        ])
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }
}
