import XCTest
@testable import MikaIOS

@MainActor private final class WaitingPhoneWorker:IOSPhoneWorker {
    var available=true
    var model:Model? {nil}
    var progressHandler:((String)->Void)?
    var interactionHandler:((PhoneInteraction?) throws -> Void)?
    func respond(interactionID:String,text:String,source:PhoneInteraction.Source) throws {throw CancellationError()}
    var starts=0
    var cancellations=0
    private var continuation:CheckedContinuation<String,Error>?
    func execute(goal:String,conversation:String) async throws -> String {
        starts+=1;progressHandler?("正在执行测试步骤")
        return try await withCheckedThrowingContinuation {continuation=$0}
    }
    func complete() {continuation?.resume(returning:"Finished once");continuation=nil}
    func cancel() async {cancellations+=1;continuation?.resume(throwing:CancellationError());continuation=nil}
}

@MainActor final class IOSReceiverTests:XCTestCase {
    private func until(_ condition:()->Bool) async throws {
        for _ in 0..<100 {if condition() {return};try await Task.sleep(nanoseconds:10_000_000)}
        XCTFail("Task lifecycle did not settle")
    }
    func testDuplicateSubmissionExecutesOnceAndCancellationIsScoped() async throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:dir)}
        let worker=WaitingPhoneWorker();let store=IOSReceiverTasks(worker:worker,storage:dir.appendingPathComponent("tasks.json"))
        let args:[String:Any]=["goal":"Read a version","request_id":"submission-one"]
        let first=try await store.call("mika_run_task",args)
        let id=try XCTUnwrap(first["task_id"] as? String)
        let duplicate=try await store.call("mika_run_task",args)
        XCTAssertEqual(duplicate["task_id"] as? String,id)
        try await until {worker.starts==1}
        do {_ = try await store.call("mika_run_task",["goal":"Different goal","request_id":"submission-one"]);XCTFail("Conflicting submission must fail")} catch {}
        do {_ = try await store.call("mika_run_task",["goal":"Another concurrent job"]);XCTFail("Concurrent UI control must fail")} catch {}
        await store.cancel("old-task-id");XCTAssertEqual(worker.cancellations,0)
        await store.cancel(id)
        try await until {store.activeID==nil}
        XCTAssertEqual(worker.starts,1);XCTAssertEqual(worker.cancellations,1)
        XCTAssertEqual(store.tasks.first?.status,"cancelled")
        let terminalDuplicate=try await store.call("mika_run_task",args)
        XCTAssertEqual(terminalDuplicate["task_id"] as? String,id);XCTAssertEqual(worker.starts,1)
    }
    func testRestartPreservesTaskWithoutReplayingAndReturnsMCPResult() async throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:dir)}
        let file=dir.appendingPathComponent("tasks.json")
        let worker=WaitingPhoneWorker();let original=IOSReceiverTasks(worker:worker,storage:file)
        let request:[String:Any]=["goal":"Read current screen","request_id":"restart-one"]
        let submitted=try await original.call("mika_run_task",request)
        try await until {worker.starts==1}
        let freshWorker=WaitingPhoneWorker();let restored=IOSReceiverTasks(worker:freshWorker,storage:file)
        XCTAssertNil(restored.activeID);XCTAssertEqual(freshWorker.starts,0)
        XCTAssertEqual(restored.tasks.first?.status,"failed")
        let duplicate=try await restored.call("mika_run_task",request)
        XCTAssertEqual(duplicate["task_id"] as? String,submitted["task_id"] as? String)
        let rpc=await restored.rpc(["jsonrpc":"2.0","id":1,"method":"tools/call","params":["name":"mika_task_status","arguments":["task_id":submitted["task_id"]!]]])
        let decoded=try MCPClient.decode(JSONSerialization.data(withJSONObject:rpc))
        XCTAssertEqual(decoded["status"] as? String,"failed");XCTAssertEqual(freshWorker.starts,0)
        await original.cancel(try XCTUnwrap(submitted["task_id"] as? String))
        try await until {original.activeID==nil}
    }
    func testUnreadableHistoryRejectsNewWorkWithoutDestroyingEvidence() async throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:dir)}
        let file=dir.appendingPathComponent("tasks.json"),corrupted=Data("incomplete private record".utf8)
        try corrupted.write(to:file)
        let worker=WaitingPhoneWorker();let store=IOSReceiverTasks(worker:worker,storage:file)
        do {_ = try await store.call("mika_run_task",["goal":"Must not execute"]);XCTFail("Unreadable history must block new execution")} catch {}
        XCTAssertEqual(try Data(contentsOf:file),corrupted);XCTAssertEqual(worker.starts,0)
    }
}
