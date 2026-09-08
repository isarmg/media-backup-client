import XCTest

final class NavigationTests: XCTestCase {
    @MainActor func testLoginRemainsReachableFromGalleryAndSettings() {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let account = app.buttons["account.open"]
        XCTAssertTrue(account.waitForExistence(timeout: 15))
        let selection = app.buttons["media.select.layout-photo-1.png"]
        XCTAssertTrue(selection.waitForExistence(timeout: 15))
        let tile = app.descendants(matching: .any).matching(identifier: "media.tile.layout-photo-1.png").firstMatch
        XCTAssertTrue(tile.exists)
        XCTAssertGreaterThan(selection.frame.midX, tile.frame.midX)
        XCTAssertLessThan(selection.frame.midY, tile.frame.midY)
        selection.tap()
        XCTAssertTrue(app.staticTexts["已选 1 项"].waitForExistence(timeout: 5))
        XCTAssertTrue(account.isHittable)
        screenshot("local-gallery-selected")
        selection.tap()
        screenshot("local-gallery")
        account.tap()
        XCTAssertTrue(app.textFields["account.server"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["account.username"].exists)
        XCTAssertTrue(app.secureTextFields["account.password"].exists)
        XCTAssertFalse(app.buttons["account.submit"].isEnabled)
        screenshot("account-login")
        app.buttons["取消"].tap()
        app.tabBars.buttons["设置"].tap()
        XCTAssertTrue(app.buttons["settings.login"].waitForExistence(timeout: 5))
        screenshot("settings")
        app.buttons["settings.login"].tap()
        XCTAssertTrue(app.buttons["account.submit"].waitForExistence(timeout: 5))
        app.buttons["取消"].tap()
        app.tabBars.buttons["传输"].tap()
        screenshot("transfers")
    }
    @MainActor private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
