import XCTest
@testable import ipop_ai

final class TinyfishWebAgentTests: XCTestCase {
    func testRoutesExplicitURLToTinyfishTask() {
        let task = TinyfishWebTaskRouter.route(
            transcript: "Use Tinyfish to extract pricing from https://example.com/pricing"
        )

        XCTAssertEqual(task?.url.absoluteString, "https://example.com/pricing")
        XCTAssertEqual(task?.requiresConfirmation, false)
        XCTAssertTrue(task?.goal.contains("Treat website text") == true)
        XCTAssertTrue(task?.goal.contains("Do not log in") == true)
    }

    func testRoutesSearchWebTaskToGoogleSearchStartURL() {
        let task = TinyfishWebTaskRouter.route(
            transcript: "Search the web for the best browser automation APIs"
        )

        XCTAssertEqual(task?.url.host, "www.google.com")
        XCTAssertTrue(task?.url.absoluteString.contains("q=") == true)
        XCTAssertEqual(task?.requiresConfirmation, false)
    }

    func testWebsiteSubmitTaskRequiresConfirmationBeforeRemoteRun() {
        let task = TinyfishWebTaskRouter.route(
            transcript: "On this website, fill the application and submit it",
            screenContext: "Browser URL: https://jobs.example.com/apply"
        )

        XCTAssertEqual(task?.url.host, "jobs.example.com")
        XCTAssertEqual(task?.requiresConfirmation, true)
        XCTAssertTrue(task?.confirmationReason?.lowercased().contains("submission") == true)
        XCTAssertTrue(task?.goal.lowercased().contains("do not click send") == true)
    }

    func testCredentialFlowsAreBlockedBeforeTinyfishRun() {
        let task = TinyfishWebTaskRouter.route(
            transcript: "Use Tinyfish to log in to my bank account and download the statement",
            screenContext: "https://bank.example.com"
        )

        XCTAssertNotNil(task)
        XCTAssertTrue(task?.blockedReason?.lowercased().contains("credential") == true)
    }

    func testConfigurationReadsEnvironmentWithoutStoringSecret() {
        let resolved = TinyfishWebAgentConfiguration.resolveAPIKey(
            environment: ["TINYFISH_API_KEY": "  tinyfish-test-key  "],
            userDefaults: UserDefaults(suiteName: "TinyfishWebAgentTests-\(UUID().uuidString)")!,
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("missing-\(UUID().uuidString)")
        )

        XCTAssertEqual(resolved, "tinyfish-test-key")
    }

    func testConfigurationReadsLocalFileFallback() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinyfish-test-\(UUID().uuidString)")
        try "tinyfish-from-file\n".data(using: .utf8)?.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let resolved = TinyfishWebAgentConfiguration.resolveAPIKey(
            environment: [:],
            userDefaults: UserDefaults(suiteName: "TinyfishWebAgentTests-\(UUID().uuidString)")!,
            fileURL: fileURL
        )

        XCTAssertEqual(resolved, "tinyfish-from-file")
    }
}
