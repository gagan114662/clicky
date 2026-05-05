import XCTest
@testable import ipop_ai

final class TextEditorToolExecutorTests: XCTestCase {
    func testStrReplaceReplacesUniqueOccurrence() async throws {
        let testFileURL = makeTempFile(contents: "hello world\nhello swift\n")
        let executor = TextEditorToolExecutor()
        let result = await executor.executeStrReplace(
            atPath: testFileURL.path,
            oldString: "hello swift",
            newString: "hello macOS"
        )
        XCTAssertFalse(result.isError, result.textContent)
        let updated = try String(contentsOf: testFileURL, encoding: .utf8)
        XCTAssertEqual(updated, "hello world\nhello macOS\n")
    }

    func testStrReplaceFailsOnAmbiguousMatch() async throws {
        let testFileURL = makeTempFile(contents: "x\nx\n")
        let executor = TextEditorToolExecutor()
        let result = await executor.executeStrReplace(
            atPath: testFileURL.path,
            oldString: "x",
            newString: "y"
        )
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.textContent.contains("multiple"))
    }

    func testUndoRestoresPreviousContents() async throws {
        let testFileURL = makeTempFile(contents: "hello\n")
        let executor = TextEditorToolExecutor()
        _ = await executor.executeStrReplace(atPath: testFileURL.path,
                                             oldString: "hello",
                                             newString: "goodbye")
        let undoResult = await executor.executeUndoEdit(atPath: testFileURL.path)
        XCTAssertFalse(undoResult.isError)
        let restored = try String(contentsOf: testFileURL, encoding: .utf8)
        XCTAssertEqual(restored, "hello\n")
    }

    private func makeTempFile(contents: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try! contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
