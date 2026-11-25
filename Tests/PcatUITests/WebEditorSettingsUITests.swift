import XCTest

final class WebEditorSettingsUITests: XCTestCase {
    func testTokenIsHiddenAndPortAutoSaves() {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment["PROXYCAT_WEB_TOKEN"] = "ui-test-token"
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))

        let settingsTab = app.tabBars.buttons.element(boundBy: 3)
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 20))
        settingsTab.tap()

        let webEditorRow = app.buttons["settings.webEditor"]
        XCTAssertTrue(webEditorRow.waitForExistence(timeout: 10))
        webEditorRow.tap()

        // Wait for the screen to mount instead of relying on a fixed sleep;
        // querying `exists` too early silently skipped the toggle tap and
        // produced a misleading "no access URL" failure.
        let toggle = app.switches["webEditor.enable"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "Web editor toggle did not appear")
        if (toggle.value as? String) == "0" {
            // The identifier lands on the accessibility wrapper for the
            // whole Form row; tapping its center hits the label and, on
            // iOS 26, does not flip the switch. Tap the actual control.
            let control = toggle.switches.firstMatch
            if control.exists {
                control.tap()
            } else {
                toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            }
        }
        let turnedOn = expectation(
            for: NSPredicate(format: "value == '1'"),
            evaluatedWith: toggle
        )
        wait(for: [turnedOn], timeout: 10)

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

        // Editing the port applies automatically; there is no Save button.
        let portField = app.textFields["webEditor.port"]
        XCTAssertTrue(portField.waitForExistence(timeout: 5))
        portField.tap()
        let existingPort = (portField.value as? String) ?? ""
        portField.typeText(
            String(repeating: XCUIKeyboardKey.delete.rawValue, count: existingPort.count)
        )
        portField.typeText("47899")

        let updatedURL = expectation(
            for: NSPredicate(format: "label CONTAINS %@", ":47899/"),
            evaluatedWith: accessURL
        )
        wait(for: [updatedURL], timeout: 10)
        XCTAssertFalse(app.buttons["保存"].exists)
    }
}
