import XCTest

extension DeviceControlTests {
    @MainActor func testRemoteIOSCancellationFromCapsule() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Run the controller in the simulator so the physical phone can own its local execution session")
        #else
        let app=XCUIApplication(bundleIdentifier:"com.huapohen.mikaremote")
        app.launch()
        XCTAssertTrue(app.buttons["新对话"].waitForExistence(timeout:12))
        app.buttons["新对话"].tap()
        let input=app.descendants(matching:.any).matching(identifier:"taskInput").firstMatch
        input.tap()
        input.typeText("On the target iPhone, read only the iOS version in Settings, then the app version on Clash Mi About. Repeat both read-only checks three times and return to Mika. Never change settings or read personal identifiers.")
        app.buttons["发送"].tap()
        XCTAssertTrue(app.descendants(matching:.any).matching(identifier:"taskProgress").firstMatch.waitForExistence(timeout:25))
        let ball=app.buttons["mikaCapsuleBall"]
        XCTAssertTrue(ball.waitForExistence(timeout:5));ball.tap()
        let stop=app.buttons["capsuleStop"]
        XCTAssertTrue(stop.waitForExistence(timeout:5));stop.tap()
        app.buttons["收起胶囊"].tap()
        XCTAssertTrue(app.staticTexts["任务已停止。"].waitForExistence(timeout:60))
        #endif
    }
}
