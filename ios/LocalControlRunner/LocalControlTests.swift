import XCTest

/// The production driver has its own bundle, containing exactly one long-lived test.
/// Navigation/provider tests must never be launched by the phone bootstrap.
final class MikaLocalControlTests:XCTestCase {
    func testServeMika() throws {
        guard let token=ProcessInfo.processInfo.environment["MIKA_LOCAL_TOKEN"],token.count>=32 else {throw XCTSkip("由 Mika 的本机启动器显式启动")}
        continueAfterFailure=false
        let server=LocalControlServer(token:token)
        try server.start()
        defer {server.stop()}
        XCUIApplication(bundleIdentifier:"com.huapohen.mikaremote").activate()
        while !server.stopped {RunLoop.current.run(until:Date().addingTimeInterval(0.1))}
    }
}
