import XCTest

extension XCUIApplication {
    /// Makes a shell workspace from the tabs overview's + and waits for it to
    /// open. In the repo's folder when the sheet offers it (scripts/ui-tests.sh
    /// sees to that); never with an agent. The host closes it afterwards.
    @MainActor
    func createShellWorkspace(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let plus = buttons["New workspace"]
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: plus)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 20), .completed, "not connected", file: file, line: line)
        plus.tap()
        let field = textFields["Name (optional)"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), file: file, line: line)
        field.typeText(name)
        let folder = buttons["~/labs/ios-herdr"].firstMatch
        if folder.exists { folder.tap() }
        // A shell, not the default agent: never start one by accident.
        let start = buttons.containing(NSPredicate(format: "label BEGINSWITH 'Start'")).firstMatch
        for _ in 0..<4 where !start.isHittable { swipeUp() }
        XCTAssertTrue(start.waitForExistence(timeout: 3), "no agent picker", file: file, line: line)
        start.tap()
        let shell = buttons["Just a shell"].firstMatch
        XCTAssertTrue(shell.waitForExistence(timeout: 3), "no Just a shell", file: file, line: line)
        shell.tap()
        let create = buttons["Create"]
        for _ in 0..<3 where !create.isHittable { swipeDown() }
        create.tap()
        XCTAssertTrue(buttons["tabs-button"].waitForExistence(timeout: 15), "workspace didn't open", file: file, line: line)
    }
}
