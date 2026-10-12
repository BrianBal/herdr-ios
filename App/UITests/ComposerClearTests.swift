import XCTest

/// The message field empties after a send, including when the last word was
/// still being composed (a misspelling with an autocorrect suggestion pending).
/// Needs a workspace named "ios-clear-test" whose pane runs an agent.
/// HERDR_PAIR_LINK as for HomeSwipeTests.
final class ComposerClearTests: XCTestCase {
    @MainActor
    func testFieldClearsAfterSend() throws {
        let link = try XCTUnwrap(ProcessInfo.processInfo.environment["HERDR_PAIR_LINK"])
        let app = XCUIApplication()
        app.launchEnvironment["HERDR_PAIR_LINK"] = link
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 8) { allow.tap() }

        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS 'ios-clear-test'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()

        let field = app.textFields.matching(NSPredicate(format: "placeholderValue BEGINSWITH 'Message'")).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        for (n, message) in ["Reply with just ok, thnaks", "Again just ok pleese", "One more, just ok tnx"].enumerated() {
            field.tap()
            field.typeText(message)
            app.buttons["Send"].tap()
            // Empty means the placeholder shows again.
            let cleared = NSPredicate(format: "value == nil OR value == '' OR value BEGINSWITH 'Message'")
            let done = expectation(for: cleared, evaluatedWith: field)
            if XCTWaiter.wait(for: [done], timeout: 8) != .completed {
                save(app, "not-cleared-\(n)")
                XCTFail("field still holds \"\(field.value as? String ?? "")\" after sending \"\(message)\"")
            }
            sleep(4)  // let the agent answer before the next one
        }
    }

    @MainActor
    private func save(_ app: XCUIApplication, _ name: String) {
        if let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] {
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        }
    }
}
