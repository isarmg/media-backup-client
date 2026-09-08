import XCTest

final class NavigationTests: XCTestCase {
    @MainActor func testLoginRemainsReachableFromGalleryAndSettings() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let account = app.buttons["account.open"]
        XCTAssertTrue(account.waitForExistence(timeout: 15))
        screenshot("local-gallery-loading")
        print(app.debugDescription)
        let selection = app.buttons["media.select.layout-photo-1.png"]
        XCTAssertTrue(selection.waitForExistence(timeout: 30), app.debugDescription)
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
    @MainActor func testSystemPickerConfirmationShowsThumbnailGrid() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["gallery.add"].waitForExistence(timeout: 20))
        app.buttons["gallery.add"].tap()
        app.buttons["gallery.system-picker"].tap()
        let photo = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 20), app.debugDescription)
        photo.tap()
        let add = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@ OR label == %@ OR label == %@", "添加", "Add", "完成", "Done"))
            .allElementsBoundByIndex.first(where: { $0.isHittable })
        XCTAssertNotNil(add, app.debugDescription)
        add?.tap()
        XCTAssertTrue(app.staticTexts["选择要备份的媒体"].waitForExistence(timeout: 15), app.debugDescription)
        let preview = app.descendants(matching: .any).matching(identifier: "selection.preview.0").firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertGreaterThan(preview.frame.width, 80)
        screenshot("selected-media-confirmation")
        app.buttons["取消本次选择"].tap()
    }

    @MainActor private func screenshot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? screenshot.pngRepresentation.write(to: documents.appendingPathComponent(name + ".png"))
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
