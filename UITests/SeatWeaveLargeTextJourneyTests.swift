import XCTest

/// Issue #6 large-text journey with synthetic guests only.
///
/// `Scripts/ci.sh` raises the destination content size to the
/// accessibility range (`xcrun simctl ui <udid> content_size
/// accessibility-extra-extra-large` — the scripted equivalent of
/// Settings ▸ Accessibility ▸ Display & Text ▸ Larger Text) right before
/// this dedicated invocation and restores the default size afterwards,
/// even on failure. The app is launched with the test-only
/// `-contentProbe YES` flag, which renders the environment's ACTUAL
/// resolved content-size category; the test asserts it reached the
/// accessibility range, so this suite can never silently pass at the
/// default size.
///
/// The journey — create -> add guests -> add table -> assign -> swap ->
/// undo -> resize -> duplicate -> relaunch -> export preview — must
/// remain reachable at that size using only scrolling and taps. Finding
/// off-screen controls BY SCROLLING is itself the large-text usability
/// assertion. The resize step is the first automated coverage of the
/// resize sheet stepper (driven through its Decrement child button; the
/// public `decrement()` API does not exist on the pinned SDK).
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

    // MARK: - Large-text interaction helpers
    //
    // At accessibility sizes SwiftUI rows sit below the fold and
    // List realizes them lazily, so every lookup scrolls until the
    // element appears, across whatever element kind the row surfaces
    // as (button/cell/other), and scrolls with real touch geometry in
    // the content band — element-scoped swipes first, then a
    // coordinate drag that cannot land on the enlarged tab bar or on a
    // sheet.

    private func candidates(_ app: XCUIApplication, _ identifier: String) -> [XCUIElement] {
        [app.buttons[identifier], app.cells[identifier], app.otherElements[identifier]]
    }

    /// Scrolls down one screenful inside the FRONTMOST scrollable
    /// surface: a sheet's own table/scroll view first (so background
    /// lists are never scrolled under a sheet), then the app's table /
    /// scroll view. If neither exists (iOS 26 SwiftUI lists have been
    /// observed surfacing as neither kind to XCUITest), a coordinate
    /// drag starts NEAR THE BOTTOM of the content band — the only
    /// region guaranteed to be inside the list viewport once any row is
    /// visible and clear of the enlarged tab bar — because at
    /// accessibility sizes the session banner occupies most of the
    /// upper screen and a center-start drag lands on static text
    /// instead of the list (CI run 35837348124).
    private func scrollDownOnce(_ app: XCUIApplication) {
        let sheet = app.sheets.firstMatch
        if sheet.exists {
            let sheetTable = sheet.tables.firstMatch
            if sheetTable.exists { sheetTable.swipeUp(); return }
            let sheetScroll = sheet.scrollViews.firstMatch
            if sheetScroll.exists { sheetScroll.swipeUp(); return }
            return // Sheet without a scrollable surface: scrolling cannot help.
        }
        let table = app.tables.firstMatch
        if table.exists { table.swipeUp(); return }
        let scroll = app.scrollViews.firstMatch
        if scroll.exists { scroll.swipeUp(); return }
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    private func scrollUpOnce(_ app: XCUIApplication) {
        if app.sheets.firstMatch.exists { return }
        let table = app.tables.firstMatch
        if table.exists { table.swipeDown(); return }
        let scroll = app.scrollViews.firstMatch
        if scroll.exists { scroll.swipeDown(); return }
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    /// Polls for an identified element across element kinds, scrolling
    /// while it is off-screen (when `scroll` is true). Mostly scrolls
    /// down; every fourth attempt scrolls back up so an over-scrolled
    /// list cannot deadlock the search.
    private func waitAny(_ app: XCUIApplication, identifier: String,
                         timeout: TimeInterval = 30, scroll: Bool = true) -> XCUIElement {
        let deadline = Date().addingTimeInterval(timeout)
        var attempts = 0
        while Date() < deadline {
            for element in candidates(app, identifier) where element.exists {
                return element
            }
            if scroll {
                attempts += 1
                if attempts % 4 == 0 { scrollUpOnce(app) } else { scrollDownOnce(app) }
            }
        }
        // Return the button proxy anyway so the caller's failure message
        // names the identifier that stayed missing.
        return app.buttons[identifier]
    }

    private func waitField(_ app: XCUIApplication, identifier: String,
                           timeout: TimeInterval = 25, scroll: Bool = true) -> XCUIElement {
        let field = app.textFields[identifier]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if field.exists, field.isHittable { return field }
            if scroll { scrollDownOnce(app) }
        }
        XCTAssertTrue(field.exists, "text field \(identifier) never found even after scrolling")
        return field
    }

    private func tap(_ app: XCUIApplication, identifier: String, scroll: Bool = true) {
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            for element in candidates(app, identifier) where element.exists && element.isHittable {
                element.tap()
                return
            }
            if scroll { scrollDownOnce(app) }
        }
        // One last pass without the hittable requirement to produce a
        // precise failure message.
        let element = candidates(app, identifier).first { $0.exists } ?? app.buttons[identifier]
        if !element.isHittable {
            // TEMPORARY one-shot evidence dump for the found-but-never-
            // hittable failure at AX5XL (CI runs 35833292698..35983208010).
            // Removed in the same PR once the root cause is committed.
            var lines: [String] = ["DIAG \(identifier) never hittable; deadline expired."]
            for (name, el) in [
                ("button", app.buttons[identifier] as XCUIElement),
                ("cell", app.cells[identifier] as XCUIElement),
                ("other", app.otherElements[identifier] as XCUIElement),
            ] {
                if el.exists {
                    lines.append("target \(name): frame=\(el.frame) hittable=\(el.isHittable) label=\(el.label.prefix(70))")
                } else {
                    lines.append("target \(name): missing")
                }
            }
            let tabBar = app.tabBars.firstMatch
            lines.append("tabBar exists=\(tabBar.exists) frame=\(tabBar.exists ? tabBar.frame : .zero)")
            let table = app.tables.firstMatch
            lines.append("table exists=\(table.exists) frame=\(table.exists ? table.frame : .zero)")
            for probe in ["seat-Round1-1", "seat-Round1-3", "seat-Round1-4", "seat-Round1-5"] {
                let b = app.buttons[probe]
                if b.exists {
                    lines.append("probe \(probe): frame=\(b.frame) hittable=\(b.isHittable)")
                } else {
                    lines.append("probe \(probe): missing")
                }
            }
            let allButtons = app.buttons.allElementsBoundByIndex
            lines.append("all buttons (\(allButtons.count)):")
            for b in allButtons.prefix(50) {
                lines.append("  id=\(b.identifier) label=\(b.label.prefix(40)) frame=\(b.frame) hittable=\(b.isHittable)")
            }
            let dump = lines.joined(separator: "\n")
            NSLog("LARGE-TEXT-DIAG\n%@", dump)
            XCTFail(dump)
        }
        element.tap()
    }

    /// Tab bar first (iPhone renders a bottom tab bar; the iOS 26 iPad
    /// tab bar may not carry the trait), plain button as fallback — the
    /// resolution rule proven by SeatWeaveRegularWidthTests.
    private func tapTab(_ app: XCUIApplication, _ name: String) {
        let inTabBar = app.tabBars.buttons[name]
        if inTabBar.waitForExistence(timeout: 5) {
            inTabBar.tap()
            return
        }
        tap(app, identifier: name, scroll: false)
    }

    /// Taps a stepper's decrement control (child button labels exposed
    /// by SwiftUI steppers).
    private func tapDecrement(_ stepper: XCUIElement) {
        for name in ["Decrement", "decrement"] {
            let button = stepper.buttons[name]
            if button.waitForExistence(timeout: 2) {
                button.tap()
                return
            }
        }
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
        tap(app, identifier: "create-event-button")
        XCTAssertTrue(app.navigationBars["Large text dinner"].waitForExistence(timeout: 10))

        // Roster on the Guests tab, scrolled into view as needed.
        tapTab(app, "Guests")
        let guestField = waitField(app, identifier: "add-guest-field")
        guestField.tap()
        guestField.typeText("Aster\n")
        tap(app, identifier: "add-guest-button")
        XCTAssertTrue(waitAny(app, identifier: "roster-Aster").exists)

        waitField(app, identifier: "add-guest-field").tap()
        app.textFields["add-guest-field"].typeText("Basil\n")
        tap(app, identifier: "add-guest-button")
        XCTAssertTrue(waitAny(app, identifier: "roster-Basil").exists)

        // One table (default six seats) on the Tables tab.
        tapTab(app, "Tables")
        tap(app, identifier: "add-table-button")
        let labelField = waitField(app, identifier: "table-label-field", scroll: false)
        labelField.tap()
        labelField.typeText("Round1\n")
        tap(app, identifier: "confirm-add-table", scroll: false)
        XCTAssertTrue(waitAny(app, identifier: "seat-Round1-1").exists,
                      "chart unusable at accessibility text size")

        // Assign Aster to seat 1 and Basil to seat 2 — list navigation
        // and taps only.
        tapTab(app, "Guests")
        tap(app, identifier: "roster-Aster")
        tapTab(app, "Tables")
        tap(app, identifier: "seat-Round1-1")
        XCTAssertTrue(waitIdentifiedLabel(app, identifier: "seating.summary", containing: "1 seated"),
                      "first assignment did not register at accessibility text size")

        tapTab(app, "Guests")
        tap(app, identifier: "roster-Basil")
        tapTab(app, "Tables")
        tap(app, identifier: "seat-Round1-2")
        XCTAssertTrue(waitIdentifiedLabel(app, identifier: "seating.summary", containing: "2 seated"))

        // Swap Aster and Basil, then undo the swap.
        tapTab(app, "Guests")
        tap(app, identifier: "roster-Aster")
        tapTab(app, "Tables")
        tap(app, identifier: "seat-Round1-2")
        XCTAssertTrue(app.staticTexts["Swap seats?"].waitForExistence(timeout: 10),
                      "swap sheet missing at accessibility text size")
        tap(app, identifier: "confirm-swap", scroll: false)
        XCTAssertTrue(waitIdentifiedLabel(app, identifier: "seating.summary", containing: "2 seated"))
        tap(app, identifier: "undo-button", scroll: false)

        // Resize Round1 6 -> 2 through the sheet. Both guests sit at
        // seats 1 and 2, so the preview must promise zero unseatings and
        // the stepper must be operable at this text size.
        tapTab(app, "Tables")
        tap(app, identifier: "resize-Round1")
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
        let apply = waitAny(app, identifier: "confirm-resize", scroll: false)
        XCTAssertTrue(apply.isEnabled)
        apply.tap()
        XCTAssertTrue(waitIdentifiedLabel(app, identifier: "seating.summary", containing: "2 seated"))

        // Duplicate the plan from the Plans tab.
        tapTab(app, "Plans")
        let planA = waitAny(app, identifier: "plan-Plan A")
        XCTAssertTrue(planA.exists, "Plan A row missing at accessibility text size")
        planA.press(forDuration: 1.2)
        let duplicate = waitAny(app, identifier: "Duplicate", timeout: 10, scroll: false)
        XCTAssertTrue(duplicate.exists, "duplicate menu item missing")
        duplicate.tap()
        XCTAssertTrue(waitAny(app, identifier: "plan-Plan A copy").exists,
                      "duplicate not visible at accessibility text size")

        // Relaunch: the workspace reopens with the seated state intact.
        app.terminate()
        app = launchApp(fresh: false)
        XCTAssertTrue(app.navigationBars["Large text dinner"].waitForExistence(timeout: 15),
                      "relaunch unusable at accessibility text size")
        XCTAssertTrue(waitIdentifiedLabel(app, identifier: "seating.summary", containing: "2 seated"))

        // Public export preview: the privacy contract holds at this size.
        tapTab(app, "Share")
        tap(app, identifier: "export-preview-button")
        let exportText = app.staticTexts["export-text"]
        XCTAssertTrue(exportText.waitForExistence(timeout: 10),
                      "export preview unusable at accessibility text size")
        XCTAssertTrue(exportText.label.contains("Aster"))
        XCTAssertTrue(exportText.label.contains("Basil"))
        XCTAssertFalse(exportText.label.contains("preference"),
                       "private preference vocabulary leaked into the public export")
        tap(app, identifier: "close-export-preview", scroll: false)
    }
}
