import XCTest

/// Taps a delivered notification and checks the app opens its pane. The host
/// sends the push with `xcrun simctl push` while this waits (see the note in
/// the test); HERDR_PAIR_LINK as for HomeSwipeTests.
final class NotificationTapTests: XCTestCase {
    @MainActor
    func testTappingNotificationOpensPane() throws {
        let link = try XCTUnwrap(ProcessInfo.processInfo.environment["HERDR_PAIR_LINK"])
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let app = XCUIApplication()
        app.launchEnvironment["HERDR_PAIR_LINK"] = link
        app.launch()

        // First connect asks for notification permission.
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 10) { allow.tap() }
        XCTAssertTrue(app.staticTexts["Workspaces"].waitForExistence(timeout: 15))
        XCUIDevice.shared.press(.home)

        // The host runs: xcrun simctl push <sim> dev.bal.herdr.app payload.json
        let banner = springboard.otherElements["Notification"].descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'Finished'")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 40), "no notification banner")
        banner.tap()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(app.navigationBars.staticTexts["html-gen"].waitForExistence(timeout: 10), "pane didn't open")
        if let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] {
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(dir)/notif-open.png"))
        }
    }
}
