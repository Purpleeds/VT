import XCTest

final class VoiceBloomUITests: XCTestCase {
    @MainActor
    func testAppLaunchesToPractice() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(app.buttons["Start Listening"].waitForExistence(timeout: 10))
    }
}
