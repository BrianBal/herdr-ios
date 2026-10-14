import XCTest

/// Settings → Gateways against the live gateway: adds the same gateway a
/// second time under another URL (a query string it ignores), renames it,
/// switches between the two from the home title, and removes it.
/// HERDR_PAIR_LINK as for HomeSwipeTests.
final class GatewaysTests: XCTestCase {
    @MainActor
    func testAddRenameSwitchRemove() throws {
        let link = try XCTUnwrap(ProcessInfo.processInfo.environment["HERDR_PAIR_LINK"])
        let items = try XCTUnwrap(URLComponents(string: link)?.queryItems)
        let url = try XCTUnwrap(items.first { $0.name == "url" }?.value)
        let token = try XCTUnwrap(items.first { $0.name == "token" }?.value)
        let fullHost = try XCTUnwrap(URL(string: url)?.host)
        let host = String(fullHost.split(separator: ".")[0])

        let app = XCUIApplication()
        app.launchEnvironment["HERDR_RESET_GATEWAYS"] = "1"
        app.launchEnvironment["HERDR_PAIR_LINK"] = link
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 8) { allow.tap() }

        // Add the second one by hand.
        if !app.buttons["Settings"].firstMatch.waitForExistence(timeout: 15) { save(app, "gateways-unpaired") }
        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Add gateway"].waitForExistence(timeout: 5))
        app.buttons["Add gateway"].tap()
        let urlField = app.textFields["wss://host.tailnet.ts.net:8443/ws"]
        XCTAssertTrue(urlField.waitForExistence(timeout: 5))
        urlField.tap()
        urlField.typeText(url + "?second=1")
        let tokenField = app.textFields["Token"]
        tokenField.tap()
        tokenField.typeText(token)
        app.buttons["Connect"].tap()
        if !urlField.waitForNonExistence(timeout: 15) { save(app, "gateways-add-failed") }
        XCTAssertFalse(app.buttons["Not Now"].waitForExistence(timeout: 2), "iOS offered to save the token as a password")

        // Back in Settings with two rows; the new one is connected. (Rows show the
        // full host; the home title behind the sheet is just the name.)
        let rows = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", fullHost))
        XCTAssertTrue(app.buttons["Add gateway"].waitForExistence(timeout: 15))
        XCTAssertEqual(rows.count, 2)
        save(app, "gateways-two")

        // Rename the second.
        rows.element(boundBy: 1).tap()
        let name = app.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 40) + "Second")
        app.buttons["Save"].tap()
        let second = app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Second'")).firstMatch
        XCTAssertTrue(second.waitForExistence(timeout: 10))
        save(app, "gateways-renamed")

        // Switch from the home title.
        app.buttons["Done"].tap()
        let title = { (name: String) in app.navigationBars.descendants(matching: .any)[name].firstMatch }
        XCTAssertTrue(title("Second").waitForExistence(timeout: 5))
        title("Second").tap()
        let first = app.buttons[host]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        save(app, "gateways-menu")
        first.tap()
        XCTAssertTrue(title(host).waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label CONTAINS 'TraceBot'")).firstMatch
            .waitForExistence(timeout: 15))

        // Remove the second by swiping its row.
        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        second.swipeLeft()
        app.buttons["Remove"].firstMatch.tap()
        app.sheets.buttons["Remove"].firstMatch.tap()
        XCTAssertTrue(second.waitForNonExistence(timeout: 5))
        XCTAssertEqual(rows.count, 1)
        app.buttons["Done"].tap()
        XCTAssertTrue(title(host).waitForExistence(timeout: 5))
    }

    @MainActor
    private func save(_ app: XCUIApplication, _ name: String) {
        if let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] {
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        }
    }
}
