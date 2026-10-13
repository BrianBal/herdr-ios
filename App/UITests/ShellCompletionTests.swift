import XCTest

/// Tab completion chips in a shell pane, and that "--" stays two dashes.
/// Needs a workspace named "ios-complete-test" at a shell prompt in the repo
/// root (it has a "Gateway" folder). HERDR_PAIR_LINK as for HomeSwipeTests.
final class ShellCompletionTests: XCTestCase {
    @MainActor
    func testCompletionChipFillsWord() throws {
        let link = try XCTUnwrap(ProcessInfo.processInfo.environment["HERDR_PAIR_LINK"])
        let app = XCUIApplication()
        app.launchEnvironment["HERDR_PAIR_LINK"] = link
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 8) { allow.tap() }

        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS 'ios-complete-test'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()

        let field = app.textFields["composer-field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("cd Gat")
        let chip = app.buttons["Complete Gateway/"]
        XCTAssertTrue(chip.waitForExistence(timeout: 5), "no completion chip")
        save(app, "completion-chip")
        chip.tap()
        XCTAssertEqual(field.value as? String, "cd Gateway/")

        field.typeText(" && ls --all")
        XCTAssertEqual(field.value as? String, "cd Gateway/ && ls --all")
    }

    @MainActor
    private func save(_ app: XCUIApplication, _ name: String) {
        if let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] {
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        }
    }
}
