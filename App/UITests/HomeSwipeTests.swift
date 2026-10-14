import XCTest

/// Drives the home grid against the live gateway. Needs HERDR_PAIR_LINK in the
/// test environment (TEST_RUNNER_HERDR_PAIR_LINK when run from xcodebuild).
final class HomeSwipeTests: XCTestCase {
    @MainActor
    func testWorkspaceTileMenuShowsActions() throws {
        let link = try XCTUnwrap(ProcessInfo.processInfo.environment["HERDR_PAIR_LINK"])
        let app = XCUIApplication()
        app.launchEnvironment["HERDR_PAIR_LINK"] = link
        app.launch()

        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS 'TraceBot'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        sleep(2)
        save(app, "home")
        row.press(forDuration: 1.2)
        save(app, "tile-menu")
        XCTAssertTrue(app.buttons["Rename"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Close Workspace"].exists)
    }

    @MainActor
    private func save(_ app: XCUIApplication, _ name: String) {
        if let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] {
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        }
    }
}
