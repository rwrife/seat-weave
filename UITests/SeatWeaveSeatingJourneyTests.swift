import XCTest

/// Issue #3 compact-phone journey with synthetic guests only:
/// create -> seat -> swap -> undo -> unseat -> undo -> duplicate -> relaunch.
/// This is simulator evidence, not physical-device evidence.
final class SeatWeaveSeatingJourneyTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchApp(fresh: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-resetStore", fresh ? "YES" : "NO"]
        app.launch()
        return app
    }

    /// SwiftUI List purges off-screen cells from the a11y hierarchy.
    /// Sweeps down through the list, then back up if needed.
    @discardableResult
    private func reveal(_ app: XCUIApplication, _ element: XCUIElement, timeout: TimeInterval = 12) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        // First try without scrolling, then sweep downward.
        if element.exists { return true }
        var scrolledDown = 0
        while Date() < deadline, scrolledDown < 8 {
            app.swipeUp()
            scrolledDown += 1
            if element.exists { return true }
        }
        // Sweep back up in case the element sits above the viewport.
        var scrolledUp = 0
        while Date() < deadline, scrolledUp < scrolledDown + 2 {
            app.swipeDown()
            scrolledUp += 1
            if element.exists { return true }
        }
        return element.exists
    }

    /// Scrolls into view, then polls until the accessibility label matches.
    private func waitVisibleLabel(
        _ app: XCUIApplication,
        _ element: XCUIElement,
        containing text: String,
        timeout: TimeInterval = 10
    ) -> Bool {
        guard reveal(app, element, timeout: timeout) else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.label.contains(text) { return true }
            _ = element.waitForExistence(timeout: 0.25)
        }
        return element.label.contains(text)
    }

    /// SwiftUI sometimes exposes an identified Text as a cell-like element
    /// instead of a static text. Accept either representation.
    private func waitIdentifiedLabel(
        _ app: XCUIApplication,
        identifier: String,
        containing text: String,
        timeout: TimeInterval = 10
    ) -> Bool {
        let candidates = [app.staticTexts[identifier], app.otherElements[identifier]]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for element in candidates where element.exists && element.label.contains(text) {
                return true
            }
            _ = reveal(app, candidates[0], timeout: 1)
        }
        return false
    }

    @MainActor
    func testCompactSeatingJourney() throws {
        let app = launchApp(fresh: true)
        let titleField = app.textFields["event-title-field"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 10))

        // Create a gathering.
        titleField.tap()
        titleField.typeText("Synthetic dinner\n")
        app.buttons["create-event-button"].tap()

        XCTAssertTrue(app.navigationBars["Synthetic dinner"].waitForExistence(timeout: 10))
        XCTAssertTrue(waitIdentifiedLabel(app, identifier: "seating.summary", containing: "0 seated"))
        XCTAssertTrue(waitIdentifiedLabel(app, identifier: "selected-plan", containing: "Plan: Plan A", timeout: 10))

        // Enter the alias-capable synthetic roster.
        addGuest(app, name: "Aster")
        addGuest(app, name: "Basil")

        // The starter variant has no tables yet; add a circular table.
        XCTAssertTrue(reveal(app, app.buttons["add-table-button"]))
        app.buttons["add-table-button"].tap()
        let labelField = app.textFields["table-label-field"]
        XCTAssertTrue(labelField.waitForExistence(timeout: 5))
        labelField.tap()
        labelField.typeText("Round1\n")
        app.buttons["confirm-add-table"].tap()
        XCTAssertTrue(reveal(app, app.buttons["seat-Round1-1"]))

        // Seat Aster into seat 1 via tap/list controls.
        XCTAssertTrue(reveal(app, app.buttons["roster-Aster"]))
        app.buttons["roster-Aster"].tap()
        XCTAssertTrue(waitIdentifiedLabel(app, identifier: "selection.current", containing: "Aster"))
        XCTAssertTrue(reveal(app, app.buttons["seat-Round1-1"]))
        app.buttons["seat-Round1-1"].tap()
        XCTAssertTrue(waitVisibleLabel(app, app.buttons["seat-Round1-1"], containing: "Aster"))
        XCTAssertTrue(waitIdentifiedLabel(app, identifier: "seating.summary", containing: "1 seated"))

        // Seat Basil into seat 2.
        XCTAssertTrue(reveal(app, app.buttons["roster-Basil"]))
        app.buttons["roster-Basil"].tap()
        XCTAssertTrue(reveal(app, app.buttons["seat-Round1-2"]))
        app.buttons["seat-Round1-2"].tap()
        XCTAssertTrue(waitIdentifiedLabel(app, identifier: "seating.summary", containing: "2 seated"))

        // Swap: select Aster, tap Basil's occupied seat -> confirm sheet.
        XCTAssertTrue(reveal(app, app.buttons["roster-Aster"]))
        app.buttons["roster-Aster"].tap()
        XCTAssertTrue(reveal(app, app.buttons["seat-Round1-2"]))
        app.buttons["seat-Round1-2"].tap()
        XCTAssertTrue(app.staticTexts["Swap seats?"].waitForExistence(timeout: 5))
        let explanation = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Aster moves to")
        )
        XCTAssertTrue(explanation.element(boundBy: 0).waitForExistence(timeout: 5))
        app.buttons["confirm-swap"].tap()

        // After the swap Aster holds seat 2 and Basil holds seat 1.
        XCTAssertTrue(waitVisibleLabel(app, app.buttons["seat-Round1-2"], containing: "Aster"))
        XCTAssertTrue(waitVisibleLabel(app, app.buttons["seat-Round1-1"], containing: "Basil"))

        // Undo reverses the swap.
        XCTAssertTrue(app.buttons["undo-button"].waitForExistence(timeout: 5))
        app.buttons["undo-button"].tap()
        XCTAssertTrue(waitVisibleLabel(app, app.buttons["seat-Round1-1"], containing: "Aster"))
        XCTAssertTrue(waitVisibleLabel(app, app.buttons["seat-Round1-2"], containing: "Basil"))

        // Unseat Aster from the selection controls, then undo the unseat.
        XCTAssertTrue(reveal(app, app.buttons["roster-Aster"]))
        app.buttons["roster-Aster"].tap()
        XCTAssertTrue(reveal(app, app.buttons["unseat-button"]))
        app.buttons["unseat-button"].tap()
        XCTAssertTrue(waitIdentifiedLabel(app, identifier: "seating.summary", containing: "1 seated"))
        app.buttons["undo-button"].tap()
        XCTAssertTrue(waitIdentifiedLabel(app, identifier: "seating.summary", containing: "2 seated"))
        XCTAssertTrue(waitVisibleLabel(app, app.buttons["seat-Round1-1"], containing: "Aster"))

        // Duplicate and compare variants without mutating assignments.
        app.buttons["plans-button"].tap()
        XCTAssertTrue(app.staticTexts["Compare plans"].waitForExistence(timeout: 5))
        let planA = app.buttons["plan-Plan A"]
        XCTAssertTrue(planA.waitForExistence(timeout: 5))
        XCTAssertTrue(waitVisibleLabel(app, planA, containing: "2 seated"))
        planA.press(forDuration: 1.2)
        let duplicateItem = app.buttons["Duplicate"]
        XCTAssertTrue(duplicateItem.waitForExistence(timeout: 5))
        duplicateItem.tap()
        let planCopy = app.buttons["plan-Plan A copy"]
        XCTAssertTrue(planCopy.waitForExistence(timeout: 5))
        XCTAssertTrue(waitVisibleLabel(app, planCopy, containing: "2 seated"))
        app.buttons["plans-done"].tap()

        // Close, then relaunch: the app reopens into the selected plan copy.
        XCTAssertTrue(reveal(app, app.buttons["close-event-button"]))
        app.buttons["close-event-button"].tap()
        XCTAssertTrue(app.textFields["event-title-field"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["open-event-Synthetic dinner"].exists)

        app.terminate()
        let relaunched = launchApp(fresh: false)
        XCTAssertTrue(relaunched.navigationBars["Synthetic dinner"].waitForExistence(timeout: 10))
        XCTAssertTrue(waitIdentifiedLabel(relaunched, identifier: "selected-plan", containing: "Plan: Plan A copy"))
        XCTAssertTrue(waitIdentifiedLabel(relaunched, identifier: "seating.summary", containing: "2 seated"))
        // Completed assignments survive restart (undo history does not):
        // Aster at seat 1 and Basil at seat 2 in the duplicated copy.
        XCTAssertTrue(waitVisibleLabel(relaunched, relaunched.buttons["seat-Round1-1"], containing: "Aster"))
        XCTAssertTrue(waitVisibleLabel(relaunched, relaunched.buttons["seat-Round1-2"], containing: "Basil"))
    }

    private func addGuest(_ app: XCUIApplication, name: String) {
        let field = app.textFields["add-guest-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        // Trailing newline submits the field, closing the keyboard so it
        // cannot shrink the list viewport for later steps.
        field.typeText("\(name)\n")
        app.buttons["add-guest-button"].tap()
        XCTAssertTrue(app.buttons["roster-\(name)"].waitForExistence(timeout: 5))
    }
}
