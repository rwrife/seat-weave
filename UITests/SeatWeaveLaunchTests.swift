import XCTest

final class SeatWeaveLaunchTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testFreshLaunchShowsEventList() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-resetStore", "YES"]
        app.launch()

        // A fresh install opens on the local event list, not a workspace.
        XCTAssertTrue(app.staticTexts["Create a gathering"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["event-title-field"].exists)
        XCTAssertTrue(app.buttons["create-event-button"].exists)
    }
}
