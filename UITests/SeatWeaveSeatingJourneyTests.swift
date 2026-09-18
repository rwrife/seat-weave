import XCTest

/// Issue #3 compact-phone journey with synthetic guests only:
/// create -> seat -> swap -> undo -> duplicate -> relaunch.
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

    /// Polls until the element's accessibility label contains the text.
    private func waitLabel(_ element: XCUIElement, containing text: String, timeout: TimeInterval = 8) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.label.contains(text) { return true }
            _ = element.waitForExistence(timeout: 0.25)
        }
        return element.label.contains(text)
    }

    /// Scrolls a list element into view when it is offscreen.
    private func forceVisible(_ app: XCUIApplication, _ element: XCUIElement) {
        var attempts = 0
        while !element.isHittable && attempts < 5 {
            app.swipeUp()
            attempts += 1
        }
    }

    @MainActor
    func testCompactSeatingJourney() throws {
        let app = launchApp(fresh: true)
        let titleField = app.textFields["event-title-field"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 10))

        // Create a gathering.
        titleField.tap()
        titleField.typeText("Synthetic dinner")
        app.buttons["create-event-button"].tap()

        XCTAssertTrue(app.navigationBars["Synthetic dinner"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["seating.summary"].waitForExistence(timeout: 5))
        XCTAssertTrue(waitLabel(app.staticTexts["selected-plan"], containing: "Plan: Plan A"))

        // Enter the alias-capable synthetic roster.
        addGuest(app, name: "Aster")
        addGuest(app, name: "Basil")

        // The starter variant has no tables yet; add a circular table.
        app.buttons["add-table-button"].tap()
        let labelField = app.textFields["table-label-field"]
        XCTAssertTrue(labelField.waitForExistence(timeout: 5))
        labelField.tap()
        labelField.typeText("Round1")
        app.buttons["confirm-add-table"].tap()
        XCTAssertTrue(app.buttons["seat-Round1-1"].waitForExistence(timeout: 5))

        // Seat Aster into seat 1 via tap/list controls.
        app.buttons["roster-Aster"].tap()
        XCTAssertTrue(waitLabel(app.staticTexts["selection.current"], containing: "Aster"))
        forceVisible(app, app.buttons["seat-Round1-1"])
        app.buttons["seat-Round1-1"].tap()
        XCTAssertTrue(waitLabel(app.buttons["seat-Round1-1"], containing: "Aster"))
        XCTAssertTrue(waitLabel(app.staticTexts["seating.summary"], containing: "1 seated"))

        // Seat Basil into seat 2.
        app.buttons["roster-Basil"].tap()
        app.buttons["seat-Round1-2"].tap()
        XCTAssertTrue(waitLabel(app.staticTexts["seating.summary"], containing: "2 seated"))

        // Swap: select Aster, tap Basil's occupied seat -> confirm sheet.
        app.buttons["roster-Aster"].tap()
        app.buttons["seat-Round1-2"].tap()
        XCTAssertTrue(app.staticTexts["Swap seats?"].waitForExistence(timeout: 5))
        let explanation = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Aster moves to")
        )
        XCTAssertTrue(explanation.element(boundBy: 0).waitForExistence(timeout: 5))
        app.buttons["confirm-swap"].tap()

        // After the swap Aster holds seat 2 and Basil holds seat 1.
        XCTAssertTrue(waitLabel(app.buttons["seat-Round1-2"], containing: "Aster"))
        XCTAssertTrue(waitLabel(app.buttons["seat-Round1-1"], containing: "Basil"))

        // Undo reverses the swap.
        app.buttons["undo-button"].tap()
        XCTAssertTrue(waitLabel(app.buttons["seat-Round1-1"], containing: "Aster"))
        XCTAssertTrue(waitLabel(app.buttons["seat-Round1-2"], containing: "Basil"))

        // Unseat Aster from the selection controls, then undo the unseat.
        app.buttons["roster-Aster"].tap()
        XCTAssertTrue(app.buttons["unseat-button"].waitForExistence(timeout: 5))
        forceVisible(app, app.buttons["unseat-button"])
        app.buttons["unseat-button"].tap()
        XCTAssertTrue(waitLabel(app.staticTexts["seating.summary"], containing: "1 seated"))
        app.buttons["undo-button"].tap()
        XCTAssertTrue(waitLabel(app.staticTexts["seating.summary"], containing: "2 seated"))
        XCTAssertTrue(waitLabel(app.buttons["seat-Round1-1"], containing: "Aster"))

        // Duplicate and compare variants without mutating assignments.
        app.buttons["plans-button"].tap()
        XCTAssertTrue(app.staticTexts["Compare plans"].waitForExistence(timeout: 5))
        let planA = app.buttons["plan-Plan A"]
        XCTAssertTrue(planA.waitForExistence(timeout: 5))
        XCTAssertTrue(waitLabel(planA, containing: "2 seated"))
        planA.press(forDuration: 1.2)
        let duplicateItem = app.buttons["Duplicate"]
        XCTAssertTrue(duplicateItem.waitForExistence(timeout: 5))
        duplicateItem.tap()
        let planCopy = app.buttons["plan-Plan A copy"]
        XCTAssertTrue(planCopy.waitForExistence(timeout: 5))
        XCTAssertTrue(waitLabel(planCopy, containing: "2 seated"))
        app.buttons["plans-done"].tap()

        // Close, then relaunch: the app reopens into the selected plan copy.
        app.buttons["close-event-button"].tap()
        XCTAssertTrue(app.textFields["event-title-field"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["open-event-Synthetic dinner"].exists)

        app.terminate()
        let relaunched = launchApp(fresh: false)
        XCTAssertTrue(relaunched.navigationBars["Synthetic dinner"].waitForExistence(timeout: 10))
        XCTAssertTrue(waitLabel(relaunched.staticTexts["selected-plan"], containing: "Plan: Plan A copy"))
        XCTAssertTrue(waitLabel(relaunched.staticTexts["seating.summary"], containing: "2 seated"))
        // Completed assignments survive restart (undo history does not):
        // Aster at seat 1 and Basil at seat 2 in the duplicated copy.
        XCTAssertTrue(waitLabel(relaunched.buttons["seat-Round1-1"], containing: "Aster"))
        XCTAssertTrue(waitLabel(relaunched.buttons["seat-Round1-2"], containing: "Basil"))
    }

    private func addGuest(_ app: XCUIApplication, name: String) {
        let field = app.textFields["add-guest-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(name)
        app.buttons["add-guest-button"].tap()
        XCTAssertTrue(app.buttons["roster-\(name)"].waitForExistence(timeout: 5))
    }
}
