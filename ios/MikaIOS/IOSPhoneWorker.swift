import Foundation
import Combine

private final class ReceiverMemoryCredentials:CredentialStore {
    private var values:[String:String]=[:]
    func get(_ key:String)->String {values[key] ?? ""}
    func set(_ key:String,_ value:String)->Bool {values[key]=value;return true}
}
@MainActor final class IOSLocalPhoneWorker:IOSPhoneWorker {
    weak var owner:Model?
    private(set) var model:Model?
    var progressHandler:((String)->Void)?
    var interactionHandler:((PhoneInteraction?) throws -> Void)?
    private var observer:AnyCancellable?
    private var stopping=false
    var available:Bool {
        guard let owner else {return false}
        return OnDeviceControl.shared.ready && !owner.busy && owner.remoteTask==nil && !owner.apiKey.isEmpty
    }
    func execute(goal:String,conversation:String) async throws -> String {
        guard let owner,OnDeviceControl.shared.ready else {throw IOSReceiverTasks.ReceiverIssue("本机执行器未就绪")}
        stopping=false
        let directory=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("RemoteAssistance/Threads/"+conversation)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let defaults=UserDefaults(suiteName:"com.huapohen.mikaremote.receiver."+conversation)!
        let execution=AgentExecutionPreferences.load(owner.defaults)
        defaults.set(execution.mode.rawValue,forKey:"localExecutionMode")
        defaults.set(execution.returnAfterTask,forKey:"localReturnAfterTask")
        let engine=Model(storage:directory,defaults:defaults,vault:ReceiverMemoryCredentials(),providerSession:owner.providerSession)
        engine.mode="iPhone";engine.base=owner.base;engine.model=owner.model;engine.apiKey=owner.apiKey
        engine.thinkingEnabled=owner.thinkingEnabled;engine.reasoningEffort=owner.reasoningEffort
        model=engine
        engine.interactionChanged={ [weak self] item in try self?.interactionHandler?(item) }
        observer=engine.objectWillChange.sink { [weak self,weak engine] in Task { @MainActor in
            guard let self,let engine,self.model === engine else {return}
            self.progressHandler?(engine.localProgress)
        }}
        defer {
            #if DEBUG
            let value:[String:Any]=["outcome":engine.lastOutcome,"tools":engine.localToolTrace,"targets":engine.localToolTargets,"timestamp":ISO8601DateFormatter().string(from:Date())]
            let file=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("IOSReceiverExecution.json")
            if let data=try? JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]) {try? data.write(to:file,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])}
            #endif
            observer=nil;model=nil
        }
        await engine.send(goal)
        if engine.lastOutcome=="cancelled" || stopping {throw CancellationError()}
        guard engine.lastOutcome=="done" else {throw IOSReceiverTasks.ReceiverIssue("本机任务未完成，请在受控手机上检查")}
        let answer=engine.messages.last(where:{$0.role=="assistant"})?.text ?? ""
        return owner.apiKey.isEmpty ? answer : answer.replacingOccurrences(of:owner.apiKey,with:"***")
    }
    func cancel() async {stopping=true;if let model {await model.stopWork(expectedID:model.capsuleOperationID)}}
    func respond(interactionID:String,text:String,source:PhoneInteraction.Source) throws {
        guard let model else {throw IOSReceiverTasks.ReceiverIssue("本机任务已结束")}
        try model.interactionGate.respond(id:interactionID,text:text,source:source)
        model.add("user",text)
    }
}
