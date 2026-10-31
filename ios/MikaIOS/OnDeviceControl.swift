import SwiftUI
import UIKit
import UniformTypeIdentifiers

#if !targetEnvironment(simulator)
@_silgen_name("mika_local_start") private func nativeStart(_ pairing:UnsafePointer<CChar>,_ host:UnsafePointer<CChar>,_ runner:UnsafePointer<CChar>,_ token:UnsafePointer<CChar>)->Int32
@_silgen_name("mika_local_stop") private func nativeStop()
@_silgen_name("mika_local_status") private func nativeStatus()->UnsafeMutablePointer<CChar>?
@_silgen_name("mika_local_string_free") private func nativeStringFree(_ value:UnsafeMutablePointer<CChar>)
#endif

@MainActor final class OnDeviceControl: ObservableObject {
    static let shared=OnDeviceControl()
    @Published private(set) var ready=false {didSet {saveDiagnostics()}}
    @Published private(set) var phase="未启动" {didSet {saveDiagnostics()}}
    @Published private(set) var detail="开启本机控制后，Mika 才能读屏和操作其他 App。" {didSet {saveDiagnostics()}}
    @Published private(set) var hasPairing=false
    @Published private(set) var starting=false
    @Published private(set) var sessionIdentifier=""
    @Published private(set) var requested=false
    @Published var host=UserDefaults.standard.string(forKey:"localDeviceHost") ?? "10.7.0.1" {didSet {UserDefaults.standard.set(host,forKey:"localDeviceHost")}}
    private var monitor:Task<Void,Never>?
    private var health:Task<Void,Never>?
    private let runner="com.huapohen.mikaremote.local-runner.xctrunner"
    private var credential=""
    private var startupBackground:UIBackgroundTaskIdentifier = .invalid
    private var developerProbeStarted=false
    private let diagnosticLaunchID:String = {
        let args=ProcessInfo.processInfo.arguments
        guard let index=args.firstIndex(of:"--mika-control-run-id"),index+1<args.count else {return ""}
        return String(args[index+1].prefix(64))
    }()
    @Published private(set) var apps:[[String:String]]=[]
    private var directory:URL {FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("LocalControl",isDirectory:true)}
    private var pairURL:URL {directory.appendingPathComponent("pairing.plist")}
    private let session:URLSession = {
        let configuration=URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest=15
        configuration.timeoutIntervalForResource=20
        configuration.httpCookieStorage=nil
        return URLSession(configuration:configuration)
    }()
    init() {
        hasPairing=FileManager.default.fileExists(atPath:pairURL.path)
        let appSource=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("LocalAppCatalog.json")
        let appStore=directory.appendingPathComponent("apps.json")
        if let data=try? Data(contentsOf:appSource),let list=try? JSONDecoder().decode([[String:String]].self,from:data) {
            try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            if (try? data.write(to:appStore,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])) != nil {apps=list;try? FileManager.default.removeItem(at:appSource)}
        } else if let data=try? Data(contentsOf:appStore),let list=try? JSONDecoder().decode([[String:String]].self,from:data) {apps=list}
        credential=Secret.get("local-control-session")
        let bootstrap=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("LocalControlPairing.mobiledevicepairing")
        if let data=try? Data(contentsOf:bootstrap) {
            do {try importPairing(data);try FileManager.default.removeItem(at:bootstrap)}
            catch {detail="设备配对记录导入失败。"}
        }
        requested=PhoneControlResumePolicy.requested(saved:UserDefaults.standard.object(forKey:"localControlWanted") as? Bool,hasPairing:hasPairing,hasPreviousSession:!credential.isEmpty)
        UserDefaults.standard.set(requested,forKey:"localControlWanted")
        saveDiagnostics()
    }
    // Local acceptance evidence contains no pairing material, tokens, UI text or app catalog.
    private func saveDiagnostics() {
        let result:[String:Any]=["ready":ready,"requested":requested,"phase":phase,"detail":detail,"has_pairing":hasPairing,"launch_id":diagnosticLaunchID,"timestamp":ISO8601DateFormatter().string(from:Date())]
        let url=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("LocalControlDiagnostics.json")
        if let data=try? JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]) {try? data.write(to:url,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])}
    }
    /// Explicit development launch only; Mac does not own or maintain an XCTest session.
    func runDeveloperProbeIfRequested() async {
        #if DEBUG
        let arguments=ProcessInfo.processInfo.arguments
        let probe=arguments.contains("--mika-local-control-probe")
        guard !developerProbeStarted,probe || arguments.contains("--mika-local-control-start") else {return}
        developerProbeStarted=true
        start()
        for _ in 0..<150 {
            if ready {if probe {await smokeTest()};return}
            if !starting {return}
            try? await Task.sleep(nanoseconds:1_000_000_000)
        }
        #endif
    }
    func importPairing(_ data:Data) throws {
        guard data.count<262144,let plist=try PropertyListSerialization.propertyList(from:data,format:nil) as? [String:Any],
              plist["HostPrivateKey"] != nil,plist["HostCertificate"] != nil,plist["DeviceCertificate"] != nil,
              plist["HostID"] != nil,plist["SystemBUID"] != nil else {throw Model.Issue.message("请选择有效的设备配对文件")}
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try data.write(to:pairURL,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
        hasPairing=true
        detail="设备配对记录已保存在本机，未上传到服务器。"
    }
    func start() {
        requested=true;UserDefaults.standard.set(true,forKey:"localControlWanted")
        guard !starting,!ready else {return}
        if MikaTunnelManager.shared.embedded {
            starting=true;phase="连接本地隧道";detail="首次使用需在系统提示中允许 Mika 添加 VPN 配置。"
            Task {
                do {try await MikaTunnelManager.shared.enable();starting=false;launchNative()}
                catch {starting=false;phase="隧道未连接";detail=error.localizedDescription}
            }
        } else {launchNative()}
    }
    private func launchNative() {
        guard !starting,!ready else {return}
        guard hasPairing else {phase="需要配对";detail="请先导入此 iPhone 的配对记录。";return}
        #if targetEnvironment(simulator)
        phase="需要真机";detail="本机开发服务需要在实际 iPhone 上验证。"
        #else
        credential=UUID().uuidString+UUID().uuidString
        sessionIdentifier=UUID().uuidString
        guard Secret.set("local-control-session",credential) else {detail="无法保存会话令牌，请先解锁设备。";return}
        let result=pairURL.path.withCString {pair in host.withCString {address in runner.withCString {identifier in credential.withCString {token in nativeStart(pair,address,identifier,token)}}}}
        guard result>=0 else {phase="配置无效";detail="请检查本机开发地址。";return}
        startupBackground=UIApplication.shared.beginBackgroundTask(withName:"Mika 本机执行器启动") { [weak self] in
            self?.detail="启动耗时过长，请返回 Mika 后重试。"
        }
        starting=true;phase="启动中";detail="请确保 LocalDevVPN 已开启，手机已解锁。"
        monitor?.cancel()
        monitor=Task { [weak self] in
            guard let self else {return}
            defer {if self.startupBackground != .invalid {UIApplication.shared.endBackgroundTask(self.startupBackground);self.startupBackground = .invalid}}
            let deadline=Date().addingTimeInterval(120)
            while Date()<deadline {
                if Task.isCancelled {return}
                if let pointer=nativeStatus() {
                    let data=Data(String(cString:pointer).utf8);nativeStringFree(pointer)
                    if let value=try? JSONSerialization.jsonObject(with:data) as? [String:String] {
                        self.detail=value["detail"] ?? self.detail
                        if value["status"]=="failed" {self.phase="启动失败";self.starting=false;return}
                        if value["status"]=="stopped" {self.phase="已停止";self.starting=false;self.ready=false;return}
                    }
                }
                if let result=try? await self.request(path:"/status",body:nil),result["ready"] as? Bool==true {
                    self.ready=true;self.starting=false;self.phase="已就绪";self.detail="本机读屏、点按、输入和滑动接口已连接。";self.watchSession();return
                }
                try? await Task.sleep(nanoseconds:1_000_000_000)
            }
            self.starting=false;self.phase="连接超时";self.detail="本机执行器尚未就绪，请检查 VPN、设备锁定状态及执行器签名。"
            nativeStop()
        }
        #endif
    }
    func stop() async {
        requested=false;UserDefaults.standard.set(false,forKey:"localControlWanted")
        monitor?.cancel();monitor=nil
        health?.cancel();health=nil
        _ = try? await request(path:"/control",body:["action":"stop"])
        #if !targetEnvironment(simulator)
        nativeStop()
        #endif
        MikaTunnelManager.shared.stop()
        ready=false;starting=false;phase="已停止";detail="本机自动化会话已停止。"
        sessionIdentifier=""
        credential="";Secret.set("local-control-session","")
    }
    private func watchSession() {
        health?.cancel()
        health=Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds:3_000_000_000)
                guard !Task.isCancelled,let self else {return}
                #if !targetEnvironment(simulator)
                if let pointer=nativeStatus() {
                    let data=Data(String(cString:pointer).utf8);nativeStringFree(pointer)
                    if let value=try? JSONSerialization.jsonObject(with:data) as? [String:String],let state=value["status"],["failed","stopped"].contains(state) {
                        self.ready=false;self.phase="会话已结束";self.detail=value["detail"] ?? "请重新启动本机控制。";return
                    }
                }
                #endif
            }
        }
    }
    func execute(_ body:[String:Any],returnToMika:Bool=true) async throws -> [String:Any] {
        guard ready else {throw Model.Issue.message("请先在设置 → 本机控制中启动执行器。")}
        var command=body
        command["return_to_mika"]=returnToMika
        // Callers choose foreground behavior. The agent holds a finite, monitored
        // background assertion across model calls instead of returning after each step.
        let background=UIApplication.shared.beginBackgroundTask(withName:"Mika 本机操作")
        defer {if background != .invalid {UIApplication.shared.endBackgroundTask(background)}}
        do {return try await request(path:"/control",body:command)}
        catch {detail="操作未获确认，不会自动重复执行。请检查执行器状态。";throw error}
    }
    private func nativeSessionEnded()->Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        guard let pointer=nativeStatus() else {return true}
        let data=Data(String(cString:pointer).utf8);nativeStringFree(pointer)
        guard let value=try? JSONSerialization.jsonObject(with:data) as? [String:String],let status=value["status"] else {return true}
        return ["failed","stopped"].contains(status)
        #endif
    }
    func verifySessionAndReconnectIfNeeded() async throws {
        guard requested else {throw Model.Issue.message("本机控制已由你停止，不能自动继续任务。")}
        if ready,!nativeSessionEnded(),let result=try? await request(path:"/status",body:nil),ready,!nativeSessionEnded(),result["ready"] as? Bool==true {return}
        guard requested else {throw Model.Issue.message("本机控制已由你停止，不能自动继续任务。")}
        // Pausing happened between operations. Reconnect the idle session; never
        // repeat a previous UI command or change the user's explicit stop choice.
        monitor?.cancel();health?.cancel()
        #if !targetEnvironment(simulator)
        nativeStop()
        #endif
        ready=false;starting=false
        try await ensureReadyIfRequested()
    }
    private func request(path:String,body:[String:Any]?) async throws -> [String:Any] {
        guard !credential.isEmpty else {throw Model.Issue.message("没有本机会话。")}
        var request=URLRequest(url:URL(string:"http://127.0.0.1:8123"+path)!)
        request.setValue("Bearer "+credential,forHTTPHeaderField:"Authorization")
        if let body {request.httpMethod="POST";request.httpBody=try JSONSerialization.data(withJSONObject:body);request.setValue("application/json",forHTTPHeaderField:"Content-Type")}
        let (data,response)=try await session.data(for:request)
        guard let http=response as? HTTPURLResponse,http.statusCode==200 else {throw Model.Issue.message("本机执行器请求失败，请检查会话是否仍在运行。")}
        guard let object=try JSONSerialization.jsonObject(with:data) as? [String:Any] else {throw Model.Issue.message("本机执行器返回格式无效。")}
        return object
    }
    func smokeTest() async {
        var checks:[String:Bool]=[:]
        do {
            _ = try await execute(["action":"launch","bundle_id":"com.apple.Preferences"])
            checks["launch_settings"]=true
            func screen() async throws -> [[String:Any]] {
                let result=try await execute(["action":"source","bundle_id":"com.apple.Preferences"])
                return result["elements"] as? [[String:Any]] ?? []
            }
            let initial=try await screen()
            guard !initial.isEmpty else {throw Model.Issue.message("设置页没有返回可读取的控件。")}
            checks["read_screen"]=true
            _ = try await execute(["action":"swipe","bundle_id":"com.apple.Preferences","direction":"up"])
            let moved=try await screen()
            checks["swipe_changed_screen"] = initial.contains { before in
                guard let label=before["label"] as? String,!label.isEmpty,let y=before["y"] as? Double else {return false}
                return moved.contains { after in (after["label"] as? String)==label && abs((after["y"] as? Double ?? y)-y)>20 }
            }
            _ = try await execute(["action":"swipe","bundle_id":"com.apple.Preferences","direction":"down"])
            let nodes=try await screen()
            let search=nodes.first {($0["search_field"] as? Bool)==true}
            guard let search,let x=search["x"] as? Double,let y=search["y"] as? Double else {throw Model.Issue.message("设置的搜索框不可见；启动和读屏已通过，输入验证尚未通过。")}
            _ = try await execute(["action":"tap","bundle_id":"com.apple.Preferences","x":x,"y":y])
            checks["tap_search"]=true
            let marker="MIKA_LOCAL_TEXT_OK"
            _ = try await execute(["action":"type","bundle_id":"com.apple.Preferences","text":marker])
            let typed=try await screen()
            checks["type_verified"]=typed.contains {($0["value"] as? String)?.contains(marker)==true}
            guard checks["type_verified"]==true else {throw Model.Issue.message("输入未获读屏确认，不能报告输入成功。")}
            _ = try await execute(["action":"type","bundle_id":"com.apple.Preferences","text":String(repeating:"\u{8}",count:marker.count)])
            detail="已验证：系统设置启动、读屏、点按、输入与滑动。"
        } catch {detail=error.localizedDescription}
        let result:[String:Any]=["checks":checks,"passed":checks.count==5 && checks.values.allSatisfy {$0},"timestamp":ISO8601DateFormatter().string(from:Date())]
        let url=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("LocalControlAcceptance.json")
        if let data=try? JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]) {try? data.write(to:url,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])}
    }

}

struct LocalControlSetup:View {
    @ObservedObject private var control=OnDeviceControl.shared
    @ObservedObject private var tunnel=MikaTunnelManager.shared
    @State private var importing=false
    @State private var importingProxy=false
    @State private var error=""
    @AppStorage("localExecutionMode") private var executionMode=AgentExecutionMode.background.rawValue
    @AppStorage("localReturnAfterTask") private var returnAfterTask=false
    var body:some View {
        Form {
            Section {
                Label(control.phase,systemImage:control.ready ? "checkmark.circle.fill" : "iphone.radiowaves.left.and.right")
                Text(control.detail).font(.footnote).accessibilityIdentifier("localControlStatus")
            }
            Section("一次性准备") {
                Text("Mac 只用于签名安装和首次导出配对记录。运行时由手机自身启动执行器。")
                if MikaTunnelManager.shared.embedded {
                    Text("此版本已集成本地开发隧道，无需单独安装 LocalDevVPN。首次启动需允许 Mika 添加 VPN 配置。")
                } else {
                    Text("当前签名版本需使用 LocalDevVPN 提供本地回环连接。集成版本需要具备 Network Extensions 权限的 Apple 开发团队签名。")
                    Link("打开 LocalDevVPN 设置",destination:URL(string:"localdevvpn://")!)
                }
                Button(control.hasPairing ? "重新导入配对记录" : "导入设备配对记录") {importing=true}.disabled(control.starting || control.ready)
                TextField("LocalDevVPN 的设备地址",text:$control.host).keyboardType(.decimalPad).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(control.starting || control.ready)
            }
            Section {
                Picker("执行模式",selection:$executionMode) {
                    ForEach(AgentExecutionMode.allCases) {mode in Text(mode.label).tag(mode.rawValue)}
                }.accessibilityIdentifier("localExecutionMode").accessibilityValue(AgentExecutionMode(rawValue:executionMode)?.label ?? "后台运行")
                Toggle("完成后返回 Mika",isOn:$returnAfterTask).disabled(executionMode==AgentExecutionMode.compatibility.rawValue).accessibilityIdentifier("localReturnAfterTask")
                Text(executionMode==AgentExecutionMode.background.rawValue ? "默认后台运行，停留在目标 App。系统无法继续提供后台时间时会暂停，点胶囊回到 Mika 后继续；不会通过反复切页维持运行。需要你回答时会返回。" : executionMode==AgentExecutionMode.continuous.rawValue ? "连续操作期间停留在目标 App，后台时间不足时返回 Mika 续接。" : "兼容模式每一步都返回 Mika，再处理下一步。")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("更改从下一项任务生效。系统取消或锁屏等中断不会被当作任务完成。").font(.footnote).foregroundStyle(.secondary)
                Button(control.starting ? "正在启动…" : "启动本机控制") {control.start()}.disabled(control.starting || control.ready || !control.hasPairing).accessibilityIdentifier("startLocalControl")
                Button("验证：打开设置并读屏") {Task {await control.smokeTest()}}.disabled(!control.ready)
                Button("停止本机控制",role:.destructive) {Task {await control.stop()}}
            } footer:{Text("控制时会切换到目标 App。系统锁屏及首次自动化授权由你在手机上处理。")}
            Section("同一隧道中的代理") {
                Toggle("代理网络 + 本机控制",isOn:$tunnel.proxyEnabled).disabled(!tunnel.embedded || control.starting || control.ready)
                Button(tunnel.hasProxyConfig ? "更换 Clash YAML 配置" : "导入 Clash YAML 配置") {importingProxy=true}.disabled(control.starting || control.ready)
                Text(tunnel.embedded ? "导入从 Clash Mi 导出的配置。启动后由同一隧道处理代理流量和本机开发连接；不需要同时运行两个 VPN。" : "代理与本地隧道的合并版本需要付费开发团队签名。当前版本不改变 Clash Mi 的配置。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if !error.isEmpty {Section {Text(error).foregroundStyle(.red)}}
        }.navigationTitle("本机控制").navigationBarTitleDisplayMode(.inline)
            .fileImporter(isPresented:$importing,allowedContentTypes:[.data]) {result in
                do {let url=try result.get();let access=url.startAccessingSecurityScopedResource();defer {if access {url.stopAccessingSecurityScopedResource()}};try control.importPairing(Data(contentsOf:url));error=""}
                catch {self.error=error.localizedDescription}
            }
            .fileImporter(isPresented:$importingProxy,allowedContentTypes:[.data,.text]) {result in
                do {let url=try result.get();let access=url.startAccessingSecurityScopedResource();defer {if access {url.stopAccessingSecurityScopedResource()}};try tunnel.importProxy(Data(contentsOf:url));error=""}
                catch {self.error=error.localizedDescription}
            }
    }
}
