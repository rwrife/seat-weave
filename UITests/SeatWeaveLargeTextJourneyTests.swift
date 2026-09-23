import XCTest

/// Issue #6 large-text journey with synthetic guests only.
///
/// `Scripts/ci.sh` sets the destination content size to
/// `accessibility-extra-extra-large` through `xcrun simctl ui booted
/// content_size` (the scripted equivalent of Settings ▸ Accessibility ▸
/// Display & Text ▸ Larger Text) immediately before this suite and
/// restores `large` afterwards. The app is launched with the test-only
/// `-contentProbe YES` flag, which renders the environment's ACTUAL
/// resolved Dynamic Type category; this test asserts that category is
/// beyond the standard sizes, so the suite can never silently pass at
/// the default size.
///
/// The journey — create -> add guests -> add table -> assign -> swap ->
/// undo -> resize -> duplicate -> relaunch -> export preview — must
/// remain reachable at that size using only scrolling and taps, and the
/// export preview must still exclude every unseated name and preference
/// text. The resize step is the first automated coverage of the resize
/// sheet stepper.
///
/// This is simulator evidence at a script-set Dynamic Type size: NOT a
/// human VoiceOver/Switch Control assessment and NOT physical-device
/// evidence.
final class SeatWeaveLargeTextJourneyTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchApp(fresh: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-resetStore", fresh ? "YES" : "NO",
                               "-contentProbe", "YES"]
        app.launch()
        return app
    }

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

    /// Scrolls the front-most scrollable surface down one screenful.
    /// SwiftUI lists may surface as tables, scroll views or a plain
    /// collection; the window-level swipe is the robust last resort.
    private func scrollDownOnce(_ app: XCUIApplication) {
        let table = app.tables.firstMatch
        if table.exists { table.swipeUp(); return }
        let scroll = app.scrollViews.firstMatch
        if scroll.exists { scroll.swipeUp(); return }
        app.swipeUp()
    }

    /// Waits for a text field by identifier, scrolling down while it is
    /// off-screen — finding controls by scrolling IS the assertion.
    private func waitField(_ app: XCUIApplication, identifier: String,
                           timeout: TimeInterval = 20) -> XCUIElement {
        let field = app.textFields[identifier]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if field.exists, field.isHittable { return field }
            scrollDownOnce(app)
        }
        XCTAssertTrue(field.exists, "text field \(identifier) never found even after scrolling")
        return field
    }

    /// Waits for a button by identifier, scrolling the workspace lists
    /// downward while searching — large text pushes controls off screen
    /// and finding them by scroll IS the accessibility assertion.
    private func waitButton(_ app: XCUIApplication, identifier: String,
                            timeout: TimeInterval = 20) -> XCUIElement {
        let button = app.buttons[identifier]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if button.exists { return button }
            scrollDownOnce(app)
        }
        XCTAssertTrue(button.exists, "button \(identifier) never found even after scrolling")
        return button
    }

    /// Taps a stepper's decrement control: SwiftUI exposes the two
    /// stepper buttons with these accessibility labels.
    private func tapDecrement(_ stepper: XCUIElement) {
        for name in ["Decrement", "decrement"] {
            let button = stepper.buttons[name]
            if button.waitForExistence(timeout: 2) {
                button.tap()
                return
            }
        }
        // Positional fallback: second child is the decrement half.
        let second = stepper.buttons.element(boundBy: 1)
        XCTAssertTrue(second.exists, "stepper exposes no decrement control")
        second.tap()
    }

    @MainActor
    func testCoreJourneyCompletesAtAccessibilityTextSize() throws {
        var app = launchApp(fresh: true)

        // The probe proves the external content-size setting actually
        // took effect; a default-size launch must fail this assertion.
        // (CI-observed actual value at accessibility-extra-extra-large:
        // "UICTContentSizeCategoryAccessibilityXXL".)
        let probe = app.staticTexts["content-size-probe"]
        XCTAssertTrue(probe.waitForExistence(timeout: 10), "content-size probe missing")
        let probeLabel = probe.label
        XCTAssertTrue(probeLabel.contains("UICTContentSizeCategoryAccessibility"),
                      "content size did not reach the accessibility range: \(probeLabel)")

        let titleField = waitField(app, identifier: "event-title-field")
        titleField.tap()
        titleField.typeText("Large text dinner\n")
        waitButton(app, identifier: "create-event-button").tap()
        XCTAssertTrue(app.navigationBars["Large text dinner"].waitForExistence(timeout: 10))

        // Roster on the Guests tab, scrolled into view as needed.
        waitButton(app, identifier: "Guests").tap()
        let guestField = waitField(app, identifier: "add-guest-field")
        guestField.tap()
        guestField.typeText("Aster\n")
        waitButton(app, identifier: "add-guest-button").tap()
        XCTAssertTrue(waitButton(app, identifier: "roster-Aster").waitForExistence(timeout: 10))

        waitField(app, identifier: "add-guest-field").tap()
        app.textFields["add-guest-field"].typeText("Basil\n")
        waitButton(app, identifier: "add-guest-button").tap()
        XCTAssertTrue(waitButton(app, identifier: "roster-Basil").waitForExistence(timeout: 10))

        // One table (default six seats) on the Tables tab.
        waitButton(app, identifier: "Tables").tap()
        waitButton(app, identifier: "add-table-button").tap()
        let labelField = waitField(app, identifier: "table-label-field")
        labelField.tap()
        labelField.typeText("Round1\n")
        waitButton(app, identifier: "confirm-add-table").tap()
        XCTAssertTrue(waitButton(app, identifier: "seat-Round1-1").waitForExistence(timeout: 15),
                      "chart unusable at accessibility text size")

        // Assign Aster to seat 1 and Basil to seat 2 — list navigation only.
        waitButton(app, identifier: "Guests").tap()
        waitButton(app, identifier: "roster-Aster").tap()
        waitButton(app, identifier: "Tables").tap()
        waitButton(app, identifier: "seat-Round1-1").tap()
        waitButton(app, identifier: "Guests").tap()
        waitButton(app, identifier: "roster-Basil").tap()
        waitButton(app, identifier: "Tables").tap()
        waitButton(app, identifier: "seat-Round1-2").tap()
        XCTAssertTrue(waitIdentifiedLabel(app, identifier: "seating.summary", containing: "2 seated"))

        // Swap Aster and Basil, then undo the swap.
        waitButton(app, identifier: "Guests").tap()
        waitButton(app, identifier: "roster-Aster").tap()
        waitButton(app, identifier: "Tables").tap()
        waitButton(app, identifier: "seat-Round1-2").tap()
        XCTAssertTrue(app.staticTexts["Swap seats?"].waitForExistence(timeout: 10),
                      "swap sheet missing at accessibility text size")
        waitButton(app, identifier: "confirm-swap").tap()
        XCTAssertTrue(waitIdentifiedLabel(app, identifier: "seating.summary", containing: "2 seated"))
        waitButton(app, identifier: "undo-button").tap()

        // Resize Round1 6 -> 2 through the sheet. Both guests sit at
        // seats 1 and 2, so the preview must promise zero unseatings and
        // the stepper must be operable at this text size.
        waitButton(app, identifier: "Tables").tap()
        waitButton(app, identifier: "resize-Round1").tap()
        let stepper = app.steppers.firstMatch
        XCTAssertTrue(stepper.waitForExistence(timeout: 10), "resize stepper missing")
        let seatsTwo = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Seats: 2")
        ).firstMatch
        for _ in 0..<6 where !seatsTwo.exists {
            tapDecrement(stepper)
        }
        XCTAssertTrue(seatsTwo.waitForExistence(timeout: 5), "stepper never reached 2 seats")
        XCTAssertTrue(app.otherElements["resize-affected-none"].waitForExistence(timeout: 10)
                      || app.staticTexts["resize-affected-none"].waitForExistence(timeout: 2),
                      "resize preview missing at accessibility text size")
        XCTAssertTrue(waitButton(app, identifier: "confirm-resize").isEnabled)
        waitButton(app, identifier: "confirm-resize").tap()
        XCTAssertTrue(waitIdentifiedLabel(app, identifier: "seating.summary", containing: "2 seated"))

        // Duplicate the plan from the Plans tab.
        waitButton(app, identifier: "Plans").tap()
        let planA = waitButton(app, identifier: "plan-Plan A")
        planA.press(forDuration: 1.2)
        let duplicate = app.buttons["Duplicate"]
        XCTAssertTrue(duplicate.waitForExistence(timeout: 10))
        duplicate.tap()
        XCTAssertTrue(waitButton(app, identifier: "plan-Plan A copy").waitForExistence(timeout: 10),
                      "duplicate not visible at accessibility text size")

        // Relaunch: the workspace reopens with the seated state intact.
        app.terminate()
        app = launchApp(fresh: false)
        XCTAssertTrue(app.navigationBars["Large text dinner"].waitForExistence(timeout: 15),
                      "relaunch unusable at accessibility text size")
        XCTAssertTrue(waitIdentifiedLabel(app, identifier: "seating.summary", containing: "2 seated"))

        // Public export preview: the privacy contract holds at this size.
        waitButton(app, identifier: "Share").tap()
        waitButton(app, identifier: "export-preview-button").tap()
        let exportText = app.staticTexts["export-text"]
        XCTAssertTrue(exportText.waitForExistence(timeout: 10),
                      "export preview unusable at accessibility text size")
        XCTAssertTrue(exportText.label.contains("Aster"))
        XCTAssertTrue(exportText.label.contains("Basil"))
        XCTAssertFalse(exportText.label.contains("preference"),
                       "private preference vocabulary leaked into the public export")
        waitButton(app, identifier: "close-export-preview").tap()
    }
}
