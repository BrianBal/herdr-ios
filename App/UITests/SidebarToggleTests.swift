import XCTest

/// Unfolded Duo (regular width on a phone): the Workspaces button in the rail
/// (landscape) or split header (portrait) opens and closes the sidebar every
/// time, after rotating too. Opens HERDR_TEST_PANE (default w3:p1).
final class SidebarToggleTests: XCTestCase {
    @MainActor
    func testWorkspacesButtonTogglesSidebar() throws {
        let env = ProcessInfo.processInfo.environment
        let app = XCUIApplication()
        app.launchEnvironment["HERDR_PAIR_LINK"] = try XCTUnwrap(env["HERDR_PAIR_LINK"])
        app.launchEnvironment["HERDR_OPEN_PANE"] = env["HERDR_TEST_PANE"] ?? "w3:p1"
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 8) { allow.tap() }

        let button = app.buttons["Workspaces"]
        // The sidebar's section header; only on screen while the sidebar is.
        let sidebar = app.staticTexts["Workspaces"]

        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait, .landscapeRight, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            XCTAssertTrue(button.waitForExistence(timeout: 10), "no Workspaces button in \(orientation.rawValue)")
            sleep(1)
            for attempt in 0..<4 {
                let wasShown = sidebar.isHittable
                // Near the side, not on the glyph: the whole target should count.
                button.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.6)).tap()
                var flipped = false
                for _ in 0..<15 where !flipped {
                    usleep(200_000)
                    flipped = sidebar.isHittable != wasShown
                }
                print("SIDEBAR orientation=\(orientation.rawValue) attempt=\(attempt) wasShown=\(wasShown) flipped=\(flipped) buttonHittable=\(button.isHittable) frame=\(button.frame)")
                XCTAssertTrue(flipped, "tap \(attempt) in orientation \(orientation.rawValue) didn't \(wasShown ? "close" : "open") the sidebar")
                save(app, "sidebar-\(orientation.rawValue)-\(attempt)")
                // Portrait slides the sidebar over the workspace; close it by its own button, as a person would.
                if sidebar.isHittable, !button.isHittable { app.buttons["Hide Sidebar"].firstMatch.tap(); sleep(1) }
            }
        }
    }

    @MainActor
    private func save(_ app: XCUIApplication, _ name: String) {
        if let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] {
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        }
    }
}
