import SwiftUI
import Combine
import UniformTypeIdentifiers

private final class ReceiverNoRedirects:NSObject,URLSessionTaskDelegate {
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void) {completionHandler(nil)}
}
@MainActor final class RemoteIOSReceiver:ObservableObject {
    static let shared=RemoteIOSReceiver()
    @Published var relay=UserDefaults.standard.string(forKey:"receiverRelay") ?? "https://qinziduihua.com/mika-rea" {didSet {UserDefaults.standard.set(relay,forKey:"receiverRelay")}}
    @Published var device=UserDefaults.standard.string(forKey:"receiverDevice") ?? "" {didSet {UserDefaults.standard.set(device,forKey:"receiverDevice")}}
    @Published var token=Secret.get("ios-receiver-agent") {didSet {Secret.set("ios-receiver-agent",token)}}
    @Published private(set) var enabled=false
    @Published private(set) var status="远程协助已关闭" {didSet {saveDiagnostics()}}
    private let worker=IOSLocalPhoneWorker()
    let tasks:IOSReceiverTasks
    private var poller:Task<Void,Never>?
    private var foreground=true
    private weak var owner:Model?
    private var subscription:AnyCancellable?
    private let session:URLSession
    var executionModel:Model? {worker.model}
    var activeTask:IOSReceivedTask? {tasks.active}
    init() {
        let configuration=URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest=25;configuration.timeoutIntervalForResource=30;configuration.httpCookieStorage=nil
        session=URLSession(configuration:configuration,delegate:ReceiverNoRedirects(),delegateQueue:nil)
        let file=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("RemoteAssistance/tasks.json")
        tasks=IOSReceiverTasks(worker:worker,storage:file)
        subscription=tasks.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        tasks.activeChanged={ [weak self] active in
            guard let self else {return}
            self.owner?.receivingRemoteWork=active
            UIApplication.shared.isIdleTimerDisabled=(self.enabled && self.foreground) || active
            if !active && !self.foreground {self.pausePolling()}
            self.saveDiagnostics()
        }
        let bootstrap=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("IOSReceiverBootstrap.json")
        if let data=try? Data(contentsOf:bootstrap) {do {try importConfiguration(data);try FileManager.default.removeItem(at:bootstrap)} catch {status="受控连接配置导入失败"}}
        saveDiagnostics()
    }
    func bind(_ model:Model) {owner=model;worker.owner=model;model.receivingRemoteWork=activeTask != nil}
    private func saveDiagnostics() {
        let value:[String:Any]=["enabled":enabled,"status":status,"active":activeTask != nil,"record_count":tasks.tasks.count,"timestamp":ISO8601DateFormatter().string(from:Date())]
        let file=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("IOSReceiverDiagnostics.json")
        if let data=try? JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]) {try? data.write(to:file,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])}
    }
    func importConfiguration(_ data:Data) throws {
        guard !enabled,data.count<=8192,let value=try JSONSerialization.jsonObject(with:data) as? [String:String],value["role"]=="agent",let base=value["relay"],let device=value["device"],let token=value["agent_token"] else {throw IOSReceiverTasks.ReceiverIssue("请选择受控端配置文件，并先关闭连接")}
        _ = try endpoint(base:base,device:device,action:"next")
        guard token.count>=32,!token.contains("\r"),!token.contains("\n"),Secret.set("ios-receiver-agent",token) else {throw IOSReceiverTasks.ReceiverIssue("受控端令牌无效或无法保存")}
        self.relay=base;self.device=device;self.token=token
    }
    func start() throws {
        guard !enabled else {return}
        guard let owner,worker.available,!owner.receivingRemoteWork else {throw IOSReceiverTasks.ReceiverIssue("请先解锁手机、开启本机控制并配置模型，且不要同时运行其他任务")}
        _ = try endpoint(base:relay,device:device,action:"next")
        guard token.count>=32,!token.contains("\n"),!token.contains("\r") else {throw IOSReceiverTasks.ReceiverIssue("请导入受控端配对配置")}
        enabled=true;status="正在连接公网中继";UIApplication.shared.isIdleTimerDisabled=true;resumePolling()
    }
    func stop() async {
        enabled=false;pausePolling();status="远程协助已关闭"
        if let task=activeTask {await tasks.cancel(task.id)}
        UIApplication.shared.isIdleTimerDisabled=activeTask != nil
    }
    func setForeground(_ foreground:Bool) {
        self.foreground=foreground
        if enabled {
            if foreground {resumePolling()}
            else if activeTask==nil {pausePolling();status="请回到 Mika 前台以接收任务"}
        }
        UIApplication.shared.isIdleTimerDisabled=(enabled && foreground) || activeTask != nil
    }
    private func pausePolling() {poller?.cancel();poller=nil}
    private func resumePolling() {
        guard enabled,poller==nil,foreground || activeTask != nil else {return}
        // Freeze endpoint and role credential for this explicit connection session.
        let base=relay,device=device,credential=token
        poller=Task { [weak self] in
            var failures=0
            while !Task.isCancelled {
                guard let self,self.enabled else {return}
                do {
                    let command=try await self.post(self.endpoint(base:base,device:device,action:"next"),token:credential,body:[:])
                    try Task.checkCancellation()
                    self.status="已连接 · 仅接受配对设备的任务"
                    if let id=command["id"] as? String,let rpc=command["rpc"] as? [String:Any] {
                        let response=await self.tasks.rpc(rpc)
                        // A failed result upload can be retried; the command itself is never replayed.
                        var delivered=false
                        for _ in 0..<3 {
                            do {
                                let result=try await self.post(self.endpoint(base:base,device:device,action:"result"),token:credential,body:["id":id,"response":response])
                                delivered=result["accepted"] as? Bool==true;break
                            } catch {try Task.checkCancellation();try await Task.sleep(nanoseconds:500_000_000)}
                        }
                        if !delivered {self.status="回传未获确认；任务记录已保留，不会重放"}
                    }
                    failures=0
                } catch {
                    if Task.isCancelled {return}
                    self.status="中继连接中断，正在重连";failures=min(failures+1,5)
                    do {try await Task.sleep(nanoseconds:UInt64(min(30,1<<failures))*1_000_000_000)} catch {return}
                }
            }
        }
    }
    private func endpoint(base:String,device:String,action:String) throws -> URL {
        guard device.range(of:"^[A-Za-z0-9_-]{1,64}$",options:.regularExpression) != nil,
              let root=URL(string:base.trimmingCharacters(in:CharacterSet(charactersIn:"/"))),root.scheme=="https",root.host != nil,root.user==nil,root.password==nil,root.query==nil,root.fragment==nil,
              let url=URL(string:root.absoluteString+"/v1/"+device+"/"+action) else {throw IOSReceiverTasks.ReceiverIssue("公网受控连接需要有效的 HTTPS 中继与设备 ID")}
        return url
    }
    private func post(_ url:URL,token:String,body:[String:Any]) async throws -> [String:Any] {
        var request=URLRequest(url:url);request.httpMethod="POST";request.setValue("Bearer "+token,forHTTPHeaderField:"Authorization");request.setValue("application/json",forHTTPHeaderField:"Content-Type");request.httpBody=try JSONSerialization.data(withJSONObject:body)
        let (data,response)=try await session.data(for:request)
        guard (response as? HTTPURLResponse)?.statusCode==200,data.count<=2_097_152,let result=try JSONSerialization.jsonObject(with:data) as? [String:Any] else {throw IOSReceiverTasks.ReceiverIssue("中继请求未成功")}
        return result
    }
}

struct IOSReceiverSettings:View {
    @ObservedObject private var receiver=RemoteIOSReceiver.shared
    @State private var importing=false
    @State private var error=""
    var body:some View {
        Form {
            Section {
                Text("允许已配对的另一台设备在这台 iPhone 上交代任务。由此手机的模型与本机执行器处理，执行内容会显示在这里，可随时停止。")
                Text("接收任务时保持 Mika 在前台并解锁；执行期间会短暂切换目标 App。锁屏或长期后台不能保证继续执行。").font(.footnote).foregroundStyle(.secondary)
                Text(receiver.status).accessibilityIdentifier("iosReceiverStatus")
            }
            Section("受控端配对") {
                TextField("HTTPS 中继地址",text:$receiver.relay).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("本机设备 ID",text:$receiver.device).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("受控端连接令牌",text:$receiver.token).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("导入受控端配置文件") {importing=true}
            }.disabled(receiver.enabled)
            Section {
                Button(receiver.enabled ? "连接已开启" : "开启本机远程协助") {do {try receiver.start();error=""} catch {self.error=error.localizedDescription}}.disabled(receiver.enabled).accessibilityIdentifier("startIOSReceiver")
                Button("关闭连接并停止后续操作",role:.destructive) {Task {await receiver.stop()}}.disabled(!receiver.enabled && receiver.activeTask==nil)
            }
            if let task=receiver.activeTask {
                Section("正在执行配对设备的任务") {Text(task.goal);Text(task.progress).font(.footnote);Button("停止这项任务",role:.destructive) {Task {await receiver.tasks.cancel(task.id)}}}
            }
            Section("本机接收记录") {
                ForEach(receiver.tasks.tasks.sorted {$0.updatedAt>$1.updatedAt}.prefix(20)) {task in
                    VStack(alignment:.leading,spacing:6) {Text(task.goal);Text(task.status+" · "+task.progress).font(.caption).foregroundStyle(.secondary);if !task.answer.isEmpty {Text(task.answer).font(.footnote).textSelection(.enabled)};if !task.reason.isEmpty {Text(task.reason).font(.footnote)}}
                }
            }
            if !error.isEmpty {Section {Text(error).foregroundStyle(.red)}}
        }.navigationTitle("接收远程协助").navigationBarTitleDisplayMode(.inline)
            .fileImporter(isPresented:$importing,allowedContentTypes:[.data,.json]) {result in
                do {let url=try result.get();let access=url.startAccessingSecurityScopedResource();defer {if access {url.stopAccessingSecurityScopedResource()}};try receiver.importConfiguration(Data(contentsOf:url));error=""} catch {self.error=error.localizedDescription}
            }
    }
}
