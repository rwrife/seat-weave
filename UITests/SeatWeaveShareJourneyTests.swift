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
        rosterButton(app, "Aster").tap()
        app.tabBars.buttons["Tables"].tap()
        app.buttons["seat-Round1-1"].tap()
        XCTAssertTrue(waitLabel(app.buttons["seat-Round1-1"], containing: "Aster"))

        // Public preview: exactly the seated name, never the unseated one.
        app.tabBars.buttons["Share"].tap()
        let reviewButton = app.buttons["review-plan-button"]
        XCTAssertTrue(reviewButton.waitForExistence(timeout: 5))
        reviewButton.tap()
        XCTAssertTrue(app.navigationBars["Plan review"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Unseated guests (1)"].exists)
        XCTAssertTrue(app.staticTexts["Empty seats (5) — informational"].exists)
        let unseated = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Seat Basil — open guest")
        ).firstMatch
        XCTAssertTrue(unseated.waitForExistence(timeout: 5))
        unseated.tap()
        XCTAssertTrue(app.tabBars.buttons["Guests"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["selection.current"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Share"].tap()
        // Select both export controls in the real Share screen. The chosen
        // layout changes row order/format, while paper size changes PDF bounds.
        chooseExportOption(app, picker: "export-layout-picker", option: "Alphabetical guest lookup")
        chooseExportOption(app, picker: "export-paper-size-picker", option: "A4")
        // Returning from a host-only review still permits a draft; the
        // existing public preview asserts Basil and warnings stay private.
        let shareButton = app.buttons["export-preview-button"]
        XCTAssertTrue(shareButton.waitForExistence(timeout: 5))
        XCTAssertTrue(shareButton.isEnabled)
        shareButton.tap()
        let exportText = app.staticTexts["export-text"]
        XCTAssertTrue(exportText.waitForExistence(timeout: 5))
        XCTAssertTrue(exportText.label.contains("Aster — Round1, Seat 1"),
                      "the picked alphabetical lookup format must reach the shared text")
        XCTAssertTrue(exportText.label.contains("Aster"))
        XCTAssertFalse(exportText.label.contains("Basil"),
                       "unseated guests must never reach the shared list")
        XCTAssertFalse(exportText.label.lowercased().contains("preference"))

        // The draft warning lives in the preview section, not the shared text.
        let warning = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "not seated")
        )
        XCTAssertTrue(warning.element(boundBy: 0).waitForExistence(timeout: 5))

        app.buttons["export-preview-pdf"].tap()
        XCTAssertTrue(app.navigationBars["PDF preview"].waitForExistence(timeout: 8))
        let pdfScreenshot = XCTAttachment(screenshot: app.screenshot())
        pdfScreenshot.name = "Synthetic shared PDF preview"
        pdfScreenshot.lifetime = .keepAlways
        add(pdfScreenshot)
        app.buttons["close-pdf-preview"].tap()
        app.buttons["close-export-preview"].tap()
        XCTAssertTrue(shareButton.waitForExistence(timeout: 5))

        // Full backup requires reading the privacy warning first.
        // The Share list lazily realizes sections below the new printable/PDF
        // cards; swipe until the backup button is realized and hittable.
        let backupButton = app.buttons["backup-export-button"]
        for _ in 0..<6 where !backupButton.isHittable {
            let lists = app.collectionViews
            if lists.count > 0 {
                lists.element(boundBy: lists.count - 1).swipeUp()
            }
        }
        XCTAssertTrue(backupButton.waitForExistence(timeout: 5))
        XCTAssertTrue(backupButton.isHittable, "Backup export must remain reachable after PDF controls")
        backupButton.tap()
        let privacy = app.staticTexts["backup-privacy-warning"]
        XCTAssertTrue(privacy.waitForExistence(timeout: 5))
        XCTAssertTrue(privacy.label.contains("preferences"),
                      "backup warning must name the private data it carries")
        app.buttons["Cancel"].tap()

        // Automatic points are browsable with timestamps and private-count
        // summaries. Restoring is exercised at the store layer; here the
        // journey proves preview + discard never mutates the event list.
        let recoveryBrowse = app.buttons["recovery-browse-button"]
        for _ in 0..<6 where !recoveryBrowse.isHittable {
            let lists = app.collectionViews
            if lists.count > 0 { lists.element(boundBy: lists.count - 1).swipeUp() }
        }
        XCTAssertTrue(recoveryBrowse.waitForExistence(timeout: 5))
        recoveryBrowse.tap()
        XCTAssertTrue(app.navigationBars["Recovery points"].waitForExistence(timeout: 5))
        let previews = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recovery-preview-"))
        XCTAssertTrue(previews.firstMatch.waitForExistence(timeout: 5))
        previews.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["recovery-preview-summary"].waitForExistence(timeout: 5))
        app.buttons["recovery-preview-discard"].tap()
        app.buttons["close-recovery-sheet"].tap()
        XCTAssertTrue(app.navigationBars["Synthetic share"].waitForExistence(timeout: 5))

        // Deleting the open event pops back to the event list. The new
        // recovery section pushes Delete below the compact lazy List fold.
        revealDeleteButton(app)
        app.buttons["delete-event-button"].tap()
        let deleteAction = app.buttons["Delete event"]
        XCTAssertTrue(deleteAction.waitForExistence(timeout: 5))
        deleteAction.tap()
        XCTAssertTrue(app.textFields["event-title-field"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["open-event-Synthetic share"].exists,
                       "the deleted event must be gone from the list")
        // Issue #16: ordinary deletion is recoverable for 14 days. Recover
        // it, delete it again, then remove it permanently.
        let recover = app.buttons["list-recover-Synthetic share"]
        XCTAssertTrue(recover.waitForExistence(timeout: 8))
        recover.tap()
        XCTAssertTrue(app.buttons["open-event-Synthetic share"].waitForExistence(timeout: 8),
                      "recover must return the deleted event to the event list")
        XCTAssertFalse(recover.exists, "a recovered event leaves Recently Deleted")

        // Create a second synthetic event to exercise delete-all from Share.
        // SwiftData tests cover individual permanent deletion of the recovered
        // event; reopening a just-recovered event is not needed for this journey.
        let secondField = app.textFields["event-title-field"]
        for _ in 0..<6 where !secondField.isHittable {
            app.collectionViews.firstMatch.swipeUp()
        }
        secondField.tap()
        secondField.typeText("Synthetic two\n")
        app.buttons["create-event-button"].tap()
        XCTAssertTrue(app.navigationBars["Synthetic two"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Share"].tap()
        let deleteAll = app.buttons["delete-all-button"]
        revealDeleteButton(app, identifier: "delete-all-button")
        XCTAssertTrue(deleteAll.isHittable, "Delete all must remain reachable after review chrome")
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

    /// The recovery + Recently Deleted sections push the destructive rows
    /// below the compact lazy-List fold; scroll the front workspace list
    /// (not the event list mounted behind it) until hittable.
    private func revealDeleteButton(_ app: XCUIApplication,
                                    identifier: String = "delete-event-button") {
        let button = app.buttons[identifier]
        for _ in 0..<8 where !button.isHittable {
            let lists = app.collectionViews
            XCTAssertGreaterThan(lists.count, 0)
            lists.element(boundBy: lists.count - 1).swipeUp()
        }
        XCTAssertTrue(button.waitForExistence(timeout: 5), "\(identifier) must be reachable")
    }

    @MainActor
    private func chooseExportOption(_ app: XCUIApplication, picker identifier: String, option label: String) {
        let trigger = app.buttons[identifier]
        XCTAssertTrue(trigger.waitForExistence(timeout: 5), "Missing picker button \(identifier)")
        trigger.tap()
        let menuOption = app.buttons[label]
        if menuOption.waitForExistence(timeout: 2) {
            menuOption.tap()
            return
        }
        let fallback = app.menuItems[label]
        if fallback.waitForExistence(timeout: 2) {
            fallback.tap()
            return
        }
        let sheetOption = app.sheets.buttons[label]
        if sheetOption.waitForExistence(timeout: 2) {
            sheetOption.tap()
            return
        }
        XCTFail("Failed to select option \(label) from picker \(identifier)")
    }

    @MainActor
    private func addGuest(_ app: XCUIApplication, name: String) {
        let field = app.textFields["add-guest-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("\(name)\n")
        app.buttons["add-guest-button"].tap()
        XCTAssertTrue(rosterButton(app, name).waitForExistence(timeout: 5))
    }

    private func waitLabel(_ element: XCUIElement, containing text: String, timeout: TimeInterval = 8) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, element.label.contains(text) { return true }
            _ = element.waitForExistence(timeout: 0.25)
        }
        return element.exists && element.label.contains(text)
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
