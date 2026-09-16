import XCTest

final class SeatWeaveLaunchTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testBootstrapHomeLaunches() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()

        XCTAssertTrue(app.otherElements["bootstrap.home"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Seat Weave"].exists)
        XCTAssertTrue(app.staticTexts["Event setup and seating tools arrive in the next milestones."].exists)
    }
}
