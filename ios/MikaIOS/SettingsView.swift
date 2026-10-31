import SwiftUI
struct SettingsHome: View {
    @ObservedObject var model: Model
    var body: some View {
        List {
            Section {
                HStack(spacing:14) { Image(systemName:model.mode == "安卓" ? "iphone.radiowaves.left.and.right" : "sparkles").font(.title2).foregroundStyle(Color.mikaBlue); VStack(alignment:.leading,spacing:5) {Text(model.mode == "安卓" ? "安卓远程助手" : "iPhone 本机助手").font(.headline);Text(model.busy ? "正在执行任务" : "按需配置模型与连接设备").font(.caption).foregroundStyle(.secondary)} }
            }
            Section("基本") {
                NavigationLink { ModelSettings(model:model) } label: { setting("模型","cpu",model.model) }.accessibilityIdentifier("settingsModels")
                NavigationLink { ConnectionSettings(model:model) } label: { setting("手机操作","iphone",model.mode == "安卓" ? model.transport : "本机助手") }
                NavigationLink { BrowserView(model:model) } label: { setting("浏览器","globe","") }
            }
            Section("隐私与数据") {
                NavigationLink { List {Section("存储") {Text("API Key 和配对令牌保存在本机钥匙串；对话保存在本机应用目录。模型请求直接发给你配置的服务商。")};Section("阅读内容") {Text("网页或文件只在你主动读取后附加到后续模型请求，可在输入栏上方移除。")} }.navigationTitle("数据与隐私") } label: { setting("数据与隐私","lock.shield","") }
                NavigationLink { List {ForEach(model.chats) { chat in VStack(alignment:.leading,spacing:5) {Text(chat.title);Text("\(chat.messages.count) 条消息").font(.caption).foregroundStyle(.secondary)} }}.navigationTitle("对话记录") } label: {setting("对话记录","bubble.left.and.bubble.right","\(model.chats.count)")}
            }
            Section("关于") {Text("Mika iPhone · 开发版");Text("界面参考 Android Mika。当前受控端支持安卓 Mika；iPhone 跨 App 受控尚不可用。").font(.footnote).foregroundStyle(.secondary)}
        }.navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
    }
    private func setting(_ title:String,_ icon:String,_ value:String)->some View {HStack(spacing:14) {Image(systemName:icon).foregroundStyle(.secondary).frame(width:30,height:38);Text(title);Spacer();Text(value).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)}}
}
struct ModelSettings: View {
    @ObservedObject var model: Model
    @State private var testing=false
    @State private var status=""
    var body: some View {
        Form {
            Section {Text("Mika 用你自己的模型服务来思考。连接一家服务商，再选择支持工具调用的模型。").font(.subheadline).foregroundStyle(.secondary)}
            Section("服务商") {
                Button {model.base="https://api.deepseek.com/v1";model.model="deepseek-flash"} label: {HStack {Text("D").font(.title2.bold()).frame(width:42,height:42).background(Color.mikaBlue.opacity(0.1)).clipShape(RoundedRectangle(cornerRadius:12));VStack(alignment:.leading) {Text("DeepSeek");Text("使用官方接口预设").font(.caption).foregroundStyle(.secondary)};Spacer();Image(systemName:"chevron.right").font(.caption)}}
                TextField("HTTPS 基础地址",text:$model.base).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                SecureField("API Key",text:$model.apiKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("主模型名称",text:$model.model).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            Section {
                Button {Task {await test()}} label: {HStack {Text(testing ? "正在测试…" : "测试连接");Spacer();if testing {ProgressView()}}}.disabled(testing || model.apiKey.isEmpty)
                if !status.isEmpty {Text(status).font(.footnote)}
            } footer: {Text("配置自动保存，API Key 加密存放在本机钥匙串。测试连接只获取模型列表，不产生聊天任务。")}
        }.disabled(model.busy).navigationTitle("模型").navigationBarTitleDisplayMode(.inline)
    }
    private func test() async {
        testing=true;defer {testing=false}
        do {let base=model.base.trimmingCharacters(in:CharacterSet(charactersIn:"/"));guard let u=URL(string:base+"/models"),u.scheme=="https" else {throw Model.Issue.message("请填写 HTTPS 地址")};var r=URLRequest(url:u);r.timeoutInterval=15;r.setValue("Bearer \(model.apiKey)",forHTTPHeaderField:"Authorization");let (data,response)=try await URLSession.shared.data(for:r);guard let h=response as? HTTPURLResponse,h.statusCode==200 else {throw Model.Issue.message("连接失败，HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")};let j=try JSONSerialization.jsonObject(with:data) as? [String:Any];let list=j?["data"] as? [[String:Any]] ?? [];status=list.contains(where:{$0["id"] as? String == model.model}) ? "已连接 · 主模型可用" : "已连接，但列表中未找到填写的模型"} catch {status=error.localizedDescription}
    }
}
struct ConnectionSettings: View {
    @ObservedObject var model: Model
    @State private var status=""
    @State private var testing=false
    var body: some View {
        Form {
            Section("运行位置") {Picker("助手",selection:$model.mode) {Text("iPhone 本机").tag("iPhone");Text("安卓 Mika").tag("安卓")}.pickerStyle(.segmented);Text("iPhone 本机支持聊天和阅读内容。安卓助手可通过 Mika 操作目标手机。").font(.footnote).foregroundStyle(.secondary)}
            Section("连接方式") {Picker("连接方式",selection:$model.transport) {Text("同一网络直连").tag("直连");Text("公网中继").tag("中继")}.pickerStyle(.segmented)}
            if model.transport == "中继" {
                Section {TextField("HTTPS 中继地址",text:$model.relayURL).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL);TextField("设备 ID",text:$model.deviceID).textInputAutocapitalization(.never).autocorrectionDisabled();SecureField("控制端配对令牌",text:$model.relayToken).textInputAutocapitalization(.never).autocorrectionDisabled()} header: {Text("公网中继")} footer: {Text("安卓端开启 Mika 远程连接，并配对同一个设备 ID。公网须使用 HTTPS。")}
            } else {
                Section {TextField("MCP 地址",text:$model.mcp).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL);SecureField("访问令牌",text:$model.token).textInputAutocapitalization(.never).autocorrectionDisabled()} header: {Text("安卓 Mika MCP")} footer: {Text("在安卓 Mika 设置 → 电脑连接（MCP）中开启 Wi-Fi 和私有网络，填写显示的地址和令牌。")}
            }
            Section {Button {Task {testing=true;defer {testing=false};do {_ = try await model.call("mika_list_tasks",["limit":1]);status="已连接 · 目标 Mika 响应正常"} catch {status=error.localizedDescription}}} label: {HStack {Text(testing ? "正在检查…" : "检查连接");Spacer();if testing {ProgressView()}}}.disabled(testing);if !status.isEmpty {Text(status).font(.footnote)}}
        }.disabled(model.busy || !model.taskID.isEmpty).navigationTitle("手机操作").navigationBarTitleDisplayMode(.inline)
    }
}
