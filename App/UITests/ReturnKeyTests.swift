import XCTest

/// With the field empty, the send button presses Return in the pane.
/// Needs a workspace named "ios-return-test" at a shell prompt; the host
/// checks that its prompt was repeated. HERDR_PAIR_LINK as for HomeSwipeTests.
final class ReturnKeyTests: XCTestCase {
    @MainActor
    func testEmptySendPressesReturn() throws {
        let link = try XCTUnwrap(ProcessInfo.processInfo.environment["HERDR_PAIR_LINK"])
        let app = XCUIApplication()
        app.launchEnvironment["HERDR_PAIR_LINK"] = link
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 8) { allow.tap() }

        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS 'ios-return-test'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()

        let ret = app.buttons["send-button"]
        XCTAssertTrue(ret.waitForExistence(timeout: 10))
        XCTAssertTrue(ret.isEnabled)
        XCTAssertEqual(ret.label, "Return")
        for _ in 0..<3 {
            ret.tap()
            sleep(1)
        }
        // Typing turns it back into Send.
        let field = app.textFields["composer-field"].firstMatch
        field.tap()
        field.typeText("x")
        XCTAssertTrue(ret.waitForLabel("Send"))
    }
}

private extension XCUIElement {
    func waitForLabel(_ label: String, timeout: TimeInterval = 3) -> Bool {
        let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: self)
        return XCTWaiter.wait(for: [done], timeout: timeout) == .completed
    }
}
