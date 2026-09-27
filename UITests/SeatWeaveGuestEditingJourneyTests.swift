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
            for element in candidates where element.exists {
                // Empty `text` means the caller is asserting identity and
                // existence only. CI run 36031804625's xcresult proved the
                // warning was present with the expected identifier and full
                // label, yet repeatedly fetching `label` made this helper
                // return false. Do not add an irrelevant label dependency to
                // existence-only assertions.
                if text.isEmpty || element.label.contains(text) {
                    return true
                }
            }
            _ = candidates[0].waitForExistence(timeout: 0.25)
        }
        return false
    }

    /// CI evidence runs 36027041095 + 36336704688: List rows realized
    /// BELOW the viewport pass `waitForExistence` but are not hittable,
    /// and a window-level `app.swipeUp()` does not reliably scroll the
    /// roster List (it can land on keyboard chrome or a sibling scroll
    /// view, so the field never moves into the viewport at all). Scroll
    /// the List element itself — the repo's sheet-list idiom proved
    /// element-scoped swipes target the right scroll view — and stop the
    /// moment the element becomes hittable so lazy loading cannot unload
    /// it by over-scrolling.
    private func scrollContainer(_ app: XCUIApplication) -> XCUIElement {
        // Prefer the frontmost sheet's scroll surface. App-level queries
        // can return the background roster while a guest-detail sheet is
        // covering it (run 36341196862), so swiping the first app scroll
        // view never brings the sheet's rename action into view.
        let sheet = app.sheets.firstMatch
        if sheet.exists {
            let sheetList = sheet.tables.firstMatch
            if sheetList.exists { return sheetList }
            let sheetScroll = sheet.scrollViews.firstMatch
            if sheetScroll.exists { return sheetScroll }
            return sheet
        }
        let list = app.tables.firstMatch
        if list.exists { return list }
        let scroll = app.scrollViews.firstMatch
        if scroll.exists { return scroll }
        return app
    }

    private func scrollUntilHittable(_ app: XCUIApplication, _ element: XCUIElement, maxSwipes: Int = 5) -> Bool {
        if element.exists, element.isHittable { return true }
        let container = scrollContainer(app)
        // "Selected guest" controls (rename/unseat/delete) are a
        // top-anchored List section, ABOVE the roster rows a prior step
        // may have scrolled past. CI run 36342484572 showed
        // rename-guest-button unreachable because the helper only ever
        // scrolled further down (swipeUp); try toward the top first,
        // then fall back to scrolling down for lower content.
        for _ in 0..<maxSwipes {
            if element.exists, element.isHittable { return true }
            container.swipeDown()
        }
        for _ in 0..<maxSwipes {
            if element.exists, element.isHittable { return true }
            container.swipeUp()
        }
        return element.exists && element.isHittable
    }

    private func tapWhenHittable(_ app: XCUIApplication, _ element: XCUIElement, _ what: String,
                                  maxSwipes: Int = 5) {
        XCTAssertTrue(scrollUntilHittable(app, element, maxSwipes: maxSwipes),
                      "\(what) never became hittable after scrolling")
        element.tap()
        // Keyboard dismissal animation leaves stale hit targets briefly.
        _ = waitGone(app.otherElements["keyplane"].firstMatch, timeout: 3)
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
        tapWhenHittable(app, field, "add-guest-field")
        field.typeText("\(name)\n")
        tapWhenHittable(app, app.buttons["add-guest-button"], "add-guest-button")
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
        XCTAssertTrue(addField.waitForExistence(timeout: 5))
        tapWhenHittable(app, addField, "add-guest-field (duplicate check)")
        addField.typeText("aster") // folded duplicate of Aster
        XCTAssertTrue(waitIdentifiedLabel(app, identifier: "add-guest-duplicate-warning", containing: ""),
                      "duplicate-name warning missing while adding a matching name")
        // Submit first so AddGuestRow's existing onSubmit clears focus.
        // CI runs 36336704688 and 36338276427 showed keyplane remained
        // open after tapping Add and consumed every subsequent roster
        // swipe, leaving the below-roster search row unrealized.
        addField.typeText("\n")
        XCTAssertTrue(waitGone(app.otherElements["keyplane"].firstMatch, timeout: 3),
                      "keyboard stayed open after submitting duplicate name")
        tapWhenHittable(app, app.buttons["add-guest-button"], "add-guest-button (intentional duplicate)")
        XCTAssertFalse(app.otherElements["keyplane"].firstMatch.exists,
                       "keyboard reopened before the search-row scroll")
        XCTAssertTrue(rosterButton(app, "aster", duplicate: true).waitForExistence(timeout: 5),
                      "duplicate copy missing or unmarked after intentional add")
        // Banner is a List-row Text: XCUITest surfaces it as a
        // cell-like Other element, so poll both kinds (repo idiom).
        XCTAssertTrue(waitIdentifiedLabel(app, identifier: "duplicate-names-banner", containing: ""),
                      "roster duplicate banner missing")

        // --- Search folds case (acceptance row 3). ---
        // Search intentionally sits below the lazy roster so existing
        // first-row interactions retain their proven viewport position.
        // CI run 36263319782 showed that waiting for existence before
        // scrolling can never realize this List row. The interaction
        // helper must scroll first and require the field to be hittable.
        let searchField = app.textFields["guest-search-field"]
        tapWhenHittable(app, searchField, "guest-search-field", maxSwipes: 8)
        searchField.typeText("ASTER\n") // Submit to dismiss keyboard so roster rows materialize
        _ = waitGone(app.otherElements["keyplane"].firstMatch, timeout: 3)
        // Both folded matches stay in the filtered roster
        XCTAssertTrue(rosterButton(app, "Aster").waitForExistence(timeout: 5))
        XCTAssertTrue(rosterButton(app, "aster").waitForExistence(timeout: 5))
        tapWhenHittable(app, searchField, "guest-search-field (second term)")
        searchField.typeText("zzz\n")
        _ = waitGone(app.otherElements["keyplane"].firstMatch, timeout: 3)
        XCTAssertTrue(waitIdentifiedLabel(app, identifier: "roster-empty", containing: ""),
                      "no empty-state when search matches nobody")
        tapWhenHittable(app, app.buttons["clear-search-button"], "clear-search-button")
        XCTAssertTrue(rosterButton(app, "Aster").waitForExistence(timeout: 5),
                      "clearing search did not restore the roster")

        // --- Rename with identity preserved (acceptance rows 1 and 6). ---
        // The rename sheet shows the current name and takes the NEW name
        // in an empty field (same pattern as the add-table sheet).
        tapWhenHittable(app, rosterButton(app, "Aster"), "roster Aster")
        tapWhenHittable(app, app.buttons["rename-guest-button"], "rename-guest-button")
        XCTAssertTrue(waitIdentifiedLabel(app, identifier: "rename-current-name", containing: "Aster"),
                      "rename sheet missing or lost the current name")
        let renameField = app.textFields["rename-guest-field"]
        XCTAssertTrue(renameField.waitForExistence(timeout: 5))
        renameField.tap()
        renameField.typeText("aster") // folded match with the OTHER guest
        XCTAssertTrue(waitIdentifiedLabel(app, identifier: "rename-duplicate-warning", containing: ""),
                      "rename duplicate warning missing")
        renameField.typeText("id") // "asterid" is distinct again
        tapWhenHittable(app, app.buttons["confirm-rename-button"], "confirm-rename-button")
        XCTAssertTrue(waitGone(app.staticTexts["rename-current-name"]), "rename sheet stayed up")
        XCTAssertTrue(rosterButton(app, "asterid").waitForExistence(timeout: 5),
                      "renamed guest missing from roster")
        XCTAssertTrue(waitIdentifiedLabel(app, identifier: "selection.current", containing: "asterid"),
                      "selection lost across the rename")

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
        tapWhenHittable(app, rosterButton(app, "asterid"), "roster asterid")
        selectTab(app, "Tables")
        XCTAssertTrue(app.buttons["seat-Round1-1"].waitForExistence(timeout: 5))
        app.buttons["seat-Round1-1"].tap()
        XCTAssertTrue(waitIdentifiedLabel(app, identifier: "seating.summary", containing: "1 seated"))
        XCTAssertTrue(app.buttons["seat-Round1-1"].label.contains("asterid"),
                      "seat lost the renamed guest: \(app.buttons["seat-Round1-1"].label)")

        // --- Filters with selection continuity (acceptance rows 3-4). ---
        selectTab(app, "Guests")
        tapWhenHittable(app, app.buttons["filter-unseated"], "filter-unseated")
        XCTAssertTrue(rosterButton(app, "aster").waitForExistence(timeout: 5),
                      "unseated guest missing under Unseated filter")
        // The selected (seated) asterid is hidden by the filter — the
        // selection must be preserved AND explained, not dropped.
        XCTAssertTrue(waitIdentifiedLabel(app, identifier: "selection.current", containing: "asterid"),
                      "selection lost when the filter hid the guest")
        XCTAssertTrue(waitIdentifiedLabel(app, identifier: "selection.hidden-by-filter",
                                          containing: "hidden"),
                      "hidden-by-filter explanation missing")
        tapWhenHittable(app, app.buttons["reveal-selected-button"], "reveal-selected-button")
        XCTAssertTrue(rosterButton(app, "asterid").waitForExistence(timeout: 5),
                      "reveal button did not restore visibility")
        tapWhenHittable(app, app.buttons["filter-seated"], "filter-seated")
        XCTAssertTrue(rosterButton(app, "asterid").waitForExistence(timeout: 5),
                      "seated guest missing under Seated filter")
        // Selecting the unseated guest and re-applying Seated hides them;
        // selection persists with the explanation again.
        tapWhenHittable(app, app.buttons["filter-unseated"], "filter-unseated (again)")
        tapWhenHittable(app, rosterButton(app, "aster"), "roster aster")
        tapWhenHittable(app, app.buttons["filter-seated"], "filter-seated (hide selection)")
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
