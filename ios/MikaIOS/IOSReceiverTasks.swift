import Foundation
import Combine
import CryptoKit

@MainActor protocol IOSPhoneWorker:AnyObject {
    var available:Bool {get}
    var model:Model? {get}
    var progressHandler:((String)->Void)? {get set}
    var interactionHandler:((PhoneInteraction?) throws -> Void)? {get set}
    func respond(interactionID:String,text:String,source:PhoneInteraction.Source) throws
    func execute(goal:String,conversation:String) async throws -> String
    func cancel() async
}
struct IOSReceivedTask:Codable,Identifiable {
    var id:String
    var conversation:String
    var goal:String
    var status:String
    var progress:String
    var answer:String=""
    var reason:String=""
    var submissionID:String?
    var requestDigest:String
    var updatedAt:Date
    var cancelRequested:Bool=false
    var interaction:PhoneInteraction?
    var answeredInteractionID:String?
    var answerDigest:String?
    var terminal:Bool {["done","failed","cancelled"].contains(status)}
    var result:[String:Any] {
        ["task_id":id,"conversation":conversation,"goal":goal,"status":status,"progress":progress,"answer":answer,"reason":reason,"question":interaction?.prompt ?? "","interaction":interaction.map {$0.rpc as Any} ?? NSNull(),"updated_at":ISO8601DateFormatter().string(from:updatedAt)]
    }
}

/// Persistent MCP task lifecycle. Interrupted work is recorded, never replayed.
@MainActor final class IOSReceiverTasks:ObservableObject {
    @Published private(set) var tasks:[IOSReceivedTask]=[]
    @Published private(set) var activeID:String?
    var active:IOSReceivedTask? {tasks.first {$0.id==activeID}}
    let worker:IOSPhoneWorker
    var activeChanged:((Bool)->Void)?
    private let storage:URL
    private var execution:Task<Void,Never>?
    private var storageReadable=true
    init(worker:IOSPhoneWorker,storage:URL) {
        self.worker=worker;self.storage=storage
        if FileManager.default.fileExists(atPath:storage.path) {
            do {
                let records=try JSONDecoder().decode([IOSReceivedTask].self,from:Data(contentsOf:storage))
                tasks=records.map {record in var value=record;if !value.terminal {value.status="failed";value.interaction=nil;value.reason="设备执行会话已结束；请检查已发生的操作，不会自动重试。";value.progress="上次会话已中断";value.updatedAt=Date()};return value}
            } catch {storageReadable=false}
        }
        worker.progressHandler={ [weak self] progress in self?.progress(progress) }
        worker.interactionHandler={ [weak self] item in try self?.interaction(item) }
        if storageReadable {try? persist()}
    }
    private func persist() throws {
        try FileManager.default.createDirectory(at:storage.deletingLastPathComponent(),withIntermediateDirectories:true)
        try JSONEncoder().encode(tasks).write(to:storage,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
    }
    private func progress(_ text:String) {
        guard let id=activeID,let index=tasks.firstIndex(where:{$0.id==id}) else {return}
        tasks[index].progress=String(text.prefix(200));tasks[index].updatedAt=Date();try? persist()
    }
    private func interaction(_ item:PhoneInteraction?) throws {
        guard let id=activeID,let index=tasks.firstIndex(where:{$0.id==id}),!tasks[index].terminal else {return}
        tasks[index].interaction=item;tasks[index].status=item?.status ?? "running"
        tasks[index].progress=tasks[index].cancelRequested ? "正在停止后续操作" : item == nil ? "继续处理任务" : item?.kind == .handoff ? "等待受控手机本人操作" : "等待回答问题"
        tasks[index].updatedAt=Date();try persist()
    }
    func rpc(_ request:[String:Any]) async -> [String:Any] {
        let id=request["id"] ?? NSNull()
        do {
            let result:[String:Any]
            if request["method"] as? String=="initialize" {
                result=["protocolVersion":"2025-06-18","capabilities":["tools":[:]],"serverInfo":["name":"mika-rea-ios","version":"1"]]
            } else {
                guard request["method"] as? String=="tools/call",let params=request["params"] as? [String:Any],let name=params["name"] as? String else {throw ReceiverIssue("不支持的请求")}
                let args=params["arguments"] as? [String:Any] ?? [:]
                let value=try await call(name,args)
                let bytes=try JSONSerialization.data(withJSONObject:value)
                result=["structuredContent":value,"content":[["type":"text","text":String(decoding:bytes,as:UTF8.self)]]]
            }
            return ["jsonrpc":"2.0","id":id,"result":result]
        } catch {return ["jsonrpc":"2.0","id":id,"error":["code":-32000,"message":error.localizedDescription]]}
    }
    func call(_ name:String,_ args:[String:Any]) async throws -> [String:Any] {
        switch name {
        case "mika_run_task":return try submit(args)
        case "mika_list_tasks":
            let limit=min(50,max(1,args["limit"] as? Int ?? 10))
            return ["tasks":tasks.sorted {$0.updatedAt>$1.updatedAt}.prefix(limit).map {$0.result}]
        case "mika_task_status":return try find(args).result
        case "mika_wait_task":
            let id=try find(args).id
            let timeout=min(10,max(0,args["timeout_s"] as? Double ?? 10))
            let deadline=Date().addingTimeInterval(timeout)
            while Date()<deadline {
                let record=try find(["task_id":id]);if record.terminal || record.interaction != nil {return record.result}
                try await Task.sleep(nanoseconds:200_000_000)
            }
            return try find(["task_id":id]).result
        case "mika_cancel_task":
            let task=try find(args);if task.terminal {return ["cancelled":false,"status":task.status]}
            await cancel(task.id);return ["cancelled":true,"status":try find(args).status]
        case "mika_answer":
            let task=try find(args)
            guard let id=args["interaction_id"] as? String,let text=args["text"] as? String else {throw ReceiverIssue("回答需要对应的问题编号与内容")}
            return try respond(taskID:task.id,interactionID:id,text:text,source:.controller)
        default:throw ReceiverIssue("不支持的工具")
        }
    }
    func respond(taskID:String,interactionID:String,text:String,source:PhoneInteraction.Source) throws -> [String:Any] {
        guard let index=tasks.firstIndex(where:{$0.id==taskID}) else {throw ReceiverIssue("找不到任务")}
        let digest=SHA256.hash(data:Data(text.utf8)).map {String(format:"%02x",$0)}.joined()
        if tasks[index].answeredInteractionID==interactionID {
            guard tasks[index].answerDigest==digest else {throw ReceiverIssue("该问题已收到不同的回答")}
            return ["accepted":true,"status":tasks[index].status]
        }
        guard activeID==taskID,!tasks[index].cancelRequested,let item=tasks[index].interaction,item.id==interactionID else {throw ReceiverIssue("此问题已结束或已被新问题替代")}
        _ = try item.validate(text,source:source)
        let old=tasks[index]
        tasks[index].answeredInteractionID=interactionID;tasks[index].answerDigest=digest;tasks[index].updatedAt=Date()
        do {try persist()} catch {tasks[index]=old;throw ReceiverIssue("回答未提交：记录无法保存")}
        try worker.respond(interactionID:interactionID,text:text,source:source)
        return ["accepted":true,"status":tasks.first(where:{$0.id==taskID})?.status ?? "running"]
    }
    private func find(_ args:[String:Any]) throws -> IOSReceivedTask {
        guard let id=args["task_id"] as? String,let task=tasks.first(where:{$0.id==id}) else {throw ReceiverIssue("找不到此手机上的任务")}
        return task
    }
    private func submit(_ args:[String:Any]) throws -> [String:Any] {
        guard storageReadable else {throw ReceiverIssue("任务记录无法读取，请先在本机恢复记录，当前不会执行新任务")}
        guard let goal=args["goal"] as? String,!goal.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,goal.count<=12000 else {throw ReceiverIssue("任务内容为空或过长")}
        let bytes=try JSONSerialization.data(withJSONObject:args,options:[.sortedKeys])
        let digest=SHA256.hash(data:bytes).map {String(format:"%02x",$0)}.joined()
        let submission=args["request_id"] as? String
        if let submission {
            guard submission.range(of:"^[A-Za-z0-9_-]{1,128}$",options:.regularExpression) != nil else {throw ReceiverIssue("提交编号无效")}
            if let existing=tasks.first(where:{$0.submissionID==submission}) {
                guard existing.requestDigest==digest else {throw ReceiverIssue("提交编号已用于其他内容")}
                return ["task_id":existing.id,"conversation":existing.conversation,"status":existing.status]
            }
        }
        guard activeID==nil,worker.available else {throw ReceiverIssue("此 iPhone 当前忙碌或本机控制未就绪")}
        let conversation:String
        if let requested=args["conversation"] as? String,!requested.isEmpty {
            guard UUID(uuidString:requested) != nil,tasks.contains(where:{$0.conversation==requested}) else {throw ReceiverIssue("会话编号无效")}
            conversation=requested
        } else {conversation=UUID().uuidString}
        let record=IOSReceivedTask(id:UUID().uuidString,conversation:conversation,goal:goal,status:"running",progress:"已接收配对设备的任务",submissionID:submission,requestDigest:digest,updatedAt:Date())
        tasks.append(record)
        do {try persist()} catch {tasks.removeLast();throw ReceiverIssue("任务未启动：本机记录无法保存")}
        activeID=record.id;activeChanged?(true)
        execution=Task { [weak self] in
            guard let self else {return}
            defer {self.activeID=nil;self.execution=nil;self.activeChanged?(false)}
            do {
                guard self.tasks.first(where:{$0.id==record.id})?.cancelRequested != true else {throw CancellationError()}
                let answer=try await self.worker.execute(goal:record.goal,conversation:record.conversation)
                if self.tasks.first(where:{$0.id==record.id})?.cancelRequested==true {throw CancellationError()}
                self.finish(record.id,status:"done",answer:answer,reason:"")
            } catch {
                let cancelled=error is CancellationError || self.tasks.first(where:{$0.id==record.id})?.cancelRequested==true
                self.finish(record.id,status:cancelled ? "cancelled" : "failed",answer:"",reason:cancelled ? "已停止后续操作，进行中的单步操作请在手机上核对。" : error.localizedDescription)
            }
        }
        return ["task_id":record.id,"conversation":record.conversation,"status":record.status]
    }
    private func finish(_ id:String,status:String,answer:String,reason:String) {
        guard let index=tasks.firstIndex(where:{$0.id==id}) else {return}
        tasks[index].status=status;tasks[index].interaction=nil;tasks[index].answer=answer;tasks[index].reason=reason;tasks[index].progress=status=="done" ? "任务已完成" : "执行已结束";tasks[index].updatedAt=Date();try? persist()
    }
    func cancel(_ id:String) async {
        guard activeID==id,let index=tasks.firstIndex(where:{$0.id==id}),!tasks[index].terminal else {return}
        tasks[index].cancelRequested=true;tasks[index].progress="正在停止后续操作";try? persist()
        await worker.cancel()
    }
    struct ReceiverIssue:LocalizedError {let message:String;init(_ message:String){self.message=message};var errorDescription:String? {message}}
}
