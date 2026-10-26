import XCTest

/// Creates a workspace with Claude Code and a first prompt through the UI.
/// The host checks herdr afterwards and closes the workspace (it's real).
final class NewWorkspaceAgentTests: XCTestCase {
    @MainActor
    func testCreateWorkspaceWithAgent() throws {
        let env = ProcessInfo.processInfo.environment
        let app = XCUIApplication()
        app.launchEnvironment["HERDR_PAIR_LINK"] = try XCTUnwrap(env["HERDR_PAIR_LINK"])
        app.launchEnvironment["HERDR_RESET_GATEWAYS"] = "1"
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 8) { allow.tap() }

        let plus = app.buttons["New workspace"]
        XCTAssertTrue(plus.waitForExistence(timeout: 15))
        // Enabled once connected.
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: plus)
        waitForExpectations(timeout: 15)
        plus.tap()

        let name = app.textFields["Name (optional)"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.typeText("ios-agent-test")
        app.buttons["~/labs/ios-herdr"].firstMatch.tap()

        // The agent and prompt are further down the sheet; on a small screen, a few swipes.
        let start = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Claude Code'")).firstMatch
        let promptView = app.textViews["First prompt (optional)"]
        let promptField = app.textFields["First prompt (optional)"]
        for _ in 0..<4 where !(promptView.isHittable || promptField.isHittable) { app.swipeUp() }
        save(app, "new-workspace-scrolled")
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        let prompt = promptView.exists ? promptView : promptField
        prompt.tap()
        prompt.typeText("Reply with just the word ready")
        save(app, "new-workspace-sheet")
        let create = app.buttons["Create"]
        for _ in 0..<3 where !create.isHittable { app.swipeDown() }
        create.tap()

        XCTAssertTrue(app.buttons["tabs-button"].waitForExistence(timeout: 15), "workspace didn't open")
        sleep(25)  // agent starts, then the prompt goes in once it's ready
        save(app, "new-workspace-agent")
        XCTAssertFalse(app.alerts["Action failed"].exists, app.alerts.firstMatch.label)
    }

    @MainActor
    private func save(_ app: XCUIApplication, _ name: String) {
        if let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] {
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        }
    }
}
