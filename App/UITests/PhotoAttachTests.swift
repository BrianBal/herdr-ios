import XCTest

/// Sends a photo to an agent: attach from the library, see the thumbnail,
/// send with a message. Needs a workspace named "ios-photo-test" whose pane
/// runs an agent (the host sets it up and checks the agent got the image) and
/// at least one photo in the simulator's library. HERDR_PAIR_LINK as for HomeSwipeTests.
final class PhotoAttachTests: XCTestCase {
    @MainActor
    func testAttachAndSendPhoto() throws {
        let link = try XCTUnwrap(ProcessInfo.processInfo.environment["HERDR_PAIR_LINK"])
        let app = XCUIApplication()
        app.launchEnvironment["HERDR_PAIR_LINK"] = link
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 8) { allow.tap() }

        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS 'ios-photo-test'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()

        let attach = app.buttons["Attach photo"]
        XCTAssertTrue(attach.waitForExistence(timeout: 10))
        attach.tap()
        app.buttons["Photo Library"].tap()

        // The system picker: pick the first photo, then Add.
        XCTAssertTrue(app.scrollViews.images.firstMatch.waitForExistence(timeout: 10), "no photos in the picker")
        sleep(1)
        // Skip the picker's small icons; photos are the big tiles.
        let photo = try XCTUnwrap(app.scrollViews.images.allElementsBoundByIndex.first { $0.frame.width > 40 })
        // The picker runs out of process: its elements report not hittable, so tap by position.
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let add = app.buttons["Add"]
        if add.waitForExistence(timeout: 3) { add.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }

        let remove = app.buttons["Remove photo"]
        XCTAssertTrue(remove.waitForExistence(timeout: 10), "no thumbnail")
        save(app, "photo-attached")

        let field = app.textFields.matching(NSPredicate(format: "placeholderValue BEGINSWITH 'Message'")).firstMatch
        field.tap()
        field.typeText("What is in this image? Answer in five words or fewer.")
        app.buttons["Send"].tap()

        XCTAssertTrue(remove.waitForNonExistence(timeout: 30), "photo wasn't sent")
        XCTAssertFalse(app.alerts.firstMatch.exists, "send failed: \(app.alerts.firstMatch.label)")
        save(app, "photo-sent")
    }

    @MainActor
    private func save(_ app: XCUIApplication, _ name: String) {
        if let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] {
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        }
    }
}
