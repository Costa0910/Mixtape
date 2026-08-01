import XCTest

final class PhysicalLayoutTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testCaptureListenNowBottom() throws {
        let app = XCUIApplication()
        app.launch()

        let smartMix = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Smart Mix")
        ).firstMatch
        XCTAssertTrue(smartMix.waitForExistence(timeout: 5))
        smartMix.tap()

        let miniPlayer = app.descendants(matching: .any)
            .matching(identifier: "miniPlayer")
            .firstMatch
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 5))

        for _ in 0..<10 {
            app.swipeUp(velocity: .fast)
        }

        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "physical-listen-now-bottom"
        attachment.lifetime = .keepAlways
        add(attachment)

        miniPlayer.tap()
        let playerScreenshot = XCUIScreen.main.screenshot()
        let playerAttachment = XCTAttachment(screenshot: playerScreenshot)
        playerAttachment.name = "physical-now-playing-volume"
        playerAttachment.lifetime = .keepAlways
        add(playerAttachment)

        print("PHYSICAL_UI_HIERARCHY_BEGIN")
        print(app.debugDescription)
        print("PHYSICAL_UI_HIERARCHY_END")
    }
}
