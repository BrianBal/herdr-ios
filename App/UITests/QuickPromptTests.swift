import XCTest

/// Uses a quick prompt in a throwaway shell workspace (no agent, so nothing
/// notifies), then saves a typed command as a new chip. The host closes the
/// "ios-qp-test" workspace afterwards.
final class QuickPromptTests: XCTestCase {
    @MainActor
    func testQuickPromptChips() throws {
        let env = ProcessInfo.processInfo.environment
        let app = XCUIApplication()
        app.launchEnvironment["HERDR_PAIR_LINK"] = try XCTUnwrap(env["HERDR_PAIR_LINK"])
        app.launchEnvironment["HERDR_RESET_GATEWAYS"] = "1"
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 8) { allow.tap() }

        app.createShellWorkspace("ios-qp-test")

        let chip = app.buttons["Send ls -la"]
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "no shell quick prompt chips")
        sleep(3)  // let the new shell reach its prompt
        chip.tap()
        // Short enough not to wrap on a narrow screen (file names do).
        let listing = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS ' staff '")).firstMatch
        XCTAssertTrue(listing.waitForExistence(timeout: 10), "ls output didn't show")

        let field = app.textFields["Run a command…"].exists ? app.textFields["Run a command…"] : app.textViews["Run a command…"]
        field.tap()
        field.typeText("echo quick-prompt-ok")
        let save = app.buttons["Save as quick prompt"]
        XCTAssertTrue(save.waitForExistence(timeout: 3))
        save.tap()
        XCTAssertTrue(app.buttons["Send echo quick-prompt-ok"].waitForExistence(timeout: 3))
        if let dir = env["SCREENSHOT_DIR"] {
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(dir)/quick-prompts.png"))
        }
        // Leave the list as it was.
        app.buttons["Send echo quick-prompt-ok"].press(forDuration: 1.0)
        app.buttons["Remove"].tap()
    }
}
