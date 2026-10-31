import XCTest
@testable import MikaIOS

private final class MemoryVault:CredentialStore {
    var values:[String:String]=[:]
    func get(_ key:String)->String {values[key] ?? ""}
    func set(_ key:String,_ value:String)->Bool {values[key]=value;return true}
}
private final class StubProtocol:URLProtocol {
    static func body(_ request:URLRequest)throws->Data {
        if let data=request.httpBody {return data}
        guard let stream=request.httpBodyStream else {throw URLError(.cannotDecodeRawData)}
        stream.open();defer {stream.close()}
        var result=Data();var bytes=[UInt8](repeating:0,count:4096)
        while stream.hasBytesAvailable {
            let count=stream.read(&bytes,maxLength:bytes.count)
            if count<0 {throw URLError(.cannotDecodeRawData)}
            if count==0 {break}
            result.append(contentsOf:bytes.prefix(count))
        }
        return result
    }
    static var backend:((URLRequest)throws->[String:Any])!
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading() {
        do {
            let value=try Self.backend(request)
            let response=HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!
            client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
            client?.urlProtocol(self,didLoad:try JSONSerialization.data(withJSONObject:["jsonrpc":"2.0","result":["structuredContent":value]]))
            client?.urlProtocolDidFinishLoading(self)
        } catch {client?.urlProtocol(self,didFailWithError:error)}
    }
    override func stopLoading() {}
}
private final class BlockingProviderProtocol:URLProtocol {
    static var started:(()->Void)?
    static var stopped:(()->Void)?
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading() {Self.started?()}
    override func stopLoading() {Self.stopped?()}
}
@MainActor final class TaskRecoveryTests:XCTestCase {
    private func client()->MCPClient {
        let configuration=URLSessionConfiguration.ephemeral;configuration.protocolClasses=[StubProtocol.self]
        return MCPClient(session:URLSession(configuration:configuration))
    }
    func testRestartUsesOriginalDeviceAndCredentialWithoutResubmitting() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:directory)}
        let suite=UUID().uuidString;let defaults=UserDefaults(suiteName:suite)!
        defer {defaults.removePersistentDomain(forName:suite)}
        let vault=MemoryVault();let transport=client()
        let lock=NSLock();var calls:[String]=[];var finished=false
        StubProtocol.backend={request in
            XCTAssertEqual(request.url?.host,"original.example.test")
            XCTAssertEqual(request.value(forHTTPHeaderField:"Authorization"),"Bearer original-test-token")
            let root=try JSONSerialization.jsonObject(with:StubProtocol.body(request)) as! [String:Any]
            let params=root["params"] as! [String:Any];let name=params["name"] as! String
            let complete=lock.withLock {calls.append(name);return finished}
            if name=="mika_run_task" {return ["task_id":"task-one","conversation":"conversation-one"]}
            return complete ? ["task_id":"task-one","status":"done","answer":"Recovered answer"] : ["task_id":"task-one","status":"waiting_on_phone"]
        }
        let first=Model(client:transport,storage:directory,defaults:defaults,vault:vault)
        first.mode="安卓";first.transport="中继";first.relayURL="https://original.example.test/mika-rea";first.deviceID="one";first.relayToken="original-test-token"
        await first.send("Read the version")
        XCTAssertEqual(first.remoteTask?.id,"task-one")
        let owner=first.selectedChat
        first.relayURL="https://different.example.test/mika-rea";first.relayToken="different-test-token"
        let restored=Model(client:transport,storage:directory,defaults:defaults,vault:vault)
        XCTAssertEqual(restored.selectedChat,owner)
        XCTAssertEqual(restored.remoteTask?.id,"task-one")
        lock.withLock {finished=true}
        await restored.resumeTask()
        XCTAssertNil(restored.remoteTask)
        XCTAssertTrue(restored.messages.contains {$0.text=="Recovered answer"})
        XCTAssertFalse(FileManager.default.fileExists(atPath:directory.appendingPathComponent("active-task.json").path))
        XCTAssertEqual(vault.get("active-task-credential"),"")
        XCTAssertEqual(calls.filter {$0=="mika_run_task"}.count,1)
    }
    func testUnknownSubmissionOutcomeWarnsAndDoesNotRetry() async throws {
        var count=0
        StubProtocol.backend={_ in count+=1;throw URLError(.timedOut)}
        let connection=try RemoteConnection(endpoint:URL(string:"https://example.test/rpc")!,label:"test")
        do {_ = try await client().call("mika_run_task",arguments:["goal":"test"],connection:connection,credential:"dummy-test-token");XCTFail("expected uncertain outcome")}
        catch {XCTAssertTrue(error.localizedDescription.contains("避免重复提交"))}
        XCTAssertEqual(count,1)
        XCTAssertThrowsError(try RemoteConnection(endpoint:URL(string:"http://203.0.113.1/rpc")!,label:"public HTTP"))
    }
    func testStaleCapsuleStopCannotCancelAnotherTask() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:directory)}
        let suite=UUID().uuidString;let defaults=UserDefaults(suiteName:suite)!
        defer {defaults.removePersistentDomain(forName:suite)}
        let vault=MemoryVault();vault.values["active-task-credential"]="task-test-token"
        var cancellations=0
        StubProtocol.backend={request in
            let root=try JSONSerialization.jsonObject(with:StubProtocol.body(request)) as! [String:Any]
            let name=(root["params"] as! [String:Any])["name"] as! String
            if name=="mika_cancel_task" {cancellations+=1;return ["cancelled":true]}
            return ["status":"cancelled"]
        }
        let model=Model(client:client(),storage:directory,defaults:defaults,vault:vault)
        let connection=try RemoteConnection(endpoint:URL(string:"https://example.test/rpc")!,label:"test")
        model.remoteTask=RemoteTaskRecord(id:"current-task",chatID:model.selectedChat,goal:"test",connection:connection,conversation:"",status:"running",progress:"",question:"",updatedAt:Date())
        await model.stopWork(expectedID:"old-task")
        XCTAssertEqual(cancellations,0);XCTAssertEqual(model.remoteTask?.id,"current-task")
        await model.stopWork(expectedID:"current-task")
        XCTAssertEqual(cancellations,1);XCTAssertNil(model.remoteTask)
    }

    func testLocalStopCancelsInFlightProviderRequest() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:directory)}
        let suite=UUID().uuidString;let defaults=UserDefaults(suiteName:suite)!
        defer {defaults.removePersistentDomain(forName:suite)}
        let started=expectation(description:"provider request started")
        let stopped=expectation(description:"provider request cancelled")
        let completed=expectation(description:"model returned from cancellation")
        BlockingProviderProtocol.started={started.fulfill()};BlockingProviderProtocol.stopped={stopped.fulfill()}
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[BlockingProviderProtocol.self]
        let model=Model(storage:directory,defaults:defaults,vault:MemoryVault(),providerSession:URLSession(configuration:config))
        model.apiKey="dummy-model-test-token";model.base="https://model.example.test/v1"
        let request=Task {await model.send("Cancellation test");completed.fulfill()}
        defer {request.cancel()}
        await fulfillment(of:[started],timeout:5)
        XCTAssertTrue(model.busy)
        await model.stopWork(expectedID:model.capsuleOperationID)
        await fulfillment(of:[stopped,completed],timeout:5)
        XCTAssertFalse(model.busy);XCTAssertEqual(model.lastOutcome,"cancelled")
    }

}
