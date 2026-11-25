import XCTest

final class WebEditorSettingsUITests: XCTestCase {
    func testTokenIsHiddenAndPortAutoSaves() {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment["PROXYCAT_WEB_TOKEN"] = "ui-test-token"
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        sleep(2)

        app.tabBars.buttons.element(boundBy: 3).tap()
        sleep(1)
        app.buttons["settings.webEditor"].tap()
        sleep(2)

        let toggle = app.switches["webEditor.enable"].exists
            ? app.switches["webEditor.enable"]
            : app.switches["启用网页编辑器"]
        if toggle.exists, (toggle.value as? String) == "0" {
            toggle.tap()
        }
        let accessURL = app.staticTexts["webEditor.accessURL"]
        XCTAssertTrue(accessURL.waitForExistence(timeout: 10))

        // The full token must not be rendered anywhere on the settings page.
        let tokenText = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "ui-test-token")
        )
        XCTAssertEqual(tokenText.count, 0)
        let tokenLike = app.staticTexts.matching(
            NSPredicate(format: "label MATCHES %@", "[0-9a-f]{64}")
        )
        XCTAssertEqual(tokenLike.count, 0)

        // Editing the port applies immediately; there is no Save button.
        let portField = app.textFields["webEditor.port"]
        XCTAssertTrue(portField.waitForExistence(timeout: 5))
        portField.tap()
        sleep(1)
        portField.press(forDuration: 1.0)
        sleep(1)
        if app.menuItems["全选"].exists {
            app.menuItems["全选"].tap()
        } else if app.menuItems["Select All"].exists {
            app.menuItems["Select All"].tap()
        }
        portField.typeText("47899")

        var sawUpdatedURL = false
        for _ in 0..<10 {
            if accessURL.label.contains(":47899/") {
                sawUpdatedURL = true
                break
            }
            sleep(1)
        }
        XCTAssertTrue(sawUpdatedURL)
        XCTAssertFalse(app.buttons["保存"].exists)
    }
}
