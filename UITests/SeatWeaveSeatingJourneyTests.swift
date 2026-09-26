import XCTest

/// Issue #3 compact-phone journey with synthetic guests only:
/// create -> seat -> swap -> undo -> unseat -> undo -> duplicate -> relaunch.
/// The compact workspace navigates between Guests/Tables/Pairs/Plans tabs
/// exactly like the README's compact-phone design.
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

    private func selectTab(_ app: XCUIApplication, _ name: String) {
        let tab = app.tabBars.buttons[name]
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "Tab \(name) missing")
        tab.tap()
    }

    /// Polls until the element's accessibility label contains the text.
    /// Checks existence first: reading `.label` on a momentarily absent
    /// element (SwiftUI rebuilds the List rows after each state change)
    /// throws a snapshot failure instead of polling.
    private func waitLabel(_ element: XCUIElement, containing text: String, timeout: TimeInterval = 8) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, element.label.contains(text) { return true }
            _ = element.waitForExistence(timeout: 0.25)
        }
        return element.exists && element.label.contains(text)
    }

    /// Polls until an element is gone. Sheet/menu dismissal animations
    /// leave stale hit targets for a moment; tapping other controls during
    /// that window can land on neighbouring buttons (Undo vs Close event).
    private func waitGone(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while element.exists, Date() < deadline {
            _ = element.waitForExistence(timeout: 0.25)
        }
        return !element.exists
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
        XCTAssertTrue(waitIdentifiedLabel(app, identifier: "selected-plan", containing: "Plan: Plan A"))

        // Enter the alias-capable synthetic roster on the Guests tab.
        selectTab(app, "Guests")
        addGuest(app, name: "Aster")
        addGuest(app, name: "Basil")

        // The starter variant has no tables yet; add a circular table.
        selectTab(app, "Tables")
        XCTAssertTrue(app.buttons["add-table-button"].waitForExistence(timeout: 5))
        app.buttons["add-table-button"].tap()
        let labelField = app.textFields["table-label-field"]
        XCTAssertTrue(labelField.waitForExistence(timeout: 5))
        labelField.tap()
        labelField.typeText("Round1\n")
        app.buttons["confirm-add-table"].tap()
        XCTAssertTrue(app.buttons["seat-Round1-1"].waitForExistence(timeout: 8))

        // Seat Aster into seat 1: select on Guests, seat on Tables.
        selectTab(app, "Guests")
        rosterButton(app, "Aster").tap()
        XCTAssertTrue(waitIdentifiedLabel(app, identifier: "selection.current", containing: "Aster"))
        selectTab(app, "Tables")
        XCTAssertTrue(app.buttons["seat-Round1-1"].waitForExistence(timeout: 5))
        app.buttons["seat-Round1-1"].tap()
        XCTAssertTrue(waitLabel(app.buttons["seat-Round1-1"], containing: "Aster"))
        XCTAssertTrue(waitIdentifiedLabel(app, identifier: "seating.summary", containing: "1 seated"))

        // Seat Basil into seat 2.
        selectTab(app, "Guests")
        rosterButton(app, "Basil").tap()
        selectTab(app, "Tables")
        app.buttons["seat-Round1-2"].tap()
        XCTAssertTrue(waitIdentifiedLabel(app, identifier: "seating.summary", containing: "2 seated"))

        // Swap: select Aster, tap Basil's occupied seat -> confirm sheet.
        selectTab(app, "Guests")
        rosterButton(app, "Aster").tap()
        selectTab(app, "Tables")
        app.buttons["seat-Round1-2"].tap()
        XCTAssertTrue(app.staticTexts["Swap seats?"].waitForExistence(timeout: 5))
        let explanation = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Aster moves to")
        )
        XCTAssertTrue(explanation.element(boundBy: 0).waitForExistence(timeout: 5))
        app.buttons["confirm-swap"].tap()
        // Let the sheet finish dismissing before tapping anything else:
        // during the dismissal animation a synthesized tap can resolve to
        // a neighbour of the intended control.
        XCTAssertTrue(waitGone(app.staticTexts["Swap seats?"]))

        // After the swap Aster holds seat 2 and Basil holds seat 1.
        XCTAssertTrue(waitLabel(app.buttons["seat-Round1-2"], containing: "Aster"))
        XCTAssertTrue(waitLabel(app.buttons["seat-Round1-1"], containing: "Basil"))

        // Undo reverses the swap (toolbar available on every tab).
        XCTAssertTrue(app.buttons["undo-button"].waitForExistence(timeout: 5))
        app.buttons["undo-button"].tap()
        XCTAssertTrue(waitLabel(app.buttons["seat-Round1-1"], containing: "Aster"))
        XCTAssertTrue(waitLabel(app.buttons["seat-Round1-2"], containing: "Basil"))

        // Unseat Aster from the Guests selection controls, then undo it.
        selectTab(app, "Guests")
        rosterButton(app, "Aster").tap()
        XCTAssertTrue(app.buttons["unseat-button"].waitForExistence(timeout: 5))
        app.buttons["unseat-button"].tap()
        XCTAssertTrue(waitIdentifiedLabel(app, identifier: "seating.summary", containing: "1 seated"))
        app.buttons["undo-button"].tap()
        XCTAssertTrue(waitIdentifiedLabel(app, identifier: "seating.summary", containing: "2 seated"))
        selectTab(app, "Tables")
        XCTAssertTrue(waitLabel(app.buttons["seat-Round1-1"], containing: "Aster"))

        // Duplicate and compare variants without mutating assignments.
        selectTab(app, "Plans")
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

        // Close, then relaunch: the app reopens into the selected plan copy.
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
        relaunched.tabBars.buttons["Tables"].tap()
        XCTAssertTrue(waitLabel(relaunched.buttons["seat-Round1-1"], containing: "Aster"))
        XCTAssertTrue(waitLabel(relaunched.buttons["seat-Round1-2"], containing: "Basil"))
    }

    private func addGuest(_ app: XCUIApplication, name: String) {
        let field = app.textFields["add-guest-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("\(name)\n")
        app.buttons["add-guest-button"].tap()
        XCTAssertTrue(rosterButton(app, name).waitForExistence(timeout: 5))
    }

    /// Issue #17: roster row identifiers are per-guest UUIDs now, so
    /// journeys locate rows by the leading name in the row's combined
    /// accessibility label ("<name>, <seat>"). Names in these journeys
    /// are unique; the new duplicate-name coverage queries per-person
    /// labels directly in SeatWeaveGuestEditingJourneyTests.
    private func rosterButton(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "\(name), "))
            .firstMatch
    }

}
