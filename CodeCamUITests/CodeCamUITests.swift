import XCTest
final class CodeCamUITests: XCTestCase {
    @MainActor func testCaptureAndRelaunch() throws {
        let app = XCUIApplication(); app.launch()
        let serial = "UITEST-" + UUID().uuidString.prefix(8)
        let input = app.textFields["serialInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap(); input.typeText(String(serial))
        app.buttons["开始采集"].tap()
        let note = app.textFields["noteInput"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        note.tap(); note.typeText("Inspection passed")
        app.terminate(); app.launch()
        XCTAssertTrue(app.staticTexts[String(serial)].waitForExistence(timeout: 10))
        app.staticTexts[String(serial)].firstMatch.tap()
        XCTAssertEqual(app.textFields["noteInput"].value as? String, "Inspection passed")
        app.swipeUp()
        app.buttons["完成采集"].tap()
        XCTAssertTrue(app.staticTexts["采集已完成"].waitForExistence(timeout: 5))
    }
}
