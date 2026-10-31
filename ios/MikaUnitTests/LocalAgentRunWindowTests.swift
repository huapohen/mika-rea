import XCTest
import UIKit
@testable import MikaIOS

@MainActor private final class RunEnvironment:AgentRunEnvironment {
    var foreground=true
    var remaining:TimeInterval=100
    var expiration:(@MainActor @Sendable ()->Void)?
    var ended=false
    func begin(_ expiration:@escaping @MainActor @Sendable ()->Void) {self.expiration=expiration;ended=false}
    func end() {ended=true}
}

@MainActor private final class ContinuedExecution:AgentContinuedExecution {
    var active=false
    var status="not_requested"
    var expiration:(()->Void)?
    var rounds:[Int]=[]
    var completion:Bool?
    func start(expiration:@escaping ()->Void) async {self.expiration=expiration;active=true;status="running"}
    func advance(round:Int) {rounds.append(round)}
    func finish(success:Bool) {active=false;completion=success;status=success ? "completed" : "stopped"}
    func expire() {active=false;expiration?()}
}

@MainActor final class LocalAgentRunWindowTests:XCTestCase {
    func testSystemSchedulerRegistrationMatchesHostManifest() async throws {
        guard #available(iOS 26.0,*),UIApplication.shared.applicationState == .active,let continued=makeAgentContinuedExecution() else {throw XCTSkip("Continued execution requires an active iOS 26 host")}
        await continued.start(expiration:{})
        let status=continued.status
        continued.finish(success:true)
        XCTAssertNotEqual(status,"registration_rejected","The scheduler identifier must match the host app's permitted wildcard")
        XCTAssertTrue(status=="running" || status.hasPrefix("submission_failed_") || status=="launch_timeout","Unexpected scheduler lifecycle: \(status)")
        // Unavailable simulator execution is explicitly not evidence of a real-device grant.
        print("Simulator continued-execution smoke status: \(status)")
    }
    func testBackgroundIsDefaultAndExplicitPreferencesSurviveReload() {
        let name=UUID().uuidString;let defaults=UserDefaults(suiteName:name)!
        defer {defaults.removePersistentDomain(forName:name)}
        XCTAssertEqual(AgentExecutionPreferences.load(defaults).mode,.background)
        XCTAssertFalse(AgentExecutionPreferences.load(defaults).returnAfterTask)
        defaults.set(false,forKey:"localSmoothExecution")
        XCTAssertEqual(AgentExecutionPreferences.load(defaults).mode,.compatibility)
        defaults.set("background",forKey:"localExecutionMode");defaults.set(true,forKey:"localReturnAfterTask")
        let restored=AgentExecutionPreferences.load(UserDefaults(suiteName:name)!)
        XCTAssertEqual(restored.mode,.background);XCTAssertTrue(restored.returnAfterTask)
    }
    func testGrantedContinuedExecutionKeepsWorkingWithoutBudgetOrFinalReturns() async throws {
        let runtime=RunEnvironment();let continued=ContinuedExecution();var actions:[String]=[]
        let window=LocalAgentRunWindow(policy:.init(mode:.background,returnAfterTask:false),environment:runtime,continuation:continued) {args,back in
            XCTAssertFalse(back);actions.append(args["action"] as! String);return [:]
        }
        await window.start();runtime.foreground=false;runtime.remaining=0
        _ = try await window.execute(["action":"source"])
        window.advance(round:1)
        _ = try await window.execute(["action":"tap"])
        await window.finish()
        XCTAssertEqual(actions,["source","tap"]);XCTAssertEqual(continued.rounds,[1]);XCTAssertEqual(continued.completion,true)
        XCTAssertFalse(runtime.foreground)
    }
    func testUnavailableBackgroundTimePausesWithoutNavigatingAndResumesOnOwnerReturn() async throws {
        let runtime=RunEnvironment();runtime.foreground=false;runtime.remaining=3
        var actions:[String]=[];let paused=expectation(description:"Paused before dispatch")
        let window=LocalAgentRunWindow(policy:.init(mode:.background,returnAfterTask:false),environment:runtime,onPause:{paused.fulfill()}) {args,_ in
            actions.append(args["action"] as! String);return args["action"] as? String=="source" ? ["elements":[[String:Any]]()] : [:]
        }
        await window.start()
        let operation=Task {try await window.execute(["action":"tap","bundle_id":"test.app"])}
        await fulfillment(of:[paused],timeout:2)
        XCTAssertTrue(actions.isEmpty);XCTAssertTrue(runtime.ended)
        runtime.foreground=true
        let withheld=try await operation.value
        XCTAssertEqual(withheld["requires_fresh_screen"] as? Bool,true)
        XCTAssertTrue(actions.isEmpty)
        _ = try await window.execute(["action":"source","bundle_id":"test.app"])
        _ = try await window.execute(["action":"tap","bundle_id":"test.app"])
        XCTAssertEqual(actions,["source","tap"])
        await window.finish()
    }
    func testCancellingAPausedTaskDoesNotRequireAnOwnerReturnOrDispatchWrites() async throws {
        let runtime=RunEnvironment();runtime.foreground=false;runtime.remaining=3
        let paused=expectation(description:"Paused");let cancelled=expectation(description:"Cancelled without foreground")
        var actions=0
        let window=LocalAgentRunWindow(policy:.init(mode:.background,returnAfterTask:false),environment:runtime,onPause:{paused.fulfill()}) {_,_ in actions+=1;return [:]}
        await window.start()
        let operation=Task {
            do {_ = try await window.execute(["action":"type"]);XCTFail("Cancelled write ran")}
            catch {XCTAssertTrue(error is CancellationError);cancelled.fulfill()}
        }
        await fulfillment(of:[paused],timeout:2);operation.cancel()
        await fulfillment(of:[cancelled],timeout:2)
        runtime.foreground=true // Cleanup can settle even if the assertion above fails.
        await operation.value;await window.finish(success:false)
        XCTAssertEqual(actions,0)
    }
    func testContinuedExecutionExpirationStopsQueuedWritesAndReportsFailure() async throws {
        let runtime=RunEnvironment();let continued=ContinuedExecution();var actions=0;var expirations=0
        let window=LocalAgentRunWindow(policy:.init(mode:.background,returnAfterTask:false),environment:runtime,continuation:continued,onExpiration:{expirations+=1}) {_,_ in actions+=1;return [:]}
        await window.start();continued.expire()
        do {_ = try await window.execute(["action":"tap"]);XCTFail("Expired write ran")} catch {}
        await window.finish(success:false)
        XCTAssertEqual(actions,0);XCTAssertEqual(expirations,1);XCTAssertEqual(continued.completion,false)
    }
    func testContinuousOperationsStayInTargetUntilOneFinalReturn() async throws {
        let runtime=RunEnvironment();var actions:[String]=[];var flags:[Bool]=[]
        let window=LocalAgentRunWindow(smooth:true,environment:runtime) {args,back in
            let action=args["action"] as! String
            actions.append(action);flags.append(back);runtime.foreground=action == "return"
            return action=="source" ? ["elements":[[String:Any]]()] : ["applied":true]
        }
        await window.start()
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
            return action=="source" ? ["elements":[[String:Any]]()] : ["applied":true]
        }
        await window.start()
        let withheld=try await window.execute(["action":"tap","bundle_id":"test.app"])
        XCTAssertEqual(withheld["requires_fresh_screen"] as? Bool,true)
        _ = try await window.execute(["action":"source","bundle_id":"test.app"])
        _ = try await window.execute(["action":"tap","bundle_id":"test.app"])
        try await window.prepare()
        XCTAssertEqual(actions,["return","source","tap"])
        await window.finish();XCTAssertEqual(actions,["return","source","tap"])
    }
    func testExpiredBudgetNeverDispatchesAQueuedWrite() async throws {
        let runtime=RunEnvironment();var actions=0
        let window=LocalAgentRunWindow(smooth:true,environment:runtime) {_,_ in actions+=1;return [:]}
        await window.start();runtime.expiration?()
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
        await window.start();try await window.showInteraction()
        XCTAssertTrue(runtime.foreground);XCTAssertEqual(returns,1)
        await window.finish();XCTAssertEqual(returns,1)
    }
}
