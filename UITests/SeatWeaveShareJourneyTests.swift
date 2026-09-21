import XCTest

/// Issue #5 simulator journey (synthetic guests only): seat a guest, then
/// walk the Share tab — the public preview shows exactly the seated rows
/// and none of the private data; the backup sheet demands an explicit
/// privacy acknowledgement; deletion is confirmed twice (event dialog and
/// delete-all dialog). The system save/open panels are OS UI and are not
/// automated here; the export/restore byte paths are covered by the
/// domain unit tests instead. This is simulator evidence, not
/// physical-device evidence.
final class SeatWeaveShareJourneyTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSharePreviewBackupAndDeletion() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-resetStore", "YES"]
        app.launch()

        // Build a small synthetic event: one guest seated, one not.
        let titleField = app.textFields["event-title-field"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 10))
        titleField.tap()
        titleField.typeText("Synthetic share\n")
        app.buttons["create-event-button"].tap()
        XCTAssertTrue(app.navigationBars["Synthetic share"].waitForExistence(timeout: 10))

        let guestTab = app.tabBars.buttons["Guests"]
        XCTAssertTrue(guestTab.waitForExistence(timeout: 10))
        guestTab.tap()
        addGuest(app, name: "Aster")
        addGuest(app, name: "Basil")

        app.tabBars.buttons["Tables"].tap()
        XCTAssertTrue(app.buttons["add-table-button"].waitForExistence(timeout: 5))
        app.buttons["add-table-button"].tap()
        let labelField = app.textFields["table-label-field"]
        XCTAssertTrue(labelField.waitForExistence(timeout: 5))
        labelField.tap()
        labelField.typeText("Round1\n")
        app.buttons["confirm-add-table"].tap()
        XCTAssertTrue(app.buttons["seat-Round1-1"].waitForExistence(timeout: 8))

        // Seat only Aster.
        app.tabBars.buttons["Guests"].tap()
        app.buttons["roster-Aster"].tap()
        app.tabBars.buttons["Tables"].tap()
        app.buttons["seat-Round1-1"].tap()
        XCTAssertTrue(waitLabel(app.buttons["seat-Round1-1"], containing: "Aster"))

        // Public preview: exactly the seated name, never the unseated one.
        app.tabBars.buttons["Share"].tap()
        let shareButton = app.buttons["export-preview-button"]
        XCTAssertTrue(shareButton.waitForExistence(timeout: 5))
        XCTAssertTrue(shareButton.isEnabled)
        shareButton.tap()
        let exportText = app.staticTexts["export-text"]
        XCTAssertTrue(exportText.waitForExistence(timeout: 5))
        XCTAssertTrue(exportText.label.contains("Aster"))
        XCTAssertFalse(exportText.label.contains("Basil"),
                       "unseated guests must never reach the shared list")
        XCTAssertFalse(exportText.label.lowercased().contains("preference"))

        // The draft warning lives in the preview section, not the shared text.
        let warning = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "not seated")
        )
        XCTAssertTrue(warning.element(boundBy: 0).waitForExistence(timeout: 5))

        app.buttons["close-export-preview"].tap()
        XCTAssertTrue(shareButton.waitForExistence(timeout: 5))

        // Full backup requires reading the privacy warning first.
        app.buttons["backup-export-button"].tap()
        let privacy = app.staticTexts["backup-privacy-warning"]
        XCTAssertTrue(privacy.waitForExistence(timeout: 5))
        XCTAssertTrue(privacy.label.contains("preferences"),
                      "backup warning must name the private data it carries")
        app.buttons["Cancel"].tap()

        // Deleting the open event pops back to the event list.
        app.buttons["delete-event-button"].tap()
        let deleteAction = app.buttons["Delete event"]
        XCTAssertTrue(deleteAction.waitForExistence(timeout: 5))
        deleteAction.tap()
        XCTAssertTrue(app.textFields["event-title-field"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["open-event-Synthetic share"].exists,
                       "the deleted event must be gone from the list")

        // Create a second synthetic event and reopen it to exercise
        // delete-all from the Share tab (delete-all lives in the workspace).
        let secondField = app.textFields["event-title-field"]
        secondField.tap()
        secondField.typeText("Synthetic two\n")
        app.buttons["create-event-button"].tap()
        XCTAssertTrue(app.navigationBars["Synthetic two"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Share"].tap()
        let deleteAll = app.buttons["delete-all-button"]
        XCTAssertTrue(deleteAll.waitForExistence(timeout: 5))
        XCTAssertTrue(deleteAll.isEnabled)
        deleteAll.tap()
        let deleteEverything = app.buttons["Delete everything"]
        XCTAssertTrue(deleteEverything.waitForExistence(timeout: 5))
        deleteEverything.tap()
        // Empty store: back on the create screen, nothing left to open.
        XCTAssertTrue(app.textFields["event-title-field"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["create-event-button"].exists)
        XCTAssertFalse(app.buttons["open-event-Synthetic share"].exists)
        XCTAssertFalse(app.buttons["open-event-Synthetic two"].exists)
    }

    @MainActor
    private func addGuest(_ app: XCUIApplication, name: String) {
        let field = app.textFields["add-guest-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("\(name)\n")
        app.buttons["add-guest-button"].tap()
        XCTAssertTrue(app.buttons["roster-\(name)"].waitForExistence(timeout: 5))
    }

    private func waitLabel(_ element: XCUIElement, containing text: String, timeout: TimeInterval = 8) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, element.label.contains(text) { return true }
            _ = element.waitForExistence(timeout: 0.25)
        }
        return element.exists && element.label.contains(text)
    }
}
