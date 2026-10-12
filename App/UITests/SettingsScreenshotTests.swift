import XCTest

/// Opens Settings and saves a screenshot of the Live Activity section (SCREENSHOT_DIR).
final class SettingsScreenshotTests: XCTestCase {
    @MainActor
    func testSettingsShowsLiveActivitySection() throws {
        let link = try XCTUnwrap(ProcessInfo.processInfo.environment["HERDR_PAIR_LINK"])
        let app = XCUIApplication()
        app.launchEnvironment["HERDR_PAIR_LINK"] = link
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 8) { allow.tap() }

        app.buttons["Settings"].firstMatch.tap()
        let toggle = app.switches["Show while agents are busy"]
        for _ in 0..<4 where !toggle.isHittable { app.swipeUp() }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        if let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] {
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(dir)/settings-live.png"))
        }
    }
}
