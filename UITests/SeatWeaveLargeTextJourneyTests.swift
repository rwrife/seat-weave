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
    /// drag spans the full content band between the navigation bar and
    /// the tab bar. CI runs 36337108077/36338870932 showed a small
    /// 20%-of-screen drag (y=0.60->0.40) was too short to move a single
    /// AX5XL-sized row out of view — the row can occupy most of the
    /// screen at that text size, so a short drag looks like a no-op.
    /// The gesture must begin within the unobscured content band, not at
    /// the enlarged tab bar's hit area (even when the List's reported
    /// collection frame extends underneath that bar).
    private func contentBand(_ app: XCUIApplication) -> (top: CGFloat, bottom: CGFloat) {
        let appFrame = app.frame
        let surface = frontScrollSurface(app)
        let tabBar = app.tabBars.firstMatch
        let navigationBar = app.navigationBars.firstMatch
        // Run 37302205727's failure hierarchy proved an app-level drag
        // starting at y=580 (only 4pt above the tab bar) SWITCHED to Pairs
        // while looking for seat 2. The collection itself is y=368..667;
        // constrain the gesture to its unobscured interior and leave a
        // generous 70pt gap above the enlarged tab controls/overlay.
        let top = max(navigationBar.exists ? navigationBar.frame.maxY + 4 : appFrame.minY + 80,
                      surface == app ? appFrame.minY + 80 : surface.frame.minY + 20)
        let bottom = min(tabBar.exists ? tabBar.frame.minY - 70 : appFrame.maxY - 80,
                         surface == app ? appFrame.maxY - 80 : surface.frame.maxY - 70)
        return (top, max(top + 40, bottom))
    }

    // Run 36465561808 root cause (from the failing run's xcresult
    // hierarchy dumps): after the event-creation push, the NavigationStack
    // keeps the event-list screen's CollectionView MOUNTED behind the
    // pushed workspace (the failure snapshot still contained
    // `event-title-field`/`create-event-button` next to the 3-page Guests
    // list). `collectionViews.firstMatch` therefore swiped the
    // background 1-page list — the Guests list's scroll bar reported
    // `value: 0%` through every swipe — and `add-guest-field` never
    // realized. The front-most mounted screen is the LAST mounted
    // collection, so scroll against `lastMatch` (identical to firstMatch
    // while only one surface is mounted, i.e. no regression elsewhere).
    // The front-most mounted screen is the LAST mounted collection.
    // (XCUIElementQuery has no `lastMatch` property — index via count.)
    private func frontScrollSurface(_ app: XCUIApplication) -> XCUIElement {
        let collections = app.collectionViews
        if collections.count > 0 { return collections.element(boundBy: collections.count - 1) }
        let tables = app.tables
        if tables.count > 0 { return tables.element(boundBy: tables.count - 1) }
        let scrolls = app.scrollViews
        if scrolls.count > 0 { return scrolls.element(boundBy: scrolls.count - 1) }
        return app
    }

    private func contentBandDrag(_ app: XCUIApplication, downward: Bool) {
        let (top, bottom) = contentBand(app)
        let appFrame = app.frame
        let startNorm = downward
            ? (bottom - appFrame.minY) / appFrame.height
            : (top - appFrame.minY) / appFrame.height
        let endNorm = downward
            ? (top - appFrame.minY) / appFrame.height
            : (bottom - appFrame.minY) / appFrame.height
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: startNorm))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: endNorm))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    // Run 36810913152 root cause (from the failing run's xcresult
    // query dumps): during the seat-Round1-2 hunt the mounted
    // CollectionView's own element-targeted `swipeUp` left the list's
    // `Vertical scroll bar, 4 pages' value pinned at 0% through ~20
    // attempts — the synthesized swipe never reached the real scroll
    // view (the row stayed unrealized). The window-level coordinate
    // drag across the content band is the strategy already proven in
    // `waitField` for exactly this stall (run 36465561808): it always
    // synthesizes against the front-most window. Alternate the two so
    // every second attempt is a band drag.
    private var scrollCadence = 0

    private func scrollDownOnce(_ app: XCUIApplication) {
        let sheet = app.sheets.firstMatch
        if sheet.exists {
            let sheetCollection = sheet.collectionViews.firstMatch
            if sheetCollection.exists { sheetCollection.swipeUp(); return }
            let sheetTable = sheet.tables.firstMatch
            if sheetTable.exists { sheetTable.swipeUp(); return }
            let sheetScroll = sheet.scrollViews.firstMatch
            if sheetScroll.exists { sheetScroll.swipeUp(); return }
            return // Sheet without a scrollable surface: scrolling cannot help.
        }
        scrollCadence += 1
        let surface = frontScrollSurface(app)
        if surface != app {
            if scrollCadence % 2 == 0 {
                surface.swipeUp()
            } else {
                contentBandDrag(app, downward: true)
            }
            return
        }
        contentBandDrag(app, downward: true)
    }

    private func scrollUpOnce(_ app: XCUIApplication) {
        if app.sheets.firstMatch.exists { return }
        scrollCadence += 1
        let surface = frontScrollSurface(app)
        if surface != app {
            if scrollCadence % 2 == 0 {
                surface.swipeDown()
            } else {
                contentBandDrag(app, downward: false)
            }
            return
        }
        contentBandDrag(app, downward: false)
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
                           timeout: TimeInterval = 30, scroll: Bool = true) -> XCUIElement {
        let field = app.textFields[identifier]
        let deadline = Date().addingTimeInterval(timeout)
        var attempts = 0
        while Date() < deadline {
            if field.exists, field.isHittable { return field }
            if scroll {
                attempts += 1
                // Run 36465561808: element-targeted swipes can be claimed
                // by a NavigationStack-mounted background list (the
                // transition keeps BOTH screens' CollectionViews mounted
                // — failure snapshots proved the Guests list stayed at
                // scroll value 0% through 20 element swipes). A coordinate
                // drag inside the content band always synthesizes against
                // the frontmost window, so alternate the two strategies.
                if attempts % 2 == 0 { scrollDownOnce(app) } else { contentBandDrag(app, downward: true) }
            }
        }
        XCTAssertTrue(field.exists, "text field \(identifier) never found even after scrolling")
        return field
    }

    /// Move an already-realized row by a small amount toward the usable
    /// viewport. A full swipe is too coarse at AX5XL: CI runs 36019523093
    /// and 36027341633 showed seat 2 beginning just under the enlarged tab
    /// bar, then jumping above the viewport and being lazily unloaded.
    private func nudgeTowardViewport(_ app: XCUIApplication, element: XCUIElement) {
        let (top, bottom) = contentBand(app)
        let startY: CGFloat
        let endY: CGFloat
        if element.frame.midY >= bottom {
            startY = bottom - 5
            endY = max(top + 5, startY - 35)
        } else if element.frame.midY <= top {
            startY = top + 5
            endY = min(bottom - 5, startY + 35)
        } else {
            startY = bottom - 10
            endY = max(top + 5, startY - 20)
        }
        // Use screen coordinates on the app rather than percentages of
        // the CollectionView: its frame extends UNDER the tab bar on AX5XL.
        let origin = app.frame
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: (startY - origin.minY) / origin.height))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: (endY - origin.minY) / origin.height))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    private func tap(_ app: XCUIApplication, identifier: String, scroll: Bool = true) {
        let deadline = Date().addingTimeInterval(25)
        var attempts = 0
        while Date() < deadline {
            let resolved = candidates(app, identifier).first { $0.exists }
            if let resolved, resolved.isHittable {
                resolved.tap()
                return
            }
            if scroll {
                attempts += 1
                if let resolved {
                    nudgeTowardViewport(app, element: resolved)
                } else if attempts % 4 == 0 {
                    // Missing means lazy loading removed the row. Keep the
                    // proven 3-down / 1-up cadence from waitAny so the hunt
                    // progresses downward but still recovers from overscroll.
                    scrollUpOnce(app)
                } else {
                    scrollDownOnce(app)
                }
            }
        }
        let element = candidates(app, identifier).first { $0.exists } ?? app.buttons[identifier]
        XCTAssertTrue(element.isHittable, "\(identifier) never became tappable inside the active list's content band")
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

    /// Taps a stepper's decrement control. Evidence run 36019523093:
    /// at AX5XL the positional fallback bound to the WRONG child — the
    /// Increment button (identifier resize-stepper-Increment) was the
    /// second exposed control — so the decrement is matched strictly by
    /// identifier/label, and a missing control fails loudly with a
    /// child dump instead of guessing.
    private func tapDecrement(_ stepper: XCUIElement) {
        let dec = stepper.buttons.matching(
            NSPredicate(format: "identifier CONTAINS[cd] %@ OR label CONTAINS[cd] %@",
                        "decrement", "decrement")
        ).firstMatch
        if dec.waitForExistence(timeout: 5) {
            dec.tap()
            return
        }
        let dump = stepper.buttons.allElementsBoundByIndex
            .map { "id=\($0.identifier) label=\($0.label)" }
            .joined(separator: " | ")
        XCTFail("no decrement control among stepper children: \(dump)")
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
