import XCTest

/// The keyboard goes away by tapping the pane output or dragging down into it,
/// and the draft stays. Opens the "TraceBot" workspace; sends nothing.
/// HERDR_PAIR_LINK as for HomeSwipeTests.
final class KeyboardDismissTests: XCTestCase {
    @MainActor
    func testTapAndDragDismissKeyboard() throws {
        let link = try XCTUnwrap(ProcessInfo.processInfo.environment["HERDR_PAIR_LINK"])
        let app = XCUIApplication()
        app.launchEnvironment["HERDR_PAIR_LINK"] = link
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 8) { allow.tap() }

        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS 'TraceBot'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()

        let field = app.textFields["composer-field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        let output = app.scrollViews["pane-output"].firstMatch
        XCTAssertTrue(output.waitForExistence(timeout: 10))

        // Tap the output.
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        output.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "tap didn't dismiss")

        // Drag down into the keyboard, with a draft in the field.
        field.tap()
        field.typeText("draft to keep")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let start = output.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "drag didn't dismiss")
        XCTAssertEqual(field.value as? String, "draft to keep")
    }
}
