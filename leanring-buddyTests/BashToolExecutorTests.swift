import XCTest
@testable import ipop_ai

final class BashToolExecutorTests: XCTestCase {
    func testHighOutputCommandDrainsAndTruncatesWithoutDeadlock() async {
        let executor = BashToolExecutor(timeoutSeconds: 5)

        let result = await executor.runShellCommand("/usr/bin/yes x | /usr/bin/head -c 700000")

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.textContent.contains("[truncated"))
        XCTAssertLessThan(result.textContent.count, 9_000)
    }
}
