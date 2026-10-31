import XCTest
final class DeviceControlTests: XCTestCase {
    override func setUpWithError() throws {continueAfterFailure=false}
    func testNavigationAndInput() throws {
        let app = XCUIApplication(bundleIdentifier:"com.huapohen.mikaremote")
        app.launch()
        let input=app.descendants(matching:.any).matching(identifier:"taskInput").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout:15))
        app.buttons["菜单"].tap()
        app.buttons["设置"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout:5))
        app.descendants(matching:.any).matching(identifier:"settingsModels").firstMatch.tap()
        XCTAssertTrue(app.navigationBars["模型"].waitForExistence(timeout:5))
        app.navigationBars.buttons.element(boundBy:0).tap()
        app.buttons["完成"].tap()
        app.buttons["菜单"].tap()
        app.buttons["连接设备"].tap()
        XCTAssertTrue(app.navigationBars["手机操作"].waitForExistence(timeout:5))
        app.buttons["完成"].tap()
        input.tap()
        input.typeText("UI input test")
        XCTAssertTrue(app.buttons["发送"].isEnabled)
        XCTAssertTrue(String(describing:input.value ?? "").contains("UI input test"))
    }
    func testConfiguredProvider() throws {
        let app = XCUIApplication(bundleIdentifier:"com.huapohen.mikaremote")
        app.launch()
        XCTAssertTrue(app.buttons["菜单"].waitForExistence(timeout:15))
        app.buttons["菜单"].tap()
        app.buttons["设置"].tap()
        app.descendants(matching:.any).matching(identifier:"settingsModels").firstMatch.tap()
        let test=app.buttons["测试连接"]
        XCTAssertTrue(test.waitForExistence(timeout:5))
        XCTAssertTrue(test.isEnabled)
        test.tap()
        XCTAssertTrue(app.staticTexts["已连接 · 主模型可用"].waitForExistence(timeout:30))
    }
    func testRelayPhoneControl() throws {
        let app = XCUIApplication(bundleIdentifier:"com.huapohen.mikaremote")
        app.launch()
        XCTAssertTrue(app.buttons["新对话"].waitForExistence(timeout:15))
        app.buttons["新对话"].tap()
        let input=app.descendants(matching:.any).matching(identifier:"taskInput").firstMatch
        input.tap()
        input.typeText("Open Android Settings. Read the Android version from the system UI. Do not change any settings.")
        app.buttons["发送"].tap()
        let answer=app.staticTexts.matching(NSPredicate(format:"label CONTAINS %@", "16")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout:180))
    }
    func testRelayAndroid() throws {
        let app = XCUIApplication(bundleIdentifier: "com.huapohen.mikaremote")
        app.launch()
        addUIInterruptionMonitor(withDescription: "Local network") { alert in
            let allow = alert.buttons["允许"]
            if allow.exists { allow.tap(); return true }
            let ok = alert.buttons["Allow"]
            if ok.exists { ok.tap(); return true }
            return false
        }
        let input = app.textFields["taskInput"]
        XCTAssertTrue(input.waitForExistence(timeout:15))
        input.tap()
        input.typeText("Please answer exactly MIKA_RELAY_OK. Do not open any app.")
        app.buttons["发送"].tap()
        app.tap()
        let reply = app.staticTexts["MIKA_RELAY_OK"]
        XCTAssertTrue(reply.waitForExistence(timeout:120))
    }
    func testLaunchSettings() throws {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(settings.navigationBars.firstMatch.waitForExistence(timeout: 10))
    }
}
