import Foundation
import Combine

struct PhoneInteraction:Codable,Equatable,Identifiable {
    enum Kind:String,Codable {case question,confirmation,handoff}
    enum Source {case owner,controller}
    let id:String
    let kind:Kind
    let prompt:String
    let options:[String]
    let bundleID:String?
    let expiresAt:Date
    enum CodingKeys:String,CodingKey {case id,kind,prompt,options;case bundleID="bundle_id",expiresAt="expires_at"}
    var status:String {kind == .handoff ? "waiting_on_phone" : "waiting_for_answer"}
    var rpc:[String:Any] {
        var value:[String:Any]=["id":id,"kind":kind.rawValue,"prompt":prompt,"options":options,"expires_at":ISO8601DateFormatter().string(from:expiresAt)]
        if let bundleID {value["bundle_id"]=bundleID};return value
    }
    static func fromRPC(_ value:Any?)->Self? {
        guard let value,JSONSerialization.isValidJSONObject(value),let data=try? JSONSerialization.data(withJSONObject:value) else {return nil}
        let decoder=JSONDecoder();decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Self.self,from:data)
    }
    func validate(_ text:String,source:Source) throws -> [String:Any] {
        guard Date()<expiresAt else {throw InteractionError("问题已过期，不会视为已同意或已完成")}
        switch kind {
        case .question:
            guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,text.count<=12000 else {throw InteractionError("请提供 12000 字以内的非空回答")}
            return ["answer":text]
        case .confirmation:
            guard ["approve","decline"].contains(text) else {throw InteractionError("请明确选择同意或不同意")}
            return ["approved":text=="approve"]
        case .handoff:
            guard source == .owner else {throw InteractionError("此步骤只能由受控手机本人在本机确认")}
            guard ["complete","skip"].contains(text) else {throw InteractionError("请选择处理完成或跳过")}
            return ["outcome":text=="complete" ? "complete" : "skipped","verified":false,"note":"用户交还控制不代表成功，必须重新读屏核实。"]
        }
    }
    struct InteractionError:LocalizedError {let message:String;init(_ message:String){self.message=message};var errorDescription:String? {message}}
}

/// Suspends the exact tool call. No phone action runs while an answer is pending.
@MainActor final class PhoneInteractionGate {
    private(set) var pending:PhoneInteraction?
    var onChange:((PhoneInteraction?) throws -> Void)?
    private var continuation:CheckedContinuation<[String:Any],Error>?
    private var timeout:Task<Void,Never>?
    func ask(kind:PhoneInteraction.Kind,prompt:String,options:[String]=[],bundleID:String?=nil,timeoutSeconds:TimeInterval=900) async throws -> [String:Any] {
        try Task.checkCancellation()
        guard pending==nil,!prompt.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,prompt.count<=2000,options.count<=8,options.allSatisfy({!$0.isEmpty && $0.count<=120}),timeoutSeconds>0,timeoutSeconds<=900 else {throw PhoneInteraction.InteractionError("问题内容无效或已有问题正在等待")}
        let item=PhoneInteraction(id:UUID().uuidString,kind:kind,prompt:prompt,options:options,bundleID:bundleID,expiresAt:Date().addingTimeInterval(timeoutSeconds))
        return try await withTaskCancellationHandler(operation:{
            try await withCheckedThrowingContinuation {resume in
                if Task.isCancelled {resume.resume(throwing:CancellationError());return}
                pending=item;continuation=resume
                do {try onChange?(item)} catch {try? finish(item.id,result:.failure(error));return}
                timeout=Task { [weak self] in
                    do {try await Task.sleep(nanoseconds:UInt64(timeoutSeconds*1_000_000_000))} catch {return}
                    try? self?.finish(item.id,result:.failure(PhoneInteraction.InteractionError("等待回答已超时；没有自动同意、提交或认定本人操作完成")))
                }
            }
        },onCancel:{Task { @MainActor [weak self] in self?.cancel(item.id) }})
    }
    func respond(id:String,text:String,source:PhoneInteraction.Source) throws {
        guard let pending,pending.id==id else {throw PhoneInteraction.InteractionError("此问题已结束或已被新问题替代")}
        let result=try pending.validate(text,source:source)
        try finish(id,result:.success(result))
    }
    func cancel(_ id:String) {try? finish(id,result:.failure(CancellationError()))}
    private func finish(_ id:String,result:Result<[String:Any],Error>) throws {
        guard pending?.id==id,let resume=continuation else {return}
        pending=nil;continuation=nil;timeout?.cancel();timeout=nil
        do {try onChange?(nil);resume.resume(with:result)}
        catch {resume.resume(throwing:error);throw error}
    }
}
