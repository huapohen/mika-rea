import XCTest

extension DeviceControlTests {
    @MainActor private func interactionController()->XCUIApplication {
        let app=XCUIApplication(bundleIdentifier:"com.huapohen.mikaremote");app.launch()
        let fresh=app.buttons["新对话"]
        XCTAssertTrue(fresh.waitForExistence(timeout:12))
        if !fresh.isEnabled,app.buttons["查看"].exists,app.buttons["查看"].isEnabled {app.buttons["查看"].tap()}
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate(format:"enabled == true"),object:fresh)],timeout:25),.completed)
        fresh.tap();return app
    }
    @MainActor func testRemoteIOSQuestionAndConfirmation() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Controller runs in simulator; real iPhone owns its local XCTest session")
        #else
        let app=interactionController()
        let input=app.descendants(matching:.any).matching(identifier:"taskInput").firstMatch
        input.tap();input.typeText("Before opening any app, call ask_user with prompt exactly MIKA_PICK_VERSION and options iOS and Clash Mi. Wait for my choice. Then call request_confirmation with prompt exactly MIKA_CONFIRM_READ and wait. If approved, open the selected app and read only its installed version from the real UI, then return to Mika. If declined, do not open an app. Do not change settings or read identifiers.")
        app.buttons["发送"].tap()
        let question=app.staticTexts.matching(identifier:"MIKA_PICK_VERSION").firstMatch
        XCTAssertTrue(question.waitForExistence(timeout:45))
        app.buttons["Clash Mi"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts.matching(identifier:"MIKA_CONFIRM_READ").firstMatch.waitForExistence(timeout:45))
        app.buttons["同意继续"].tap()
        let result=app.staticTexts.matching(NSPredicate(format:"label CONTAINS %@","1.0.31.1703")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout:120))
        #endif
    }
    @MainActor func testRemoteIOSHandoffThroughOwnerUI() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Controller runs in simulator; owner UI is exercised by the on-device runner")
        #else
        let app=interactionController()
        let input=app.descendants(matching:.any).matching(identifier:"taskInput").firstMatch
        input.tap();input.typeText("Call hand_to_user with message exactly MIKA_OWNER_UI_ACCEPTANCE and bundle_id com.nebula.clashmi. This is a read-only owner handoff UI test. Wait for the phone owner to return control, then read the Clash Mi About version from the real UI and return to Mika. Do not change VPN, proxy settings or any other setting.")
        app.buttons["发送"].tap()
        let prompt=app.staticTexts.matching(identifier:"MIKA_OWNER_UI_ACCEPTANCE").firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout:45))
        XCTAssertFalse(app.buttons["我已处理，继续核实"].exists,"The controller must not be able to acknowledge the owner's local step")
        let result=app.staticTexts.matching(NSPredicate(format:"label CONTAINS %@","1.0.31.1703")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout:120))
        #endif
    }
    @MainActor func testRemoteIOSCancelWhileWaitingForAnswer() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Controller runs in simulator; real iPhone owns execution")
        #else
        let app=interactionController()
        let input=app.descendants(matching:.any).matching(identifier:"taskInput").firstMatch
        input.tap();input.typeText("Before any phone actions, call ask_user with prompt exactly MIKA_CANCEL_WHILE_WAITING and wait for my answer. Do not open or read any app before I answer.")
        app.buttons["发送"].tap()
        XCTAssertTrue(app.staticTexts.matching(identifier:"MIKA_CANCEL_WHILE_WAITING").firstMatch.waitForExistence(timeout:45))
        app.buttons["mikaCapsuleBall"].tap()
        app.buttons["capsuleStop"].tap();app.buttons["收起胶囊"].tap()
        XCTAssertTrue(app.staticTexts["任务已停止。"].waitForExistence(timeout:45))
        #endif
    }
}
