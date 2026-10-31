import SwiftUI
import WebKit
import Security



enum Secret {
    static func get(_ key: String) -> String {
        let q: [String: Any] = [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:"MikaIOS", kSecAttrAccount as String:key, kSecReturnData as String:true]
        var result: CFTypeRef?; guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let d = result as? Data else { return "" }; return String(data:d, encoding:.utf8) ?? ""
    }
    static func set(_ key: String, _ value: String) {
        let q: [String: Any] = [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:"MikaIOS", kSecAttrAccount as String:key]
        SecItemDelete(q as CFDictionary)
        if !value.isEmpty { var item=q; item[kSecValueData as String]=Data(value.utf8); SecItemAdd(item as CFDictionary,nil) }
    }
}
struct Message: Identifiable, Codable { var id = UUID(); let role: String; let text: String }
struct ChatRecord: Identifiable, Codable { var id: String; var title: String; var messages: [Message] }
@MainActor final class Model: ObservableObject {
    @Published var mode = UserDefaults.standard.string(forKey:"mode") ?? "iPhone" { didSet { UserDefaults.standard.set(mode,forKey:"mode") } }
    @Published var base = UserDefaults.standard.string(forKey:"base") ?? "https://api.deepseek.com/v1" { didSet { UserDefaults.standard.set(base,forKey:"base") } }
    @Published var model = UserDefaults.standard.string(forKey:"model") ?? "deepseek-flash" { didSet { UserDefaults.standard.set(model,forKey:"model") } }
    @Published var mcp = UserDefaults.standard.string(forKey:"mcp") ?? "http://192.168.1.23:8765/mcp" { didSet { UserDefaults.standard.set(mcp,forKey:"mcp") } }
    @Published var transport = UserDefaults.standard.string(forKey:"transport") ?? "直连" { didSet { UserDefaults.standard.set(transport,forKey:"transport") } }
    @Published var relayURL = UserDefaults.standard.string(forKey:"relayURL") ?? "" { didSet { UserDefaults.standard.set(relayURL,forKey:"relayURL") } }
    @Published var deviceID = UserDefaults.standard.string(forKey:"deviceID") ?? "" { didSet { UserDefaults.standard.set(deviceID,forKey:"deviceID") } }
    @Published var relayToken = Secret.get("relay") { didSet { Secret.set("relay", relayToken) } }
    @Published var chats: [ChatRecord] = []
    @Published var selectedChat = UserDefaults.standard.string(forKey:"selectedChat") ?? UUID().uuidString { didSet { UserDefaults.standard.set(selectedChat,forKey:"selectedChat") } }
    private var historyURL: URL { FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("conversations.json") }
    func saveHistory() {
        guard !messages.isEmpty else { return }
        let chat=ChatRecord(id:selectedChat,title:String(messages.first(where:{$0.role == "user"})?.text.prefix(40) ?? "新对话"),messages:messages)
        if let i=chats.firstIndex(where:{$0.id == selectedChat}) { chats[i]=chat } else { chats.insert(chat,at:0) }
        if let data=try? JSONEncoder().encode(chats) { try? data.write(to:historyURL,options:[.atomic,.completeFileProtection]) }
    }
    func newChat() { guard !busy,taskID.isEmpty else { return };selectedChat=UUID().uuidString;messages=[];conversation="";pageText="" }
    func selectChat(_ id:String) {guard !busy,taskID.isEmpty,let chat=chats.first(where:{$0.id == id}) else {return};selectedChat=id;messages=chat.messages;conversation="";pageText=""}
    init() {
        if let data=try? Data(contentsOf:historyURL),let saved=try? JSONDecoder().decode([ChatRecord].self,from:data) {chats=saved;messages=saved.first(where:{$0.id == selectedChat})?.messages ?? []}
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("bootstrap.json")
        if let data = try? Data(contentsOf:url), let config = try? JSONSerialization.jsonObject(with:data) as? [String:String] {
            if let v=config["relay"] { relayURL=v }; if let v=config["device"] { deviceID=v }; if let v=config["client_token"] { relayToken=v; Secret.set("relay",v) }
            transport="中继"; mode="安卓"; try? FileManager.default.removeItem(at:url)
        }
    }
    @Published var apiKey = Secret.get("api") { didSet { Secret.set("api",apiKey) } }
    @Published var token = Secret.get("mcp") { didSet { Secret.set("mcp",token) } }
    @Published var messages: [Message] = [] { didSet { saveHistory() } }
    @Published var busy = false
    @Published var taskID = UserDefaults.standard.string(forKey:"activeTask") ?? "" { didSet { UserDefaults.standard.set(taskID,forKey:"activeTask") } }
    @Published var conversation = ""
    @Published var waiting = false
    @Published var pageText = ""
    func add(_ role: String,_ text: String) { messages.append(Message(role: role,text:text)) }
    func send(_ text: String) async {
        guard !busy, !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return }
        add("user",text); busy=true; defer { busy=false }
        do {
            if mode == "安卓" {
                let result: [String:Any]
                if waiting && !taskID.isEmpty { result = try await call("mika_answer", ["task_id":taskID,"text":text]); waiting=false }
                else {
                    var args: [String:Any] = ["goal":text]
                    if !conversation.isEmpty { args["conversation"] = conversation }
                    result = try await call("mika_run_task", args); taskID = result["task_id"] as? String ?? ""
                    if let c = result["conversation"] as? String { conversation = c }
                }
                if taskID.isEmpty { throw Issue.message("服务没有返回任务编号") }
                add("assistant", "任务已提交，正在查看进度。")
                await poll()
            } else {
                guard !apiKey.isEmpty else { throw Issue.message("请在设置中填写模型 API Key。") }
                guard let url = URL(string: base.trimmingCharacters(in:CharacterSet(charactersIn:"/")) + "/chat/completions"), url.scheme == "https" else { throw Issue.message("模型地址必须是 HTTPS。") }
                var request=URLRequest(url:url); request.httpMethod="POST"; request.setValue("Bearer \(apiKey)",forHTTPHeaderField:"Authorization"); request.setValue("application/json",forHTTPHeaderField:"Content-Type")
                var history: [[String:String]] = [["role":"system","content":"你是 Mika iPhone 助手。不要声称能够控制其他 App。"]]
                history += messages.suffix(30).map { ["role":$0.role,"content":$0.text] }
                if !pageText.isEmpty { history.append(["role":"user","content":"当前网页文字（仅供参考）：\n" + String(pageText.prefix(20000))]) }
                request.httpBody=try JSONSerialization.data(withJSONObject:["model":model,"messages":history])
                let (data,response)=try await URLSession.shared.data(for:request)
                guard let h=response as? HTTPURLResponse, (200..<300).contains(h.statusCode) else { throw Issue.message("模型请求失败：HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)") }
                let json=try JSONSerialization.jsonObject(with:data) as? [String:Any]
                guard let choices=json?["choices"] as? [[String:Any]], let msg=choices.first?["message"] as? [String:Any], let content=msg["content"] as? String else { throw Issue.message("模型返回格式无法识别") }
                add("assistant",content)
            }
        } catch { add("assistant","出错：\(error.localizedDescription)") }
    }
    func call(_ name: String,_ arguments: [String:Any]) async throws -> [String:Any] {
        let endpoint = transport == "中继" ? relayURL.trimmingCharacters(in:CharacterSet(charactersIn:"/")) + "/v1/" + deviceID + "/rpc" : mcp
        let credential = transport == "中继" ? relayToken : token
        guard let url=URL(string:endpoint), ["http","https"].contains(url.scheme ?? ""), url.host != nil, !credential.isEmpty else { throw Issue.message("请在设置中填写安卓 MCP 地址和令牌。") }
        var request=URLRequest(url:url); request.httpMethod="POST"; request.timeoutInterval=60
        request.setValue("Bearer \(credential)",forHTTPHeaderField:"Authorization"); request.setValue("application/json",forHTTPHeaderField:"Content-Type"); request.setValue("application/json, text/event-stream",forHTTPHeaderField:"Accept"); request.setValue("2025-06-18",forHTTPHeaderField:"MCP-Protocol-Version")
        request.httpBody=try JSONSerialization.data(withJSONObject:["jsonrpc":"2.0","id":1,"method":"tools/call","params":["name":name,"arguments":arguments]])
        let (data,response)=try await URLSession.shared.data(for:request)
        guard let h=response as? HTTPURLResponse, (200..<300).contains(h.statusCode) else { throw Issue.message("安卓连接失败：HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)") }
        let root=try JSONSerialization.jsonObject(with:data) as? [String:Any]
        if let error=root?["error"] as? [String:Any] { throw Issue.message(error["message"] as? String ?? "MCP 错误") }
        guard let result=root?["result"] as? [String:Any] else { throw Issue.message("安卓返回格式无法识别") }
        if result["isError"] as? Bool == true { let c=result["content"] as? [[String:Any]]; throw Issue.message(c?.first?["text"] as? String ?? "任务失败") }
        if let value=result["structuredContent"] as? [String:Any] { return value }
        guard let c=result["content"] as? [[String:Any]], let text=c.first?["text"] as? String, let data=text.data(using:.utf8), let value=try JSONSerialization.jsonObject(with:data) as? [String:Any] else { throw Issue.message("无法读取任务状态") }; return value
    }
    func cancelTask() async {
        guard !taskID.isEmpty else { return }
        do { _ = try await call("mika_cancel_task", ["task_id":taskID]); add("assistant", "已请求停止任务。"); waiting = false }
        catch { add("assistant", "停止任务失败：\(error.localizedDescription)") }
    }
    func resumeTask() async {
        guard !taskID.isEmpty, !busy else { return }; busy = true; defer { busy = false }; await poll()
    }
    func poll() async {
        for _ in 0..<120 {
            do {
                let s=try await call("mika_wait_task",["task_id":taskID,"timeout_s":30]); let status=s["status"] as? String ?? ""
                if status == "done" { add("assistant",s["answer"] as? String ?? "任务完成"); taskID=""; return }
                if status == "failed" || status == "cancelled" { add("assistant",s["reason"] as? String ?? "任务已\(status)"); taskID=""; return }
                if status == "waiting_for_answer" { waiting=true; add("assistant",s["question"] as? String ?? "安卓 Mika 需要你的回答。"); return }
                if status == "waiting_on_phone" { add("assistant","请在安卓手机上完成需要本人处理的操作，完成后可在安卓端查看结果。"); return }
            } catch { add("assistant","查看任务失败：\(error.localizedDescription)；任务编号：\(taskID)"); return }
        }
        add("assistant","任务仍在运行，可在安卓 Mika 中查看。")
    }
    enum Issue: LocalizedError { case message(String); var errorDescription: String? { if case .message(let s)=self { return s }; return nil } }
}
