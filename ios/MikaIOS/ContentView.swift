import SwiftUI
import UniformTypeIdentifiers

extension Color {
    static let mikaBlue = Color(red:0.039,green:0.486,blue:1)
    static let mikaBackground = Color(uiColor:.systemGroupedBackground)
}
struct ContentView: View {
    @StateObject private var model = Model()
    @State private var input = ""
    @State private var drawer = false
    @State private var destination: String?
    @State private var importing = false
    @State private var fileError = ""
    @FocusState private var focused: Bool
    private let examples: [(String,String)] = [
        ("app.badge","打开设置，告诉我安卓版本是多少"),
        ("globe","打开 Hacker News，读出首页前 5 条新闻"),
        ("doc.text","帮我总结当前网页的主要内容"),
        ("clock","帮我订明天早上 9:40 的闹钟"),
        ("bubble.left.and.bubble.right","先告诉我你能在这台设备上做什么")]
    var body: some View {
        ZStack(alignment:.leading) {
            NavigationStack {
                VStack(spacing:0) {
                    HStack(spacing:8) {
                        Circle().fill(model.mode == "安卓" ? Color.mikaBlue : Color.green).frame(width:6,height:6)
                        Text(model.mode == "安卓" ? "安卓 Mika · \(model.transport)" : "iPhone · 本机助手").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Menu { Button("iPhone 本机助手") { model.mode="iPhone" }; Button("安卓远程助手") { model.mode="安卓" } } label: { Image(systemName:"chevron.down").font(.caption).frame(width:32,height:32) }.accessibilityLabel("选择运行设备")
                    }.padding(.horizontal,22)
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment:.leading,spacing:18) {
                                if model.messages.isEmpty { welcome }
                                ForEach(model.messages) { message in
                                    VStack(alignment:message.role == "user" ? .trailing : .leading,spacing:6) {
                                        Text(message.role == "user" ? "你" : "Mika").font(.caption).foregroundStyle(.secondary)
                                        Text(message.text).textSelection(.enabled).padding(15)
                                            .background(message.role == "user" ? Color.mikaBlue.opacity(0.11) : Color(uiColor:.secondarySystemGroupedBackground))
                                            .clipShape(RoundedRectangle(cornerRadius:18))
                                    }.frame(maxWidth:.infinity,alignment:message.role == "user" ? .trailing : .leading).id(message.id)
                                }
                                if model.busy { HStack(spacing:10) { ProgressView(); Text("Mika 正在处理…").font(.subheadline).foregroundStyle(.secondary) } }
                            }.padding(20)
                        }.scrollDismissesKeyboard(.interactively)
                            .onChange(of:model.messages.count) { _ in if let id=model.messages.last?.id { withAnimation { proxy.scrollTo(id,anchor:.bottom) } } }
                    }
                }.background(Color.mikaBackground)
                    .safeAreaInset(edge:.bottom,spacing:0) { composer }
                    .navigationTitle("Mika").navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement:.navigationBarLeading) { Button { focused=false; withAnimation(.easeOut(duration:0.2)) { drawer=true } } label: { Image(systemName:"line.3.horizontal").frame(width:40,height:40) }.accessibilityLabel("菜单") }
                        ToolbarItem(placement:.navigationBarTrailing) { Button { model.newChat();input="" } label: { Image(systemName:"square.and.pencil").frame(width:40,height:40) }.accessibilityLabel("新对话").disabled(model.busy || !model.taskID.isEmpty) }
                    }
            }
            if drawer {
                Color.black.opacity(0.3).ignoresSafeArea().onTapGesture { withAnimation { drawer=false } }.accessibilityLabel("关闭菜单")
                sidebar.frame(width:300).background(Color(uiColor:.systemBackground)).transition(.move(edge:.leading))
            }
        }.tint(.mikaBlue)
            .sheet(item:$destination) { route in NavigationStack { routeView(route).toolbar { ToolbarItem(placement:.navigationBarTrailing) { Button("完成") { destination=nil } } } } }
            .fileImporter(isPresented:$importing,allowedContentTypes:[.plainText,.text],allowsMultipleSelection:false) { result in
                do { guard let url=try result.get().first else { return }; let granted=url.startAccessingSecurityScopedResource();defer { if granted { url.stopAccessingSecurityScopedResource() } }; let data=try Data(contentsOf:url);guard data.count<=1_000_000,let text=String(data:data,encoding:.utf8) else { throw Model.Issue.message("请选择 1 MB 以内的 UTF-8 文本文件") }; model.pageText=text }
                catch { fileError=error.localizedDescription }
            }.alert("无法读取文件",isPresented:Binding(get:{!fileError.isEmpty},set:{if !$0 {fileError=""}})) { Button("好") {fileError=""} } message: {Text(fileError)}
    }
    private var welcome: some View {
        VStack(alignment:.leading,spacing:8) {
            Text(greeting).font(.system(size:30,weight:.semibold)).padding(.top,42)
            Text("想让 Mika 做什么？").font(.title3).foregroundStyle(.secondary)
            VStack(spacing:0) { ForEach(examples.indices,id:\.self) { index in
                if index>0 { Divider().padding(.leading,54) }
                Button { input=examples[index].1; focused=true } label: {
                    HStack(spacing:16) { Image(systemName:examples[index].0).frame(width:22).foregroundStyle(.secondary); Text(examples[index].1).font(.system(size:15)).multilineTextAlignment(.leading).foregroundStyle(.primary); Spacer(minLength:0) }.padding(.horizontal,16).padding(.vertical,18).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
            } }.background(Color(uiColor:.secondarySystemGroupedBackground)).clipShape(RoundedRectangle(cornerRadius:20)).padding(.top,20)
            if model.mode == "iPhone" { Text("操作安卓 App 请切换到安卓助手，并在设置中配置连接。当前 iPhone 助手支持聊天和阅读内容。").font(.caption).foregroundStyle(.secondary).padding(.top,12) }
        }
    }
    private var greeting: String { let hour=Calendar.current.component(.hour,from:Date());return hour<12 ? "上午好" : hour<18 ? "下午好" : "晚上好" }
    private var composer: some View {
        VStack(spacing:8) {
            if !model.taskID.isEmpty {
                HStack { Text(model.waiting ? "Mika 需要你的回答" : "有正在执行的任务").font(.caption);Spacer();if !model.busy {Button("查看") { Task { await model.resumeTask() } }};Button("停止",role:.destructive) { Task { await model.cancelTask() } } }.padding(.horizontal,20)
            }
            if !model.pageText.isEmpty { HStack { Label("已附加阅读内容",systemImage:"doc.text");Spacer();Button("移除") {model.pageText=""} }.font(.caption).padding(.horizontal,20) }
            HStack(alignment:.bottom,spacing:10) {
                Menu { Button("打开浏览器",systemImage:"globe") { open("浏览器") };Button("添加文本文件",systemImage:"doc") {importing=true} } label: { Image(systemName:"plus").font(.title3).foregroundStyle(.secondary).frame(width:40,height:44) }.accessibilityLabel("添加附件")
                TextField("说说想做的事…",text:$input,axis:.vertical).lineLimit(1...5).focused($focused).accessibilityIdentifier("taskInput").padding(.vertical,12)
                Button { let text=input; input="";focused=false;Task {await model.send(text)} } label: { Image(systemName:"arrow.up").font(.system(size:18,weight:.semibold)).foregroundStyle(.white).frame(width:38,height:38).background(input.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || model.busy ? Color.gray.opacity(0.35) : Color.mikaBlue).clipShape(Circle()) }.accessibilityLabel("发送").disabled(model.busy || input.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty).padding(.bottom,4)
            }.padding(.trailing,8).background(Color(uiColor:.secondarySystemGroupedBackground)).clipShape(RoundedRectangle(cornerRadius:25)).overlay(RoundedRectangle(cornerRadius:25).stroke(Color.primary.opacity(0.06))).padding(.horizontal,14)
        }.padding(.vertical,10).background(.ultraThinMaterial)
    }
    private var sidebar: some View {
        VStack(alignment:.leading,spacing:8) {
            HStack { Image(systemName:"sparkle").font(.title); VStack(alignment:.leading) {Text("Mika").font(.title2.bold());Text(model.mode == "安卓" ? "安卓远程助手" : "iPhone 助手").font(.caption).foregroundStyle(.secondary)};Spacer() }.padding(22)
            sideButton("新对话","square.and.pencil") { model.newChat();drawer=false }
            sideButton("浏览器","globe") {open("浏览器")}
            sideButton("连接设备","iphone.radiowaves.left.and.right") {open("连接设备")}
            Divider().padding(.vertical,10)
            Text("最近对话").font(.caption).foregroundStyle(.secondary).padding(.horizontal,22)
            ScrollView { VStack(spacing:2) {ForEach(model.chats) { chat in Button {model.selectChat(chat.id);drawer=false} label: {Text(chat.title).lineLimit(1).frame(maxWidth:.infinity,alignment:.leading).padding(14).foregroundStyle(.primary)}.disabled(model.busy || !model.taskID.isEmpty)} }.padding(.horizontal,8) }
            sideButton("设置","gearshape") {open("设置")}
            sideButton("关于 Mika","info.circle") {open("关于 Mika")}
        }.padding(.vertical,10)
    }
    private func sideButton(_ label:String,_ icon:String,action:@escaping()->Void)->some View {Button(action:action) {Label(label,systemImage:icon).frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,22).padding(.vertical,12)}.foregroundStyle(.primary)}
    private func open(_ route:String) {drawer=false;focused=false;destination=route}
    @ViewBuilder private func routeView(_ route:String)->some View {
        switch route {
        case "设置": SettingsHome(model:model)
        case "连接设备": ConnectionSettings(model:model)
        case "浏览器": BrowserView(model:model)
        default: List {Section {Text("Mika").font(.largeTitle.bold());Text("iPhone 伴侣 · 开发版");Text("基于 wangzan101/Mika 的 Android 项目移植界面，并实现原生聊天、网页阅读和安卓远程任务。")};Section("项目") {Link("Mika 源码",destination:URL(string:"https://github.com/wangzan101/Mika")!);Link("REA",destination:URL(string:"https://github.com/morluto/rea")!)} }.navigationTitle("关于 Mika")
        }
    }
}
extension String: @retroactive Identifiable { public var id:String {self} }
