import Foundation

enum TeacherTurnQualityFlag: String, Equatable {
    case emptyExplanation
    case scriptedPhrase
    case lectureHeavy
    case genericExplanation
    case missingVisualAnchor
    case contextPolluted
}

enum TeacherTurnValidator {
    private static let scriptedPhrases = [
        "checkpoint question",
        "lesson objective",
        "correct answer",
        "quiz time",
        "try again",
        "what is the answer",
        "as an ai"
    ]

    private static let pollutedPhrases = [
        "teachme",
        "this is codex speaking",
        "codex speaking",
        "qa harness",
        "synthetic probe",
        "prompt injection",
        "[system instructions"
    ]

    static func flags(
        for move: TeachingMove,
        lesson: LessonSession,
        assetContext: LearningAssetContext
    ) -> [TeacherTurnQualityFlag] {
        let spoken = move.combinedSpokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = spoken.lowercased()
        var flags: [TeacherTurnQualityFlag] = []

        if spoken.isEmpty {
            flags.append(.emptyExplanation)
        }
        if scriptedPhrases.contains(where: { normalized.contains($0) }) {
            flags.append(.scriptedPhrase)
        }
        if pollutedPhrases.contains(where: { normalized.contains($0) }) {
            flags.append(.contextPolluted)
        }

        let words = normalized.split { !$0.isLetter && !$0.isNumber }
        let sentenceCount = spoken.split(whereSeparator: { ".?!\n".contains($0) }).count
        if words.count > 150 || sentenceCount > 8 {
            flags.append(.lectureHeavy)
        }

        let visualAnchor = move.visualAnchor.trimmingCharacters(in: .whitespacesAndNewlines)
        if visualAnchor.isEmpty && visualAnchorIsAvailable(move: move, assetContext: assetContext) {
            flags.append(.missingVisualAnchor)
        }

        if looksGeneric(spoken, move: move, lesson: lesson) {
            flags.append(.genericExplanation)
        }

        return flags
    }

    static func repairedMove(
        _ move: TeachingMove,
        lesson: LessonSession,
        assetContext: LearningAssetContext
    ) -> TeachingMove {
        let existingFlags = flags(for: move, lesson: lesson, assetContext: assetContext)
        guard !existingFlags.isEmpty else { return move }

        var repaired = move
        repaired.spokenResponse = cleanSpokenExplanation(
            repaired.spokenResponse,
            fallback: fallbackExplanation(for: lesson, assetContext: assetContext)
        )
        repaired.studentMove = cleanOptionalStudentMove(repaired.studentMove ?? repaired.question)
        repaired.question = repaired.studentMove

        if existingFlags.contains(.lectureHeavy) {
            repaired.spokenResponse = shortenedExplanation(repaired.spokenResponse)
        }
        if existingFlags.contains(.missingVisualAnchor) {
            repaired.visualAnchor = inferredVisualAnchor(for: lesson, assetContext: assetContext, move: move)
        }
        if existingFlags.contains(.genericExplanation), repaired.coreIdea.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            repaired.coreIdea = lesson.topic.isEmpty ? "make the visible idea concrete" : "make \(lesson.topic) visible"
        }
        if (repaired.studentMove ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           shouldAddLearnerMove(for: lesson, assetContext: assetContext) {
            repaired.studentMove = fallbackStudentMove(for: lesson, assetContext: assetContext)
            repaired.question = repaired.studentMove
        }

        return repaired
    }

    private static func visualAnchorIsAvailable(
        move: TeachingMove,
        assetContext: LearningAssetContext
    ) -> Bool {
        if case .prepareFreeformDiagram = move.surfaceAction {
            return true
        }
        switch assetContext.assetType {
        case .youtube, .browserPage, .localDocument, .whiteboard, .code:
            return true
        case .screen:
            return !assetContext.screenContextLines.isEmpty
        case .unknown:
            return false
        }
    }

    private static func looksGeneric(
        _ spoken: String,
        move: TeachingMove,
        lesson: LessonSession
    ) -> Bool {
        let normalized = spoken.lowercased()
        guard !normalized.isEmpty else { return false }
        let topicWords = lesson.topic.lowercased().split { !$0.isLetter && !$0.isNumber }
        let mentionsTopic = topicWords.contains { $0.count > 3 && normalized.contains($0) }
        let hasPointTarget = move.pointTarget.map {
            let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !trimmed.isEmpty && !trimmed.hasPrefix("none")
        } ?? false
        let hasConcreteMove = !move.visualAnchor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || hasPointTarget
            || move.surfaceAction != nil
        let genericOpeners = [
            "this concept is",
            "the key is to understand",
            "let's break it down",
            "it is important to"
        ]
        return !mentionsTopic && !hasConcreteMove && genericOpeners.contains(where: { normalized.contains($0) })
    }

    private static func cleanSpokenExplanation(_ text: String, fallback: String) -> String {
        let cleanedLines = text
            .components(separatedBy: .newlines)
            .map(cleanLine)
            .filter { !$0.isEmpty }
        let cleaned = cleanedLines.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? fallback : cleaned
    }

    private static func cleanLine(_ line: String) -> String {
        let normalized = line.lowercased()
        if pollutedPhrases.contains(where: { normalized.contains($0) }) {
            return ""
        }
        var cleaned = line
        for phrase in scriptedPhrases {
            cleaned = cleaned.replacingOccurrences(of: phrase, with: "", options: .caseInsensitive)
        }
        return cleaned
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".:;-")))
    }

    private static func cleanOptionalStudentMove(_ text: String?) -> String? {
        guard let text else { return nil }
        let cleaned = cleanSpokenExplanation(text, fallback: "")
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func shortenedExplanation(_ text: String) -> String {
        let sentenceSeparators = CharacterSet(charactersIn: ".?!")
        let sentences = text
            .components(separatedBy: sentenceSeparators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard sentences.count > 5 else { return text }
        return sentences.prefix(5).joined(separator: ". ") + "."
    }

    private static func fallbackExplanation(
        for lesson: LessonSession,
        assetContext: LearningAssetContext
    ) -> String {
        let anchor = inferredVisualAnchor(for: lesson, assetContext: assetContext, move: nil)
        if lesson.topic.lowercased().contains("fraction") {
            return "Use the visible parts as the guide. The numerator counts what you have, and the denominator names how many equal pieces the whole was cut into."
        }
        if lesson.topic.lowercased().contains("derivative") {
            return "Start at the point on the curve. The derivative is the slope of the tiny straight-line guess at that exact spot."
        }
        if lesson.topic.lowercased().contains("multiplication") {
            return "Use the array instead of counting one by one. Rows tell you how many groups there are, and the dots in one row tell you the size of each group."
        }
        return "Use \(anchor) as the anchor. The goal is to connect one visible part to the bigger idea, then make one small prediction from it."
    }

    private static func inferredVisualAnchor(
        for lesson: LessonSession,
        assetContext: LearningAssetContext,
        move: TeachingMove?
    ) -> String {
        if case .prepareFreeformDiagram(let spec) = move?.surfaceAction {
            return spec.title
        }
        if let browserTitle = assetContext.browserTitle, !browserTitle.isEmpty {
            return browserTitle
        }
        if let firstPath = assetContext.selectedFilePaths.first {
            return URL(fileURLWithPath: firstPath).lastPathComponent
        }
        if assetContext.assetType == .whiteboard {
            return "the visible board"
        }
        if assetContext.assetType == .code {
            return "the visible code or error"
        }
        return lesson.topic.isEmpty ? "the visible screen" : lesson.topic
    }

    private static func shouldAddLearnerMove(
        for lesson: LessonSession,
        assetContext: LearningAssetContext
    ) -> Bool {
        lesson.phase != .evaluatingAnswer || assetContext.assetType != .unknown
    }

    private static func fallbackStudentMove(
        for lesson: LessonSession,
        assetContext: LearningAssetContext
    ) -> String {
        let anchor = inferredVisualAnchor(for: lesson, assetContext: assetContext, move: nil)
        if lesson.topic.lowercased().contains("fraction") {
            return "Point your eyes at the whole first: how many equal spaces are there, including the empty ones?"
        }
        if lesson.topic.lowercased().contains("derivative") {
            return "Look at the tangent line and predict whether the derivative there should be positive, negative, or zero."
        }
        if lesson.topic.lowercased().contains("multiplication") {
            return "Look at one row first: how many dots are in that single row?"
        }
        return "Look at \(anchor) and name the one part that seems to control the rest."
    }
}
