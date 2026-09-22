import XCTest

/// Issue #4 auto-path evidence: on a regular-width (iPad-family) simulator
/// with NO launch override, the environment's regular horizontal size
/// class alone must select the regular workspace region, and rotating to
/// portrait plus the compact event-list path must still work. This proves
/// the environment-driven path of `SeatingWorkspaceLayout` (`.auto`),
/// complementing SeatWeaveWorkspaceTransitionTests which forces the
/// regions through the test-only override on a compact iPhone simulator.
/// This is simulator evidence, not physical-device evidence.
final class SeatWeaveRegularWidthTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
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

    private func regionVisible(_ app: XCUIApplication, _ identifier: String, timeout: TimeInterval = 10) -> Bool {
        let candidates = [app.otherElements[identifier], app.groups[identifier]]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if candidates.contains(where: { $0.exists }) { return true }
            _ = candidates[0].waitForExistence(timeout: 0.25)
        }
        return candidates.contains(where: { $0.exists })
    }

    /// Resolve a chart-column tab by identifier regardless of container:
    /// iPhone renders the TabView as a bottom tab bar, but the iOS 26
    /// iPad tab bar does not always carry the tab-bar trait (run
    /// 35695764761: `tabBars.buttons["Tables"]` never resolved on the
    /// iPad mini destination even though the tab existed).
    private func chartTab(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        let inTabBar = app.tabBars.buttons[name]
        if inTabBar.waitForExistence(timeout: 3) { return inTabBar }
        return app.buttons[name]
    }

    @MainActor
    func testAutoLayoutPicksRegularRegionOnRegularWidth() throws {
        let app = XCUIApplication()
        // No -layoutToggle: the auto path must follow the environment.
        app.launchArguments = ["-ui-testing", "-resetStore", "YES"]
        app.launch()

        XCTAssertFalse(app.buttons["layout-region-menu"].exists,
                       "Override menu must never appear without the test flag")

        let titleField = app.textFields["event-title-field"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 10))
        titleField.tap()
        titleField.typeText("Regular width dinner\n")
        app.buttons["create-event-button"].tap()
        XCTAssertTrue(app.navigationBars["Regular width dinner"].waitForExistence(timeout: 10))

        // Environment-only selection of the regular region.
        XCTAssertTrue(regionVisible(app, "workspace-regular"),
                      "Auto path did not follow the regular width environment")
        XCTAssertFalse(app.otherElements["workspace-compact"].exists,
                       "Compact region still present at regular width")
        XCTAssertTrue(waitIdentifiedLabel(app, identifier: "seating.summary", containing: "0 seated"))

        // The roster/preferences sidebar and the chart coexist: add a
        // guest in the sidebar, see it persist while the chart tab shows.
        let field = app.textFields["add-guest-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Roster sidebar missing at regular width")
        field.tap()
        field.typeText("Aster\n")
        app.buttons["add-guest-button"].tap()
        XCTAssertTrue(app.buttons["roster-Aster"].waitForExistence(timeout: 5))
        XCTAssertTrue(chartTab(app, "Tables").waitForExistence(timeout: 8),
                      "Chart column tabs missing at regular width")

        // Rotation at regular width: region choice and any live selection
        // survive orientation changes.
        app.buttons["roster-Aster"].tap()
        XCTAssertTrue(waitIdentifiedLabel(app, identifier: "selection.current", containing: "Aster"))
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(regionVisible(app, "workspace-regular"))
        XCTAssertTrue(waitIdentifiedLabel(app, identifier: "selection.current", containing: "Aster"))
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(regionVisible(app, "workspace-regular"))
        XCTAssertTrue(waitIdentifiedLabel(app, identifier: "selection.current", containing: "Aster"))

        app.terminate()
    }
}
