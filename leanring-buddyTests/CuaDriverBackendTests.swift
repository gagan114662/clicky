import XCTest
@testable import ipop_ai

final class CuaDriverBackendTests: XCTestCase {
    func testKeyCommandBuildsHotkey() {
        XCTAssertEqual(
            CuaDriverBackend.keyCommand(from: "cmd+shift+t"),
            .hotkey(keys: ["cmd", "shift", "t"])
        )
    }

    func testKeyCommandBuildsSinglePressKey() {
        XCTAssertEqual(
            CuaDriverBackend.keyCommand(from: "Enter"),
            .pressKey(key: "return")
        )
    }

    func testKeyCommandRejectsUnknownKey() {
        XCTAssertNil(CuaDriverBackend.keyCommand(from: "cmd+launchpad"))
    }

    func testCommandEncodesToolNameAndSortedJSONArguments() throws {
        let command = try XCTUnwrap(CuaDriverClient.makeCommand(
            executablePath: "/tmp/cua-driver",
            toolName: "type_text",
            jsonArguments: ["text": "hello", "pid": 123]
        ))

        XCTAssertEqual(command.executablePath, "/tmp/cua-driver")
        XCTAssertEqual(command.arguments.first, "type_text")

        let json = try XCTUnwrap(command.arguments.dropFirst().first)
        let data = try XCTUnwrap(json.data(using: .utf8))
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(decoded?["text"] as? String, "hello")
        XCTAssertEqual(decoded?["pid"] as? Int, 123)
    }
}
