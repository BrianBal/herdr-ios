import XCTest

/// Drives the home list against the live gateway. Needs HERDR_PAIR_LINK in the
/// test environment (TEST_RUNNER_HERDR_PAIR_LINK when run from xcodebuild).
final class HomeSwipeTests: XCTestCase {
    @MainActor
    func testWorkspaceRowSwipeShowsActions() throws {
        let link = try XCTUnwrap(ProcessInfo.processInfo.environment["HERDR_PAIR_LINK"])
        let app = XCUIApplication()
        app.launchEnvironment["HERDR_PAIR_LINK"] = link
        app.launch()

        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS 'TraceBot'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.swipeLeft()
        save(app, "swipe")
        XCTAssertTrue(app.buttons["Rename"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Close"].exists)
    }

    @MainActor
    private func save(_ app: XCUIApplication, _ name: String) {
        if let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] {
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        }
    }
}
