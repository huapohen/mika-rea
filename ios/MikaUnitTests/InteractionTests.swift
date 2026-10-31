import XCTest
@testable import MikaIOS

@MainActor private final class QuestionPhoneWorker:IOSPhoneWorker {
    var available=true
    var model:Model? {nil}
    var progressHandler:((String)->Void)?
    var interactionHandler:((PhoneInteraction?) throws -> Void)?
    let gate=PhoneInteractionGate()
    var starts=0
    init() {gate.onChange={ [weak self] item in try self?.interactionHandler?(item) }}
    func execute(goal:String,conversation:String) async throws -> String {
        starts+=1
        let first=try await gate.ask(kind:.question,prompt:"Which version?",options:["iOS","Clash Mi"])
        let second=try await gate.ask(kind:.question,prompt:"Which format?",options:["Short","Detailed"])
        return "\(first["answer"]!) / \(second["answer"]!)"
    }
    func respond(interactionID:String,text:String,source:PhoneInteraction.Source) throws {try gate.respond(id:interactionID,text:text,source:source)}
    func cancel() async {if let id=gate.pending?.id {gate.cancel(id)}}
}

@MainActor final class InteractionTests:XCTestCase {
    private func until(_ condition:()->Bool) async throws {
        for _ in 0..<100 {if condition() {return};try await Task.sleep(nanoseconds:10_000_000)}
        XCTFail("Interaction did not reach expected state")
    }
    func testQuestionAnswerContinuesOnlyTheMatchingToolCall() async throws {
        let gate=PhoneInteractionGate()
        let task=Task {try await gate.ask(kind:.question,prompt:"Pick one",options:["A","B"])}
        defer {task.cancel()}
        try await until {gate.pending != nil}
        let id=try XCTUnwrap(gate.pending?.id)
        XCTAssertThrowsError(try gate.respond(id:"stale-question",text:"A",source:.owner))
        XCTAssertEqual(gate.pending?.id,id)
        try gate.respond(id:id,text:"B",source:.owner)
        let result=try await task.value
        XCTAssertEqual(result["answer"] as? String,"B");XCTAssertNil(gate.pending)
        XCTAssertThrowsError(try gate.respond(id:id,text:"A",source:.owner))
    }
    func testConfirmationRequiresAnExplicitDecisionAndCanBeDeclined() async throws {
        let gate=PhoneInteractionGate()
        let task=Task {try await gate.ask(kind:.confirmation,prompt:"Use the short format?")}
        defer {task.cancel()}
        try await until {gate.pending != nil}
        let id=try XCTUnwrap(gate.pending?.id)
        XCTAssertThrowsError(try gate.respond(id:id,text:"maybe",source:.controller))
        try gate.respond(id:id,text:"decline",source:.controller)
        let result=try await task.value
        XCTAssertEqual(result["approved"] as? Bool,false)
    }
    func testHandoffRequiresPhoneOwnerAndDoesNotClaimVerification() async throws {
        let gate=PhoneInteractionGate()
        let task=Task {try await gate.ask(kind:.handoff,prompt:"Handle this on the phone",bundleID:"com.apple.Preferences")}
        defer {task.cancel()}
        try await until {gate.pending != nil}
        let id=try XCTUnwrap(gate.pending?.id)
        XCTAssertThrowsError(try gate.respond(id:id,text:"complete",source:.controller))
        XCTAssertNotNil(gate.pending)
        try gate.respond(id:id,text:"complete",source:.owner)
        let result=try await task.value
        XCTAssertEqual(result["outcome"] as? String,"complete");XCTAssertEqual(result["verified"] as? Bool,false)
    }
    func testCancellationAndTimeoutNeverGrantApproval() async throws {
        let gate=PhoneInteractionGate()
        let cancelled=Task {try await gate.ask(kind:.confirmation,prompt:"Should this proceed?")}
        try await until {gate.pending != nil};cancelled.cancel()
        do {_ = try await cancelled.value;XCTFail("Cancellation must throw")} catch {XCTAssertTrue(error is CancellationError)}
        XCTAssertNil(gate.pending)
        do {_ = try await gate.ask(kind:.confirmation,prompt:"No implicit approval",timeoutSeconds:0.02);XCTFail("Timeout must throw")} catch {XCTAssertTrue(error.localizedDescription.contains("超时"))}
        XCTAssertNil(gate.pending)
    }
    func testFailedTransitionPersistenceDoesNotContinueExecution() async throws {
        let gate=PhoneInteractionGate()
        gate.onChange={item in if item==nil {throw PhoneInteraction.InteractionError("simulated disk failure")}}
        var continued=false
        let task=Task {let result=try await gate.ask(kind:.question,prompt:"Answer before continuing");continued=true;return result}
        defer {task.cancel()}
        try await until {gate.pending != nil}
        XCTAssertThrowsError(try gate.respond(id:XCTUnwrap(gate.pending?.id),text:"yes",source:.owner))
        do {_ = try await task.value;XCTFail("Disk failure must fail the suspended call")} catch {}
        XCTAssertFalse(continued);XCTAssertNil(gate.pending)
    }
    func testRemoteAnswersAreIdempotentAndCannotAnswerTheNextQuestion() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let worker=QuestionPhoneWorker(),file=directory.appendingPathComponent("tasks.json")
        let store=IOSReceiverTasks(worker:worker,storage:file)
        let submitted=try await store.call("mika_run_task",["goal":"Two choices","request_id":"question-task"])
        let taskID=try XCTUnwrap(submitted["task_id"] as? String)
        try await until {store.active?.interaction != nil}
        let first=try XCTUnwrap(store.active?.interaction)
        let start=Date();let waiting=try await store.call("mika_wait_task",["task_id":taskID,"timeout_s":10])
        XCTAssertEqual(waiting["status"] as? String,"waiting_for_answer");XCTAssertLessThan(Date().timeIntervalSince(start),1)
        let response:[String:Any]=["task_id":taskID,"interaction_id":first.id,"text":"iOS"]
        _ = try await store.call("mika_answer",response)
        try await until {store.active?.interaction?.id != nil && store.active?.interaction?.id != first.id}
        let second=try XCTUnwrap(store.active?.interaction)
        _ = try await store.call("mika_answer",response)
        XCTAssertEqual(store.active?.interaction?.id,second.id)
        do {_ = try await store.call("mika_answer",["task_id":taskID,"interaction_id":first.id,"text":"changed"]);XCTFail("A conflicting answer must fail")} catch {}
        _ = try await store.call("mika_answer",["task_id":taskID,"interaction_id":second.id,"text":"Short"])
        try await until {store.activeID==nil}
        XCTAssertEqual(store.tasks.first?.status,"done");XCTAssertEqual(store.tasks.first?.answer,"iOS / Short");XCTAssertEqual(worker.starts,1)
    }
    func testRestartWhileWaitingDoesNotReplayOrAcceptTheOldQuestion() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let worker=QuestionPhoneWorker(),file=directory.appendingPathComponent("tasks.json")
        let original=IOSReceiverTasks(worker:worker,storage:file)
        let task=try await original.call("mika_run_task",["goal":"Pause for input"])
        let id=try XCTUnwrap(task["task_id"] as? String)
        try await until {original.active?.interaction != nil}
        let question=try XCTUnwrap(original.active?.interaction)
        let freshWorker=QuestionPhoneWorker();let restored=IOSReceiverTasks(worker:freshWorker,storage:file)
        XCTAssertEqual(restored.tasks.first?.status,"failed");XCTAssertNil(restored.tasks.first?.interaction)
        do {_ = try await restored.call("mika_answer",["task_id":id,"interaction_id":question.id,"text":"iOS"]);XCTFail("An interrupted question must not resume")} catch {}
        XCTAssertEqual(freshWorker.starts,0)
        await original.cancel(id);try await until {original.activeID==nil}
        XCTAssertEqual(original.tasks.first?.status,"cancelled")
    }
}
