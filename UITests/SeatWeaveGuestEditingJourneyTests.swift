import XCTest

/// Issue #17 compact-phone journey with synthetic guests only:
/// duplicate-name warnings while adding/renaming, rename with identity
/// preserved across variants and relaunch, name search, seated/unseated
/// filters, and selection preservation (with an explanation) when a
/// filter hides the selected guest.
/// This is simulator evidence, not physical-device evidence.
final class SeatWeaveGuestEditingJourneyTests: XCTestCase {
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

    private func waitGone(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while element.exists, Date() < deadline {
            _ = element.waitForExistence(timeout: 0.25)
        }
        return !element.exists
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

    /// Roster rows carry per-guest UUID identifiers (issue #17), so
    /// journeys locate them by the leading "<name>, " prefix of the
    /// combined accessibility label ("<name>, <seat>[, shares this name
    /// …]"). Name matching is case-SENSITIVE here on purpose: the
    /// journey keeps "Aster" and "aster" distinguishable. For a
    /// duplicate copy, `duplicate: true` additionally requires the
    /// ", shares this name" suffix, proving the visible mark exists.
    private func rosterButton(_ app: XCUIApplication, _ name: String, duplicate: Bool? = nil) -> XCUIElement {
        let predicate: NSPredicate
        if duplicate == true {
            predicate = NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@",
                                    "\(name), ", "shares this name")
        } else {
            predicate = NSPredicate(format: "label CONTAINS %@", "\(name), ")
        }
        return app.buttons.matching(predicate).firstMatch
    }

    private func addGuest(_ app: XCUIApplication, name: String) {
        let field = app.textFields["add-guest-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("\(name)\n")
        app.buttons["add-guest-button"].tap()
        XCTAssertTrue(rosterButton(app, name).waitForExistence(timeout: 5),
                      "roster row for \(name) missing after add")
    }

    @MainActor
    func testGuestEditingJourney() throws {
        var app = launchApp(fresh: true)
        let titleField = app.textFields["event-title-field"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 10))
        titleField.tap()
        titleField.typeText("Editing dinner\n")
        app.buttons["create-event-button"].tap()
        XCTAssertTrue(app.navigationBars["Editing dinner"].waitForExistence(timeout: 10))

        selectTab(app, "Guests")
        addGuest(app, name: "Aster")

        // --- Duplicate-name warning while adding (acceptance row 2). ---
        let addField = app.textFields["add-guest-field"]
        addField.tap()
        addField.typeText("aster") // folded duplicate of Aster
        XCTAssertTrue(app.staticTexts["add-guest-duplicate-warning"].waitForExistence(timeout: 5),
                      "duplicate-name warning missing while adding a matching name")
        app.buttons["add-guest-button"].tap() // intentional duplicate stays legal
        XCTAssertTrue(rosterButton(app, "aster", duplicate: true).waitForExistence(timeout: 5),
                      "duplicate copy missing or unmarked after intentional add")
        XCTAssertTrue(app.staticTexts["duplicate-names-banner"].waitForExistence(timeout: 5),
                      "roster duplicate banner missing")

        // --- Search folds case (acceptance row 3). ---
        let searchField = app.textFields["guest-search-field"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.tap()
        searchField.typeText("ASTER")
        // Both folded matches stay visible; the count header tracks them.
        XCTAssertTrue(rosterButton(app, "Aster").waitForExistence(timeout: 5))
        XCTAssertTrue(rosterButton(app, "aster").waitForExistence(timeout: 5))
        searchField.tap()
        searchField.typeText("zzz")
        XCTAssertTrue(app.staticTexts["roster-empty"].waitForExistence(timeout: 5),
                      "no empty-state when search matches nobody")
        app.buttons["clear-search-button"].tap()
        XCTAssertTrue(rosterButton(app, "Aster").waitForExistence(timeout: 5),
                      "clearing search did not restore the roster")

        // --- Rename with identity preserved (acceptance rows 1 and 6). ---
        // The rename sheet shows the current name and takes the NEW name
        // in an empty field (same pattern as the add-table sheet).
        rosterButton(app, "Aster").tap()
        XCTAssertTrue(app.buttons["rename-guest-button"].waitForExistence(timeout: 5))
        app.buttons["rename-guest-button"].tap()
        XCTAssertTrue(app.staticTexts["rename-current-name"].waitForExistence(timeout: 5),
                      "rename sheet missing")
        XCTAssertTrue(app.staticTexts["rename-current-name"].label.contains("Aster"),
                      "rename sheet lost the current name")
        let renameField = app.textFields["rename-guest-field"]
        XCTAssertTrue(renameField.waitForExistence(timeout: 5))
        renameField.tap()
        renameField.typeText("aster") // folded match with the OTHER guest
        XCTAssertTrue(app.staticTexts["rename-duplicate-warning"].waitForExistence(timeout: 5),
                      "rename duplicate warning missing")
        renameField.typeText("id") // "asterid" is distinct again
        app.buttons["confirm-rename-button"].tap()
        XCTAssertTrue(waitGone(app.staticTexts["rename-current-name"]), "rename sheet stayed up")
        XCTAssertTrue(rosterButton(app, "asterid").waitForExistence(timeout: 5),
                      "renamed guest missing from roster")
        XCTAssertTrue(waitIdentifiedLabel(app, identifier: "selection.current", containing: "asterid"),
                      "selection lost across the rename")
        // Renaming away the duplicate removes the duplicate marks.
        XCTAssertTrue(!app.staticTexts["duplicate-names-banner"].exists
                      || app.staticTexts["duplicate-names-banner"].label.isEmpty,
                      "duplicate banner still present after rename away from the pair")

        // --- Seat the renamed guest; assignment followed the UUID. ---
        selectTab(app, "Tables")
        XCTAssertTrue(app.buttons["add-table-button"].waitForExistence(timeout: 5))
        app.buttons["add-table-button"].tap()
        let labelField = app.textFields["table-label-field"]
        XCTAssertTrue(labelField.waitForExistence(timeout: 5))
        labelField.tap()
        labelField.typeText("Round1\n")
        app.buttons["confirm-add-table"].tap()
        XCTAssertTrue(app.buttons["seat-Round1-1"].waitForExistence(timeout: 8))
        selectTab(app, "Guests")
        rosterButton(app, "asterid").tap()
        selectTab(app, "Tables")
        app.buttons["seat-Round1-1"].tap()
        XCTAssertTrue(waitIdentifiedLabel(app, identifier: "seating.summary", containing: "1 seated"))
        XCTAssertTrue(app.buttons["seat-Round1-1"].label.contains("asterid"),
                      "seat lost the renamed guest: \(app.buttons["seat-Round1-1"].label)")

        // --- Filters with selection continuity (acceptance rows 3-4). ---
        selectTab(app, "Guests")
        app.buttons["filter-unseated"].tap()
        XCTAssertTrue(rosterButton(app, "aster").waitForExistence(timeout: 5),
                      "unseated guest missing under Unseated filter")
        // The selected (seated) asterid is hidden by the filter — the
        // selection must be preserved AND explained, not dropped.
        XCTAssertTrue(waitIdentifiedLabel(app, identifier: "selection.current", containing: "asterid"),
                      "selection lost when the filter hid the guest")
        XCTAssertTrue(waitIdentifiedLabel(app, identifier: "selection.hidden-by-filter",
                                          containing: "hidden"),
                      "hidden-by-filter explanation missing")
        app.buttons["reveal-selected-button"].tap()
        XCTAssertTrue(rosterButton(app, "asterid").waitForExistence(timeout: 5),
                      "reveal button did not restore visibility")
        app.buttons["filter-seated"].tap()
        XCTAssertTrue(rosterButton(app, "asterid").waitForExistence(timeout: 5),
                      "seated guest missing under Seated filter")
        // Selecting the unseated guest and re-applying Seated hides them;
        // selection persists with the explanation again.
        app.buttons["filter-unseated"].tap()
        rosterButton(app, "aster").tap()
        app.buttons["filter-seated"].tap()
        XCTAssertTrue(waitIdentifiedLabel(app, identifier: "selection.hidden-by-filter",
                                          containing: "hidden"),
                      "selection not explained when hidden by Seated filter")

        // --- Rename + identity persist across relaunch (acceptance row 6). ---
        app.terminate()
        app = launchApp(fresh: false)
        XCTAssertTrue(app.navigationBars["Editing dinner"].waitForExistence(timeout: 15))
        XCTAssertTrue(waitIdentifiedLabel(app, identifier: "seating.summary", containing: "1 seated"))
        selectTab(app, "Guests")
        XCTAssertTrue(rosterButton(app, "asterid").waitForExistence(timeout: 5),
                      "rename did not persist across relaunch")
        XCTAssertTrue(rosterButton(app, "aster").waitForExistence(timeout: 5),
                      "intentional duplicate did not persist across relaunch")
        // The seat still belongs to the renamed person: identity, not
        // the name, owns the assignment.
        selectTab(app, "Tables")
        XCTAssertTrue(app.buttons["seat-Round1-1"].label.contains("asterid"),
                      "seat lost the renamed guest after relaunch")
    }
}
