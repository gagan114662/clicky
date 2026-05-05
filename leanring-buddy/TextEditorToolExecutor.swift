import Foundation

/// Implements the `str_replace_based_edit_tool` subset Claude expects.
/// Maintains a per-file undo stack in memory for the lifetime of the process.
actor TextEditorToolExecutor {
    private var undoStackPerFilePath: [String: [String]] = [:]

    func executeView(atPath filePath: String, lineRangeIfAny: (Int, Int)?) async -> ToolExecutionResult {
        guard let contents = try? String(contentsOfFile: filePath, encoding: .utf8) else {
            return ToolExecutionResult(toolUseId: "",
                                       isError: true,
                                       textContent: "Cannot read \(filePath)",
                                       imageDataIfAny: nil)
        }
        if let range = lineRangeIfAny {
            let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
            let startIndex = max(0, range.0 - 1)
            let endIndexExclusive = min(lines.count, range.1)
            let slice = lines[startIndex..<endIndexExclusive].joined(separator: "\n")
            return ToolExecutionResult(toolUseId: "", isError: false,
                                       textContent: slice, imageDataIfAny: nil)
        }
        return ToolExecutionResult(toolUseId: "", isError: false,
                                   textContent: contents, imageDataIfAny: nil)
    }

    func executeCreate(atPath filePath: String, contents: String) async -> ToolExecutionResult {
        do {
            let parentDirectoryURL = URL(fileURLWithPath: filePath).deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentDirectoryURL,
                                                    withIntermediateDirectories: true)
            try contents.write(toFile: filePath, atomically: true, encoding: .utf8)
            undoStackPerFilePath[filePath] = []  // creation has nothing to undo to
            return ToolExecutionResult(toolUseId: "", isError: false,
                                       textContent: "Created \(filePath)", imageDataIfAny: nil)
        } catch {
            return ToolExecutionResult(toolUseId: "", isError: true,
                                       textContent: "Failed to create: \(error.localizedDescription)",
                                       imageDataIfAny: nil)
        }
    }

    func executeStrReplace(atPath filePath: String,
                           oldString: String,
                           newString: String) async -> ToolExecutionResult {
        guard let original = try? String(contentsOfFile: filePath, encoding: .utf8) else {
            return ToolExecutionResult(toolUseId: "", isError: true,
                                       textContent: "Cannot read \(filePath)",
                                       imageDataIfAny: nil)
        }
        let occurrenceCount = original.components(separatedBy: oldString).count - 1
        if occurrenceCount == 0 {
            return ToolExecutionResult(toolUseId: "", isError: true,
                                       textContent: "old_string not found in \(filePath)",
                                       imageDataIfAny: nil)
        }
        if occurrenceCount > 1 {
            return ToolExecutionResult(toolUseId: "", isError: true,
                                       textContent: "old_string matches multiple (\(occurrenceCount)) locations — disambiguate",
                                       imageDataIfAny: nil)
        }
        let updated = original.replacingOccurrences(of: oldString, with: newString)
        do {
            try updated.write(toFile: filePath, atomically: true, encoding: .utf8)
            var stack = undoStackPerFilePath[filePath] ?? []
            stack.append(original)
            undoStackPerFilePath[filePath] = stack
            return ToolExecutionResult(toolUseId: "", isError: false,
                                       textContent: "Replaced 1 occurrence in \(filePath)",
                                       imageDataIfAny: nil)
        } catch {
            return ToolExecutionResult(toolUseId: "", isError: true,
                                       textContent: "Write failed: \(error.localizedDescription)",
                                       imageDataIfAny: nil)
        }
    }

    func executeInsert(atPath filePath: String, lineNumber: Int, insertedText: String) async -> ToolExecutionResult {
        guard let original = try? String(contentsOfFile: filePath, encoding: .utf8) else {
            return ToolExecutionResult(toolUseId: "", isError: true,
                                       textContent: "Cannot read \(filePath)", imageDataIfAny: nil)
        }
        var lines = original.components(separatedBy: "\n")
        let clampedIndex = max(0, min(lineNumber, lines.count))
        lines.insert(insertedText, at: clampedIndex)
        let updated = lines.joined(separator: "\n")
        do {
            try updated.write(toFile: filePath, atomically: true, encoding: .utf8)
            var stack = undoStackPerFilePath[filePath] ?? []
            stack.append(original)
            undoStackPerFilePath[filePath] = stack
            return ToolExecutionResult(toolUseId: "", isError: false,
                                       textContent: "Inserted at line \(lineNumber)", imageDataIfAny: nil)
        } catch {
            return ToolExecutionResult(toolUseId: "", isError: true,
                                       textContent: "Write failed: \(error.localizedDescription)",
                                       imageDataIfAny: nil)
        }
    }

    func executeUndoEdit(atPath filePath: String) async -> ToolExecutionResult {
        guard var stack = undoStackPerFilePath[filePath], let previous = stack.popLast() else {
            return ToolExecutionResult(toolUseId: "", isError: true,
                                       textContent: "No undo history for \(filePath)",
                                       imageDataIfAny: nil)
        }
        do {
            try previous.write(toFile: filePath, atomically: true, encoding: .utf8)
            undoStackPerFilePath[filePath] = stack
            return ToolExecutionResult(toolUseId: "", isError: false,
                                       textContent: "Undid last edit", imageDataIfAny: nil)
        } catch {
            return ToolExecutionResult(toolUseId: "", isError: true,
                                       textContent: "Restore failed: \(error.localizedDescription)",
                                       imageDataIfAny: nil)
        }
    }
}
