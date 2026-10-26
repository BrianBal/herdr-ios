import XCTest

/// Split, new tab and close from the pane menu, in a throwaway shell
/// workspace ("ios-split-test"; the host closes it afterwards).
final class PaneActionsTests: XCTestCase {
    @MainActor
    func testSplitNewTabAndClose() throws {
        let env = ProcessInfo.processInfo.environment
        let app = XCUIApplication()
        app.launchEnvironment["HERDR_PAIR_LINK"] = try XCTUnwrap(env["HERDR_PAIR_LINK"])
        app.launchEnvironment["HERDR_RESET_GATEWAYS"] = "1"
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 8) { allow.tap() }

        let plus = app.buttons["New workspace"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: plus)
        waitForExpectations(timeout: 20)
        plus.tap()
        let name = app.textFields["Name (optional)"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.typeText("ios-split-test")
        app.buttons["~/labs/ios-herdr"].firstMatch.tap()
        // A shell, not the default agent: never start one by accident.
        let start = app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Start'")).firstMatch
        for _ in 0..<4 where !start.isHittable { app.swipeUp() }
        XCTAssertTrue(start.waitForExistence(timeout: 3), "no agent picker")
        start.tap()
        let shell = app.buttons["Just a shell"].firstMatch
        XCTAssertTrue(shell.waitForExistence(timeout: 3), "no Just a shell")
        shell.tap()
        app.buttons["Create"].tap()
        XCTAssertTrue(app.buttons["tabs-button"].waitForExistence(timeout: 15))

        let menu = app.buttons["Pane actions"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        app.buttons["Split right"].tap()
        XCTAssertTrue(app.staticTexts["Split 2 of 2"].waitForExistence(timeout: 10), "didn't land on the new split")
        save(app, "pane-split")

        menu.tap()
        app.buttons["New tab"].tap()
        // Two tabs now: the tab chips appear, and the new tab's single pane is selected.
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label BEGINSWITH '2'")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Split 2 of 2"].exists)
        save(app, "pane-newtab")

        menu.tap()
        app.buttons["Close pane"].tap()
        let confirm = app.buttons["Close Pane"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        // Closing the new tab's only pane closes the tab: back to one tab with two splits.
        XCTAssertTrue(app.staticTexts["Split 2 of 2"].waitForExistence(timeout: 10) || app.staticTexts["Split 1 of 2"].waitForExistence(timeout: 2))
        save(app, "pane-closed")
    }

    @MainActor
    private func save(_ app: XCUIApplication, _ name: String) {
        if let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] {
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        }
    }
}
