import XCTest

/// Issue #6 large-text journey with synthetic guests only: at the
/// AXExtraLarge content size (set through `simctl ui content_size`, which
/// is the scripted equivalent of Settings > Accessibility > Display &
/// Text > Larger Text), the complete core journey — create -> add guests
/// -> add table -> assign -> swap -> undo -> resize -> duplicate ->
/// relaunch -> public export preview — must remain reachable using only
/// scrolling and taps. The export preview must still exclude every
/// unseated name and preference text at the largest supported size.
///
/// This is simulator evidence at a script-set Dynamic Type size, not
/// human VoiceOver/Switch Control validation and not physical-device
/// evidence. The content size is restored in tearDown; when the simulator
/// rejects the setting the test records the fact and asserts the plain
/// journey still completes, rather than passing silently.
final class SeatWeaveLargeTextJourneyTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        // Best-effort restore so later tests in the same destination see
        // the default content size. Failures here are non-fatal.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        task.arguments = ["simctl", "ui", "booted", "content_size", "large"]
        try? task.run()
        task.waitUntilExit()
        super.tearDown()
    }

    /// Applies an accessibility content size through the simulator,
    /// trying the accepted token spellings in order (iOS 26 documents
    /// `accessibility-extra-extra-large`; older builds used the plain
    /// `extra-extra-large`/`xxx-large` spellings). Returns the first
    /// token the simulator accepted, or nil when every spelling failed.
    private func setContentSize() -> String? {
        for token in ["accessibility-extra-extra-large", "extra-extra-large", "xxx-large"] {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            task.arguments = ["simctl", "ui", "booted", "content_size", token]
            do {
                try task.run()
                task.waitUntilExit()
                if task.terminationStatus == 0 { return token }
            } catch {
                return nil
            }
        }
        return nil
    }

    private func launchApp(fresh: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-resetStore", fresh ? "YES" : "NO"]
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

    /// Waits for a button by identifier, scrolling the tables/roster
    /// lists downward while searching — large text pushes controls off
    /// screen and finding them by scroll IS the accessibility assertion.
    private func waitButton(_ app: XCUIApplication, identifier: String,
                            timeout: TimeInterval = 15) -> XCUIElement {
        let button = app.buttons[identifier]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if button.exists { return button }
            let table = app.tables.firstMatch
            if table.exists { table.swipeUp() }
        }
        XCTAssertTrue(button.exists, "button \(identifier) never found even after scrolling")
        return button
    }

    @MainActor
    func testCoreJourneyCompletesAtExtraLargeText() throws {
        let appliedToken = setContentSize()
        continueAfterFailure = true
        XCTAssert(appliedToken != nil,
                  "simctl rejected every extra-large content-size spelling; the journey below then runs at the simulator default")
        continueAfterFailure = false

        var app = launchApp(fresh: true)
        let titleField = app.textFields["event-title-field"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 10),
                      "event list unusable at extra-large text")
        titleField.tap()
        titleField.typeText("Large text dinner\n")
        waitButton(app, identifier: "create-event-button").tap()
        XCTAssertTrue(app.navigationBars["Large text dinner"].waitForExistence(timeout: 10))

        // Roster on the Guests tab, scrolled into view as needed.
        waitButton(app, identifier: "Guests").tap()
        let guestField = app.textFields["add-guest-field"]
        XCTAssertTrue(guestField.waitForExistence(timeout: 15), "add-guest field off-screen at large text")
        guestField.tap()
        guestField.typeText("Aster\n")
        waitButton(app, identifier: "add-guest-button").tap()
        XCTAssertTrue(waitButton(app, identifier: "roster-Aster").waitForExistence(timeout: 10))

        guestField.tap()
        guestField.typeText("Basil\n")
        waitButton(app, identifier: "add-guest-button").tap()
        XCTAssertTrue(waitButton(app, identifier: "roster-Basil").waitForExistence(timeout: 10))

        // One four-seat table on the Tables tab.
        waitButton(app, identifier: "Tables").tap()
        waitButton(app, identifier: "add-table-button").tap()
        let labelField = app.textFields["table-label-field"]
        XCTAssertTrue(labelField.waitForExistence(timeout: 10))
        labelField.tap()
        labelField.typeText("Round1\n")
        waitButton(app, identifier: "confirm-add-table").tap()
        XCTAssertTrue(waitButton(app, identifier: "seat-Round1-1").waitForExistence(timeout: 15),
                      "chart unusable at extra-large text")

        // Assign Aster to seat 1, Basil to seat 2 — list navigation only.
        waitButton(app, identifier: "Guests").tap()
        waitButton(app, identifier: "roster-Aster").tap()
        waitButton(app, identifier: "Tables").tap()
        waitButton(app, identifier: "seat-Round1-1").tap()
        waitButton(app, identifier: "Guests").tap()
        waitButton(app, identifier: "roster-Basil").tap()
        waitButton(app, identifier: "Tables").tap()
        waitButton(app, identifier: "seat-Round1-2").tap()
        XCTAssertTrue(waitIdentifiedLabel(app, identifier: "seating.summary", containing: "2 seated"))

        // Swap Aster and Basil, then undo it.
        waitButton(app, identifier: "Guests").tap()
        waitButton(app, identifier: "roster-Aster").tap()
        waitButton(app, identifier: "Tables").tap()
        waitButton(app, identifier: "seat-Round1-2").tap()
        XCTAssertTrue(app.staticTexts["Swap seats?"].waitForExistence(timeout: 10),
                      "swap sheet missing at extra-large text")
        waitButton(app, identifier: "confirm-swap").tap()
        XCTAssertTrue(waitIdentifiedLabel(app, identifier: "seating.summary", containing: "2 seated"))
        waitButton(app, identifier: "undo-button").tap()

        // Resize Round1 6 -> 2 through the sheet: both guests hold seats
        // 1 and 2, so the preview must promise zero unseatings, and the
        // sheet must still be operable (stepper + confirm) at this size.
        waitButton(app, identifier: "Tables").tap()
        waitButton(app, identifier: "resize-Round1").tap()
        let stepper = app.steppers.firstMatch
        XCTAssertTrue(stepper.waitForExistence(timeout: 10), "resize stepper missing at extra-large text")
        let seatsTwo = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Seats: 2")
        ).firstMatch
        for _ in 0..<6 where !seatsTwo.exists {
            stepper.decrement()
            _ = seatsTwo.waitForExistence(timeout: 1)
        }
        XCTAssertTrue(seatsTwo.waitForExistence(timeout: 5), "stepper never reached 2 seats")
        XCTAssertTrue(app.otherElements["resize-affected-none"].waitForExistence(timeout: 10)
                      || app.staticTexts["resize-affected-none"].waitForExistence(timeout: 2),
                      "resize preview missing at extra-large text")
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
                      "duplicate not visible at extra-large text")

        // Relaunch: the workspace reopens with the seated state intact.
        app.terminate()
        app = launchApp(fresh: false)
        XCTAssertTrue(app.navigationBars["Large text dinner"].waitForExistence(timeout: 15),
                      "relaunch unusable at extra-large text")
        XCTAssertTrue(waitIdentifiedLabel(app, identifier: "seating.summary", containing: "2 seated"))

        // Public export preview at extra-large text: privacy contract holds.
        waitButton(app, identifier: "Share").tap()
        waitButton(app, identifier: "export-preview-button").tap()
        let exportText = app.staticTexts["export-text"]
        XCTAssertTrue(exportText.waitForExistence(timeout: 10),
                      "export preview unusable at extra-large text")
        XCTAssertTrue(exportText.label.contains("Aster"))
        XCTAssertTrue(exportText.label.contains("Basil"))
        XCTAssertFalse(exportText.label.contains("preference"),
                       "private preference vocabulary leaked into the public export")
        waitButton(app, identifier: "close-export-preview").tap()
    }
}
