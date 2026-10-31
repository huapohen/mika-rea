import XCTest

extension DeviceControlTests {
    @MainActor func testExecutionModeAndCompletionReturnPersist() throws {
        let app=XCUIApplication(bundleIdentifier:"com.huapohen.mikaremote")
        // Isolate settings persistence from the separately tested overlay window.
        // NSArgumentDomain changes apply only to this test process.
        app.launchArguments=["-capsuleMode","off"]
        func openSettings() {
            XCTAssertTrue(app.buttons["菜单"].waitForExistence(timeout:15))
            app.buttons["菜单"].tap()
            XCTAssertTrue(app.buttons["设置"].waitForExistence(timeout:5))
            app.buttons["设置"].tap()
            app.buttons["settingsLocalControl"].tap()
        }
        func show(_ element:XCUIElement) {
            for _ in 0..<5 {if element.isHittable {return};app.swipeUp()}
            XCTAssertTrue(element.isHittable)
        }
        app.launch();openSettings()
        let picker=app.buttons["localExecutionMode"]
        show(picker)
        let originalMode=picker.value as? String ?? "后台运行"
        let completion=app.switches["localReturnAfterTask"]
        let originalReturn=completion.value as? String ?? "0"
        picker.tap();app.buttons["兼容模式"].tap()
        XCTAssertEqual(picker.value as? String,"兼容模式")
        XCTAssertFalse(completion.isEnabled)
        picker.tap();app.buttons["后台运行"].tap()
        XCTAssertTrue(completion.isEnabled)
        if completion.value as? String != "1" {completion.coordinate(withNormalizedOffset:CGVector(dx:0.92,dy:0.5)).tap()}
        XCTAssertEqual(completion.value as? String,"1")
        app.terminate();app.launch();openSettings();show(picker)
        XCTAssertEqual(picker.value as? String,"后台运行")
        XCTAssertEqual(completion.value as? String,"1")
        if originalReturn != "1" {completion.coordinate(withNormalizedOffset:CGVector(dx:0.92,dy:0.5)).tap()}
        if originalMode != "后台运行" {picker.tap();app.buttons[originalMode].tap()}
    }
}
