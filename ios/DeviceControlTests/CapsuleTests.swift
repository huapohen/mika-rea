import XCTest

extension DeviceControlTests {
    @MainActor func testCapsuleInterfaceAndSystemActivity() throws {
        let app=XCUIApplication(bundleIdentifier:"com.huapohen.mikaremote")
        app.launch()
        app.buttons["新对话"].tap()
        let ball=app.buttons["mikaCapsuleBall"]
        XCTAssertTrue(ball.waitForExistence(timeout:12))
        ball.tap()
        let input=app.descendants(matching:.any).matching(identifier:"capsuleTaskInput").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout:5))
        let capsuleShot=XCTAttachment(screenshot:app.screenshot());capsuleShot.name="Mika capsule input card";capsuleShot.lifetime = .keepAlways;add(capsuleShot)
        input.tap();input.typeText("Capsule input check")
        XCTAssertTrue(app.buttons["capsuleSend"].isEnabled)
        app.buttons["收起胶囊"].tap()
        // Outside the bubble, the underlying toolbar must still receive taps.
        app.buttons["菜单"].tap();app.buttons["设置"].tap()
        app.buttons["settingsCapsule"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["悬浮胶囊"].waitForExistence(timeout:5))
        app.buttons["关闭"].firstMatch.tap()
        XCTAssertFalse(ball.exists)
        app.buttons["总是显示"].firstMatch.tap()
        XCTAssertTrue(ball.waitForExistence(timeout:3))
        let start=ball.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5))
        let wasRight=ball.frame.midX>app.frame.midX
        let destination=app.coordinate(withNormalizedOffset:CGVector(dx:wasRight ? 0.12 : 0.88,dy:0.4))
        start.press(forDuration:0.15,thenDragTo:destination)
        XCTAssertTrue(ball.exists)
        if wasRight {XCTAssertLessThan(ball.frame.midX,app.frame.midX)} else {XCTAssertGreaterThan(ball.frame.midX,app.frame.midX)}
        XCTAssertFalse(app.descendants(matching:.any).matching(identifier:"capsuleTaskInput").firstMatch.exists)
        app.buttons["capsulePreview"].tap()
        XCTAssertTrue(app.staticTexts["系统胶囊已显示"].waitForExistence(timeout:8))
        XCUIDevice.shared.press(.home)
        let springboard=XCUIApplication(bundleIdentifier:"com.apple.springboard")
        // Expand the real Dynamic Island; this is an ordinary UI interaction.
        springboard.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.032)).press(forDuration:1.2)
        let stop=springboard.buttons["mikaLiveStop"].firstMatch
        let labelled=springboard.buttons.matching(NSPredicate(format:"label CONTAINS %@","结束预览")).firstMatch
        let action=stop.exists ? stop : labelled
        XCTAssertTrue(action.waitForExistence(timeout:5),"Live Activity stop button was not exposed in Dynamic Island")
        action.tap()
        app.activate()
        XCTAssertTrue(app.staticTexts["已通过系统按钮结束预览"].waitForExistence(timeout:8))
        XCTAssertTrue(app.staticTexts["当前没有系统胶囊"].waitForExistence(timeout:8))
    }
}
