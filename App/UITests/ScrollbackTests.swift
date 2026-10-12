import XCTest

/// Loads earlier output in a shell pane with scrollback (HERDR_TEST_PANE,
/// default w1:p2) and checks the history and the Live divider appear.
final class ScrollbackTests: XCTestCase {
    @MainActor
    func testLoadEarlierOutput() throws {
        let env = ProcessInfo.processInfo.environment
        let app = XCUIApplication()
        app.launchEnvironment["HERDR_PAIR_LINK"] = try XCTUnwrap(env["HERDR_PAIR_LINK"])
        app.launchEnvironment["HERDR_OPEN_PANE"] = env["HERDR_TEST_PANE"] ?? "w1:p2"
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 8) { allow.tap() }

        // Open it the way a person would if the launch hook didn't: its workspace, then swipe to it.
        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS '2 panes'")).firstMatch
        if row.waitForExistence(timeout: 10) {
            row.tap()
            let counter = app.staticTexts["2/2"]
            for _ in 0..<3 where !counter.exists { app.swipeLeft() }
        }

        // Scrolling to the top either shows the button or, by pulling past the
        // top, already loads the history (pull to load).
        let load = app.buttons["Load earlier output"]
        let live = app.staticTexts["Live"]
        for _ in 0..<12 where !load.isHittable && !live.exists {
            app.swipeDown(velocity: .fast)
        }
        save(app, "scrollback-top")
        if !live.exists, load.isHittable { load.tap() }
        XCTAssertTrue(live.waitForExistence(timeout: 15), "history didn't load")
        // It stays at the seam (newest history just above the live screen), not the top.
        let seam = NSPredicate(format: "hittable == true")
        expectation(for: seam, evaluatedWith: live)
        waitForExpectations(timeout: 5)
        save(app, "scrollback-seam")
        for _ in 0..<3 { app.swipeDown(velocity: .fast) }
        save(app, "scrollback-older")
    }

    @MainActor
    private func save(_ app: XCUIApplication, _ name: String) {
        if let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] {
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        }
    }

    /// Claude Code pane: earlier output comes from Claude's session transcript.
    @MainActor
    func testClaudeTranscript() throws {
        let env = ProcessInfo.processInfo.environment
        let app = XCUIApplication()
        app.launchEnvironment["HERDR_PAIR_LINK"] = try XCTUnwrap(env["HERDR_PAIR_LINK"])
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 8) { allow.tap() }

        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", env["HERDR_CLAUDE_WORKSPACE"] ?? "TraceBot, 1 tab")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        let load = app.buttons["Load earlier output"]
        let live = app.staticTexts["Live"]
        for _ in 0..<12 where !load.isHittable && !live.exists { app.swipeDown(velocity: .fast) }
        if !live.exists, load.isHittable { load.tap() }
        XCTAssertTrue(live.waitForExistence(timeout: 15), "transcript didn't load")
        XCTAssertFalse(app.staticTexts["No earlier output"].exists)
        for _ in 0..<2 { app.swipeDown() }
        save(app, "claude-transcript")
    }
}
