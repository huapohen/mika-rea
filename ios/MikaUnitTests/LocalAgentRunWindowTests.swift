import XCTest
@testable import MikaIOS

@MainActor private final class RunEnvironment:AgentRunEnvironment {
    var foreground=true
    var remaining:TimeInterval=100
    var expiration:(()->Void)?
    var ended=false
    func begin(_ expiration:@escaping ()->Void) {self.expiration=expiration;ended=false}
    func end() {ended=true}
}

@MainActor final class LocalAgentRunWindowTests:XCTestCase {
    func testContinuousOperationsStayInTargetUntilOneFinalReturn() async throws {
        let runtime=RunEnvironment();var actions:[String]=[];var flags:[Bool]=[]
        let window=LocalAgentRunWindow(smooth:true,environment:runtime) {args,back in
            let action=args["action"] as! String
            actions.append(action);flags.append(back);runtime.foreground=action == "return"
            return ["applied":true]
        }
        window.start()
        for action in ["launch","source","tap","source"] {_ = try await window.execute(["action":action])}
        XCTAssertEqual(actions,["launch","source","tap","source"])
        XCTAssertEqual(flags,[false,false,false,false])
        XCTAssertFalse(runtime.foreground)
        await window.finish()
        XCTAssertEqual(actions.last,"return");XCTAssertEqual(actions.filter {$0=="return"}.count,1)
        XCTAssertTrue(runtime.foreground);XCTAssertTrue(runtime.ended)
    }
    func testLowBudgetReturnsBeforeAnotherWriteAndDoesNotLoopInForeground() async throws {
        let runtime=RunEnvironment();runtime.foreground=false;runtime.remaining=4
        var actions:[String]=[]
        let window=LocalAgentRunWindow(smooth:true,environment:runtime) {args,_ in
            let action=args["action"] as! String;actions.append(action)
            if action=="return" {runtime.foreground=true}
            return ["applied":true]
        }
        window.start()
        _ = try await window.execute(["action":"tap"])
        try await window.prepare()
        XCTAssertEqual(actions,["return","tap"])
        await window.finish();XCTAssertEqual(actions,["return","tap"])
    }
    func testExpiredBudgetNeverDispatchesAQueuedWrite() async throws {
        let runtime=RunEnvironment();var actions=0
        let window=LocalAgentRunWindow(smooth:true,environment:runtime) {_,_ in actions+=1;return [:]}
        window.start();runtime.expiration?()
        do {_ = try await window.execute(["action":"type","text":"must not be typed"]);XCTFail("expired work dispatched")}
        catch {XCTAssertTrue(error.localizedDescription.contains("后台时间"))}
        XCTAssertEqual(actions,0);await window.finish()
    }
    func testInteractionReturnsBeforeWaitingForOwner() async throws {
        let runtime=RunEnvironment();runtime.foreground=false
        var returns=0
        let window=LocalAgentRunWindow(smooth:true,environment:runtime) {args,_ in
            if args["action"] as? String=="return" {returns+=1;runtime.foreground=true}
            return [:]
        }
        window.start();try await window.showInteraction()
        XCTAssertTrue(runtime.foreground);XCTAssertEqual(returns,1)
        await window.finish();XCTAssertEqual(returns,1)
    }
}
