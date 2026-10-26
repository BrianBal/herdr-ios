import XCTest

/// The Safari-style flow against live gateways: open a card, swipe between
/// panes, back to the tabs, open a card on another machine. Needs the app
/// paired with two machines (HERDR_PAIR_LINK adds one); HERDR_TEST_TAB and
/// HERDR_TEST_OTHER_TAB name a card on each (defaults: dragon, tracebot).
final class TabsFlowTests: XCTestCase {
    @MainActor
    func testOpenSwipeAndSwitchTabs() throws {
        let env = ProcessInfo.processInfo.environment
        let app = XCUIApplication()
        if let link = env["HERDR_PAIR_LINK"] { app.launchEnvironment["HERDR_PAIR_LINK"] = link }
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 5) { allow.tap() }

        let card = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", env["HERDR_TEST_TAB"] ?? "dragon")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20), "no card")
        save(app, "flow-0-tabs")
        card.tap()

        let tabs = app.buttons["tabs-button"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 10), "workspace didn't open")
        let output = app.scrollViews["pane-output"].firstMatch
        XCTAssertTrue(output.waitForExistence(timeout: 10))
        sleep(2)
        save(app, "flow-1-open")

        // Scrolling the terminal down and up must not dismiss the workspace.
        output.swipeDown()
        output.swipeDown()
        sleep(1)
        XCTAssertTrue(tabs.exists, "swiping the output dismissed the workspace")
        output.swipeUp()
        save(app, "flow-2-scrolled")

        // Swipe to the next pane, when there is one.
        output.swipeLeft()
        sleep(1)
        XCTAssertTrue(tabs.exists)
        save(app, "flow-3-swiped")

        tabs.tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5), "tabs didn't come back")
        sleep(1)
        save(app, "flow-4-back")

        let other = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", env["HERDR_TEST_OTHER_TAB"] ?? "tracebot")).element(boundBy: 0)
        // The other machine's cards are further down.
        for _ in 0..<4 where !other.isHittable { app.swipeUp() }
        XCTAssertTrue(other.waitForExistence(timeout: 5))
        other.tap()
        XCTAssertTrue(tabs.waitForExistence(timeout: 10))
        sleep(3)
        save(app, "flow-5-other")
        tabs.tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertTrue(tabs.waitForExistence(timeout: 5), "Done didn't reopen the tab")
        save(app, "flow-6-done")
    }

    @MainActor
    private func save(_ app: XCUIApplication, _ name: String) {
        if let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] {
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        }
    }
}
