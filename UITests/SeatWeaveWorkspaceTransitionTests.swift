import XCTest

/// Issue #4 adaptive-workspace journey with synthetic guests only:
/// selection and table focus must survive compact<->regular transitions
/// DURING an active assignment, and the assignment must complete in the
/// regular region using only taps (no dragging).
/// The region override menu exists only under the `-layoutToggle YES`
/// launch flag; normal launches never show it. This is simulator
/// evidence, not physical-device evidence.
final class SeatWeaveWorkspaceTransitionTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchApp(toggle: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        var arguments = ["-ui-testing", "-resetStore", "YES"]
        if toggle { arguments += ["-layoutToggle", "YES"] }
        app.launchArguments = arguments
        app.launch()
        return app
    }

    private func selectTab(_ app: XCUIApplication, _ name: String) {
        let tab = app.tabBars.buttons[name]
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "Tab \(name) missing")
        tab.tap()
    }

    private func waitLabel(_ element: XCUIElement, containing text: String, timeout: TimeInterval = 8) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, element.label.contains(text) { return true }
            _ = element.waitForExistence(timeout: 0.25)
        }
        return element.exists && element.label.contains(text)
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

    /// Region markers are plain container identifiers; SwiftUI may expose
    /// an identified group as either element representation.
    private func regionVisible(_ app: XCUIApplication, _ identifier: String, timeout: TimeInterval = 10) -> Bool {
        let candidates = [app.otherElements[identifier], app.groups[identifier]]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if candidates.contains(where: { $0.exists }) { return true }
            _ = candidates[0].waitForExistence(timeout: 0.25)
        }
        return candidates.contains(where: { $0.exists })
    }

    private func setRegion(_ app: XCUIApplication, to region: String) {
        let menu = app.buttons["layout-region-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "Region menu missing")
        menu.tap()
        let item = app.buttons[region]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "Region item \(region) missing")
        item.tap()
    }

    private func addGuest(_ app: XCUIApplication, name: String) {
        let field = app.textFields["add-guest-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("\(name)\n")
        app.buttons["add-guest-button"].tap()
        XCTAssertTrue(app.buttons["roster-\(name)"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testAdaptiveWorkspaceJourney() throws {
        let app = launchApp(toggle: true)
        let titleField = app.textFields["event-title-field"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 10))
        titleField.tap()
        titleField.typeText("Transition dinner\n")
        app.buttons["create-event-button"].tap()
        XCTAssertTrue(app.navigationBars["Transition dinner"].waitForExistence(timeout: 10))
        XCTAssertTrue(regionVisible(app, "workspace-compact"), "Compact region marker missing")
        XCTAssertFalse(app.otherElements["workspace-regular"].exists)

        selectTab(app, "Guests")
        addGuest(app, name: "Aster")
        addGuest(app, name: "Basil")
        selectTab(app, "Tables")
        XCTAssertTrue(app.buttons["add-table-button"].waitForExistence(timeout: 5))
        app.buttons["add-table-button"].tap()
        let labelField = app.textFields["table-label-field"]
        XCTAssertTrue(labelField.waitForExistence(timeout: 5))
        labelField.tap()
        labelField.typeText("Round1\n")
        app.buttons["confirm-add-table"].tap()
        XCTAssertTrue(app.buttons["seat-Round1-1"].waitForExistence(timeout: 8))

        // Start an ACTIVE assignment in compact: select Aster, do not seat yet.
        selectTab(app, "Guests")
        app.buttons["roster-Aster"].tap()
        XCTAssertTrue(waitIdentifiedLabel(app, identifier: "selection.current", containing: "Aster"))

        // Rotate mid-assignment: selection belongs to app state, not view
        // lifetime, so orientation cannot lose it.
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitIdentifiedLabel(app, identifier: "selection.current", containing: "Aster"))
        XCUIDevice.shared.orientation = .portrait

        // Transition to the regular workspace WHILE the selection is live.
        setRegion(app, to: "regular")
        XCTAssertTrue(regionVisible(app, "workspace-regular"))
        XCTAssertFalse(app.otherElements["workspace-compact"].exists)
        // The roster sidebar stays visible beside the chart: Aster's
        // selection section survived the layout transition.
        XCTAssertTrue(waitIdentifiedLabel(app, identifier: "selection.current", containing: "Aster"))
        // Compact-only Guests tab is gone; the chart column keeps its tabs.
        XCTAssertFalse(app.tabBars.buttons["Guests"].exists)
        XCTAssertTrue(app.tabBars.buttons["Tables"].waitForExistence(timeout: 5))

        // Complete the assignment in the regular region with plain taps.
        XCTAssertTrue(app.buttons["seat-Round1-1"].waitForExistence(timeout: 8))
        app.buttons["seat-Round1-1"].tap()
        XCTAssertTrue(waitLabel(app.buttons["seat-Round1-1"], containing: "Aster"))
        XCTAssertTrue(waitIdentifiedLabel(app, identifier: "seating.summary", containing: "1 seated"))
        XCTAssertTrue(app.images["focus-Round1"].waitForExistence(timeout: 5),
                      "Table focus marker missing after seating")

        // Switch back to compact and forward again: the tap-focus on
        // Round1 and the completed assignment must both survive, and the
        // roster remains permanently beside the chart in regular width.
        setRegion(app, to: "compact")
        XCTAssertTrue(regionVisible(app, "workspace-compact"))
        XCTAssertTrue(app.tabBars.buttons["Guests"].exists)
        setRegion(app, to: "regular")
        XCTAssertTrue(regionVisible(app, "workspace-regular"))
        selectTab(app, "Tables")
        XCTAssertTrue(waitLabel(app.buttons["seat-Round1-1"], containing: "Aster"))
        XCTAssertTrue(app.images["focus-Round1"].exists,
                      "Table focus lost across region transitions")

        app.terminate()
    }
}
