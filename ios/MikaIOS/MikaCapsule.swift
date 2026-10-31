import SwiftUI
import Combine
import ActivityKit

struct MikaCapsuleState:Equatable {
    var id=""
    var phase="idle"
    var headline="Mika 随时待命"
    var detail="点按胶囊，交代一件事"
    var target="iPhone 本机"
    var active=false
    var canStop=false
    var needsUser:Bool {phase=="needsUser" || phase=="failed"}
    @MainActor static func read(_ model:Model)->Self {
        var state=Self();state.id=model.capsuleOperationID
        state.target=model.remoteTask?.connection.label ?? model.targetLabel
        if let remote=model.remoteTask {
            state.id=remote.id;state.active=true;state.canStop = !model.cancelling
            if model.cancelling {state.phase="stopping";state.headline="正在停止任务";state.detail="等待目标设备确认"}
            else if ["waiting_for_answer","waiting_on_phone"].contains(remote.status) {state.phase="needsUser";state.headline="Mika 需要你处理";state.detail=remote.status=="waiting_for_answer" ? "打开 Mika 回答问题" : "请在目标手机上完成操作"}
            else {state.phase="running";state.headline=model.busy ? "Mika 正在处理" : "任务待查看";state.detail=model.busy ? "正在查看目标设备进度" : "打开 Mika 恢复查看进度"}
        } else if let item=model.localInteraction {
            state.active=true;state.canStop=true;state.phase="needsUser";state.headline="Mika 需要你处理";state.detail=item.kind == .handoff ? "请在本机完成操作后交还控制" : "打开 Mika 回答问题"
        } else if model.busy {
            state.active=true;state.phase="running";state.headline="Mika 正在处理"
            state.detail=model.isRemote ? "正在提交到目标设备" : model.localProgress
            state.canStop = !model.isRemote
        } else if !model.lastOutcome.isEmpty {
            state.phase=model.lastOutcome
            state.headline=["done":"任务已完成","failed":"任务未完成","cancelled":"后续处理已停止","detached":"已解除本机关联"][model.lastOutcome] ?? "Mika 随时待命"
            state.detail="打开 Mika 查看详情"
        }
        return state
    }
}

@available(iOS 16.2,*) @MainActor private final class MikaActivityBridge {
    var changed:((String,Int)->Void)?
    private var current:Activity<MikaActivityAttributes>?
    private var last:MikaCapsuleState?
    private var stateWatch:Task<Void,Never>?
    private var dismissedIDs=Set<String>()
    private var endedByApp=Set<String>()
    func apply(_ state:MikaCapsuleState) async {
        guard last != state else {return};last=state
        if !state.active {
            for activity in Activity<MikaActivityAttributes>.activities {
                endedByApp.insert(activity.id)
                await activity.end(ActivityContent(state:content(state),staleDate:nil),dismissalPolicy:.after(Date().addingTimeInterval(15)))
            }
            current=nil;changed?("当前没有系统胶囊",0);return
        }
        guard !dismissedIDs.contains(state.id) else {changed?("本轮系统胶囊已由你关闭",0);return}
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {changed?("系统已关闭 Mika 实时活动",0);return}
        if current?.attributes.operationID != state.id {
            for activity in Activity<MikaActivityAttributes>.activities where activity.attributes.operationID != state.id {endedByApp.insert(activity.id);await activity.end(nil,dismissalPolicy:.immediate)}
            current=Activity<MikaActivityAttributes>.activities.first {$0.attributes.operationID==state.id}
        }
        let value=ActivityContent(state:content(state),staleDate:Date().addingTimeInterval(60))
        do {
            if let current {await current.update(value)}
            else if UIApplication.shared.applicationState == .active {
                current=try Activity.request(attributes:MikaActivityAttributes(operationID:state.id,target:state.target),content:value,pushType:nil)
            } else {changed?("回到 Mika 后显示系统胶囊",0);last=nil;return}
            if let current {watch(current)}
            changed?("系统胶囊已显示",current == nil ? 0 : 1)
        } catch {changed?("系统胶囊启动失败，请检查实时活动设置",0);last=nil}
    }
    private func watch(_ activity:Activity<MikaActivityAttributes>) {
        stateWatch?.cancel()
        stateWatch=Task { [weak self] in
            for await status in activity.activityStateUpdates {
                guard !Task.isCancelled,let self else {return}
                if status == .dismissed || status == .ended {
                    guard self.current?.id==activity.id else {return}
                    if status == .dismissed,!self.endedByApp.contains(activity.id) {self.dismissedIDs.insert(activity.attributes.operationID)}
                    self.current=nil;self.last=nil;self.changed?("本轮系统胶囊已关闭",0);return
                }
            }
        }
    }
    func endStale(_ id:String) async {
        for activity in Activity<MikaActivityAttributes>.activities where activity.attributes.operationID==id {endedByApp.insert(activity.id);await activity.end(nil,dismissalPolicy:.immediate)}
        if current?.attributes.operationID==id {current=nil;last=nil}
        changed?(current == nil ? "当前没有系统胶囊" : "系统胶囊已显示",current == nil ? 0 : 1)
    }
    func heartbeat() async {
        guard let current,let last,last.active,current.attributes.operationID==last.id else {return}
        await current.update(ActivityContent(state:content(last),staleDate:Date().addingTimeInterval(60)))
    }
    private func content(_ state:MikaCapsuleState)->MikaActivityAttributes.ContentState {
        .init(phase:state.phase,headline:state.headline,detail:state.detail,canStop:state.canStop,updatedAt:Date())
    }
}

@MainActor final class MikaCapsuleCoordinator:ObservableObject {
    static let shared=MikaCapsuleCoordinator()
    @Published var mode=UserDefaults.standard.string(forKey:"capsuleMode") ?? "always" {didSet {UserDefaults.standard.set(mode,forKey:"capsuleMode");refresh()}}
    @Published var systemEnabled=UserDefaults.standard.object(forKey:"capsuleSystemEnabled") as? Bool ?? true {didSet {UserDefaults.standard.set(systemEnabled,forKey:"capsuleSystemEnabled");refresh()}}
    @Published var expanded=false {didSet {if !expanded {window?.endEditing(true);window?.resignKey();previousKey?.makeKey()};saveDiagnostics()}}
    @Published private(set) var state=MikaCapsuleState()
    @Published private(set) var systemStatus="当前没有系统胶囊"
    @Published private(set) var activityCount=0
    @Published private(set) var lastAction=UserDefaults.standard.string(forKey:"capsuleLastAction") ?? "" {didSet {UserDefaults.standard.set(lastAction,forKey:"capsuleLastAction")}}
    @Published private(set) var inputError=""
    private weak var model:Model?
    private var subscriptions=Set<AnyCancellable>()
    private var window:CapsuleWindow?
    private weak var previousKey:UIWindow?
    private var bridge:AnyObject?
    private var desired=MikaCapsuleState()
    private var updateTask:Task<Void,Never>?
    private var previewState:MikaCapsuleState?
    private var previewTask:Task<Void,Never>?
    private var pulse:Task<Void,Never>?
    private var foreground=true
    var bubbleVisible:Bool {mode=="always" || (mode=="duringTasks" && state.active)}
    var previewing:Bool {previewState != nil}
    var currentModel:Model? {model}
    var interaction:PhoneInteraction? {RemoteIOSReceiver.shared.activeTask?.interaction ?? model?.localInteraction ?? model?.remoteTask?.interaction}
    var interactionOwner:Bool {RemoteIOSReceiver.shared.activeTask != nil || model?.localInteraction != nil}
    var canSubmit:Bool {if let task=RemoteIOSReceiver.shared.activeTask {return task.interaction?.kind == .question};return model?.canSend == true}
    func bind(_ model:Model) {
        guard self.model !== model else {refresh();return}
        self.model=model;subscriptions=[]
        model.objectWillChange.sink { [weak self] in Task { @MainActor in self?.refresh() }}.store(in:&subscriptions)
        OnDeviceControl.shared.objectWillChange.sink { [weak self] in Task { @MainActor in self?.refresh() }}.store(in:&subscriptions)
        RemoteIOSReceiver.shared.objectWillChange.sink { [weak self] in Task { @MainActor in self?.refresh() }}.store(in:&subscriptions)
        ensureBridge()
        if pulse==nil {
            pulse=Task { [weak self] in
                while !Task.isCancelled {
                    do {try await Task.sleep(nanoseconds:20_000_000_000)} catch {return}
                    guard let self else {return}
                    if self.foreground,self.desired.active {
                        if #available(iOS 16.2,*),let service=self.bridge as? MikaActivityBridge {await service.heartbeat()}
                    }
                }
            }
        }
        refresh();showWindow()
    }
    private func ensureBridge() {
        if #available(iOS 16.2,*),bridge==nil {
            let service=MikaActivityBridge()
            service.changed={ [weak self] text,count in self?.systemStatus=text;self?.activityCount=count;self?.saveDiagnostics() }
            bridge=service
        }
    }
    func setForeground(_ active:Bool) {foreground=active;window?.isHidden = !active || !bubbleVisible;if active {showWindow();refresh()}}
    func refresh() {
        if let model {state=MikaCapsuleState.read(model)}
        if let received=RemoteIOSReceiver.shared.activeTask {
            state=MikaCapsuleState(id:"received:"+received.id,phase:received.cancelRequested ? "stopping" : received.interaction != nil ? "needsUser" : "running",headline:received.interaction != nil ? "远程协助需要你处理" : "正在执行远程协助",detail:received.cancelRequested ? "正在停止后续操作" : received.progress,target:"iPhone 远程协助",active:true,canStop:!received.cancelRequested)
        }
        if lastAction=="intent_stop_preview",state.active || OnDeviceControl.shared.ready {lastAction=""}
        if mode=="off" {expanded=false}
        window?.isHidden = !foreground || !bubbleVisible
        desired=previewState ?? state
        let control=OnDeviceControl.shared
        if previewState==nil,!state.active,mode=="always",control.ready,!control.sessionIdentifier.isEmpty {
            desired=MikaCapsuleState(id:"session:"+control.sessionIdentifier,phase:"ready",headline:"Mika 本机控制已就绪",detail:"点按返回 Mika 交代任务",target:"iPhone 本机",active:true,canStop:true)
        }
        if !systemEnabled || mode=="off" {desired.active=false;desired.phase="idle";desired.canStop=false}
        pumpUpdates();saveDiagnostics()
    }
    private func pumpUpdates() {
        guard updateTask==nil else {return}
        updateTask=Task { [weak self] in
            guard let self else {return}
            var applied:MikaCapsuleState?
            while !Task.isCancelled,applied != self.desired {
                let snapshot=self.desired
                if #available(iOS 16.2,*),let bridge=self.bridge as? MikaActivityBridge {await bridge.apply(snapshot)}
                else {self.systemStatus="系统胶囊需要 iOS 16.2 或更新版本"}
                applied=snapshot
            }
            self.updateTask=nil
        }
    }
    func expand() {guard !expanded else {expanded=false;return};expanded=true;previousKey=window?.windowScene?.windows.first {$0.isKeyWindow && $0 !== window} ?? window?.windowScene?.windows.first {$0 !== window && $0.windowLevel == .normal};window?.makeKey()}
    func submit(_ text:String) async {
        if let task=RemoteIOSReceiver.shared.activeTask,let item=task.interaction,item.kind == .question {
            do {_ = try RemoteIOSReceiver.shared.tasks.respond(taskID:task.id,interactionID:item.id,text:text,source:.owner);inputError="";expanded=false} catch {inputError=error.localizedDescription};return
        }
        guard let model,model.canSend else {return}
        expanded=false
        await model.send(text)
    }
    func respond(_ text:String,expectedID:String) async throws {
        if let task=RemoteIOSReceiver.shared.activeTask,task.interaction?.id==expectedID {_ = try RemoteIOSReceiver.shared.tasks.respond(taskID:task.id,interactionID:expectedID,text:text,source:.owner);return}
        guard let model else {throw Model.Issue.message("任务会话已结束")}
        try await model.respondToInteraction(text,expectedID:expectedID)
    }
    func stop(_ id:String) async throws {
        ensureBridge()
        var knownPreview=previewState?.id==id
        if #available(iOS 16.2,*),id.hasPrefix("preview:") {
            knownPreview = knownPreview || Activity<MikaActivityAttributes>.activities.contains {$0.attributes.operationID==id}
        }
        if knownPreview {
            lastAction="intent_stop_preview"
            if previewState?.id==id {previewTask?.cancel();previewTask=nil;previewState=nil}
            if #available(iOS 16.2,*),let bridge=bridge as? MikaActivityBridge {await bridge.endStale(id)}
            refresh();return
        }
        let control=OnDeviceControl.shared
        let receiver=RemoteIOSReceiver.shared
        if let received=receiver.activeTask,id=="received:"+received.id {
            lastAction="intent_stop_received";await receiver.tasks.cancel(received.id);refresh();return
        }
        if id=="session:"+control.sessionIdentifier,control.ready,receiver.activeTask==nil,!MikaCapsuleState.read(model ?? Model()).active {
            lastAction="intent_stop_session";await control.stop();refresh();return
        }
        let active=model ?? Model()
        let snapshot=MikaCapsuleState.read(active)
        guard snapshot.active,snapshot.id==id,snapshot.canStop else {
            if #available(iOS 16.2,*),let bridge=bridge as? MikaActivityBridge {await bridge.endStale(id)}
            return
        }
        lastAction="intent_stop_task";saveDiagnostics()
        await active.stopWork(expectedID:id)
        if model == nil {bind(active)}
        refresh()
    }
    func preview() {
        guard !state.active else {return}
        previewTask?.cancel()
        previewState=MikaCapsuleState(id:"preview:"+UUID().uuidString,phase:"preview",headline:"Mika 胶囊预览",detail:"长按灵动岛可结束预览",target:"预览",active:true,canStop:true)
        lastAction="preview_started";refresh()
        previewTask=Task { [weak self] in
            let background=UIApplication.shared.beginBackgroundTask(withName:"Mika 胶囊短时预览")
            defer {if background != .invalid {UIApplication.shared.endBackgroundTask(background)}}
            do {try await Task.sleep(nanoseconds:25_000_000_000)} catch {return}
            self?.lastAction="preview_timed_out";self?.previewState=nil;self?.refresh()
        }
    }
    func route(_ route:String) {expanded=false;NotificationCenter.default.post(name:.mikaCapsuleRoute,object:route)}
    private func showWindow() {
        guard foreground,window==nil,let scene=UIApplication.shared.connectedScenes.compactMap({$0 as? UIWindowScene}).first(where:{$0.activationState == .foregroundActive}) else {return}
        let overlay=CapsuleWindow(windowScene:scene)
        overlay.windowLevel = .normal+1
        let controller=UIHostingController(rootView:MikaCapsuleOverlay(coordinator:self,regions:{ [weak self,weak overlay] in overlay?.regions=$0;self?.saveDiagnostics() }))
        controller.view.backgroundColor = .clear
        overlay.rootViewController=controller;overlay.backgroundColor = .clear;overlay.isHidden = !bubbleVisible
        window=overlay
    }
    private func saveDiagnostics() {
        let value:[String:Any]=["mode":mode,"phase":state.phase,"bubble_visible":bubbleVisible && foreground && !expanded,"expanded":expanded,"system_status":systemStatus,"system_activity_count":activityCount,"system_phase":desired.phase,"last_action":lastAction,"preview":previewState != nil,"hit_regions":(window?.regions ?? []).map {[$0.minX,$0.minY,$0.width,$0.height]},"timestamp":ISO8601DateFormatter().string(from:Date())]
        let url=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("CapsuleDiagnostics.json")
        if let data=try? JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]) {try? data.write(to:url,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])}
    }
}

extension Notification.Name {static let mikaCapsuleRoute=Notification.Name("MikaCapsuleRoute")}
@MainActor private final class CapsuleWindow:UIWindow {
    var regions:[CGRect]=[]
    override func point(inside point:CGPoint,with event:UIEvent?)->Bool {regions.contains {$0.contains(point)}}
}
private struct CapsuleRegions:PreferenceKey {
    static var defaultValue:[CGRect]=[]
    static func reduce(value:inout [CGRect],nextValue:()->[CGRect]) {value+=nextValue()}
}
private extension View {
    func capsuleHitRegion()->some View {background(GeometryReader {proxy in Color.clear.preference(key:CapsuleRegions.self,value:[proxy.frame(in:.global)])})}
}
private struct MikaCapsuleOverlay:View {
    @ObservedObject var coordinator:MikaCapsuleCoordinator
    var regions:([CGRect])->Void
    @AppStorage("capsuleRightEdge") private var right=true
    @AppStorage("capsuleVerticalFraction") private var fraction=0.3
    @GestureState private var drag=CGSize.zero
    @State private var input=""
    @State private var dragging=false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body:some View {
        GeometryReader {proxy in
            let top=proxy.safeAreaInsets.top+72
            let bottom=max(top+1,proxy.size.height-proxy.safeAreaInsets.bottom-120)
            let x=(right ? proxy.size.width-40 : 40)+drag.width
            let y=min(bottom,max(top,top+(bottom-top)*fraction+drag.height))
            ZStack {
                if coordinator.expanded {
                    Color.black.opacity(0.12).ignoresSafeArea().onTapGesture {coordinator.expanded=false}.capsuleHitRegion()
                    card.frame(width:min(350,proxy.size.width-32)).position(x:proxy.size.width/2,y:proxy.size.height*0.43).capsuleHitRegion()
                }
                if coordinator.bubbleVisible && !coordinator.expanded {
                    Button {if !dragging {coordinator.expand()}} label:{
                        ZStack {
                            Circle().fill(.ultraThinMaterial).shadow(color:.black.opacity(0.2),radius:10,y:3)
                            Image("MikaLogo").resizable().scaledToFit().padding(10)
                            Circle().stroke(coordinator.state.needsUser ? .orange : Color.mikaBlue.opacity(0.7),lineWidth:2)
                            if coordinator.state.active {
                                Image(systemName:coordinator.state.needsUser ? "exclamationmark.circle.fill" : "ellipsis.circle.fill").foregroundStyle(coordinator.state.needsUser ? .orange : .blue).background(Circle().fill(.white)).offset(x:20,y:-20)
                            }
                        }.frame(width:54,height:54)
                    }.buttonStyle(.plain).accessibilityLabel("Mika 悬浮胶囊").accessibilityIdentifier("mikaCapsuleBall")
                        .capsuleHitRegion().position(x:min(proxy.size.width-30,max(30,x)),y:y)
                        .simultaneousGesture(DragGesture(minimumDistance:8).updating($drag) {value,state,_ in state=value.translation}.onChanged {_ in dragging=true}.onEnded {value in
                            withAnimation(reduceMotion ? nil : .spring(response:0.3)) {right=(right ? proxy.size.width-40 : 40)+value.translation.width>proxy.size.width/2;fraction=min(1,max(0,(top+(bottom-top)*fraction+value.translation.height-top)/(bottom-top)))}
                            DispatchQueue.main.asyncAfter(deadline:.now()+0.2) {dragging=false}
                        })
                }
            }
        }.ignoresSafeArea(.container).coordinateSpace(name:"capsuleWindow").onPreferenceChange(CapsuleRegions.self,perform:regions)
    }
    private var card:some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {Image("MikaLogo").resizable().scaledToFit().frame(width:30,height:30);Text("Mika").font(.headline);Spacer();Button {coordinator.expanded=false} label:{Image(systemName:"xmark.circle.fill").foregroundStyle(.secondary)}.accessibilityLabel("收起胶囊")}
            Text(coordinator.state.headline).font(.title3.bold())
            Text(coordinator.state.active ? (coordinator.currentModel?.taskProgress.isEmpty==false ? coordinator.currentModel!.taskProgress : coordinator.state.detail) : (coordinator.currentModel?.mode=="安卓" ? "任务将交给已配置的安卓 Mika" : (OnDeviceControl.shared.ready ? "本机控制已连接" : "本机控制未开启，可聊天或切换安卓助手"))).font(.subheadline).foregroundStyle(.secondary)
            if let item=coordinator.interaction {PhoneInteractionView(interaction:item,owner:coordinator.interactionOwner,showsInput:false) {text in try await coordinator.respond(text,expectedID:item.id)}.id(item.id)}
            else if let remote=coordinator.currentModel?.remoteTask,!remote.question.isEmpty {Text(remote.question).font(.subheadline).lineLimit(4)}
            if !coordinator.inputError.isEmpty {Text(coordinator.inputError).font(.caption).foregroundStyle(.red)}
            TextField(coordinator.interaction != nil || coordinator.currentModel?.waiting==true ? "回答 Mika…" : "交代一件事…",text:$input,axis:.vertical).lineLimit(1...4).textFieldStyle(.roundedBorder).accessibilityIdentifier("capsuleTaskInput")
            HStack {
                Button("查看对话") {coordinator.route("task")}
                Spacer()
                if coordinator.state.canStop {Button("停止",role:.destructive) {Task {try? await coordinator.stop(coordinator.state.id)}}.accessibilityIdentifier("capsuleStop")}
                Button("发送") {let text=input;input="";Task {await coordinator.submit(text)}}.buttonStyle(.borderedProminent).disabled(input.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || !coordinator.canSubmit).accessibilityIdentifier("capsuleSend")
            }
            Divider()
            HStack {Button("本机控制") {coordinator.route("local")};Spacer();Button("胶囊设置") {coordinator.route("capsule")}}
                .font(.caption)
        }.padding(18).background(.regularMaterial,in:RoundedRectangle(cornerRadius:24)).shadow(color:.black.opacity(0.16),radius:20,y:8).accessibilityElement(children:.contain)
    }
}

struct CapsuleSettings:View {
    @ObservedObject private var coordinator=MikaCapsuleCoordinator.shared
    var body:some View {
        Form {
            Section("应用内悬浮胶囊") {
                Picker("显示方式",selection:$coordinator.mode) {Text("关闭").tag("off");Text("任务期间").tag("duringTasks");Text("总是显示").tag("always")}.pickerStyle(.inline).accessibilityIdentifier("capsuleMode")
                Text("胶囊可拖动并吸附左右边缘。点按展开后可输入任务、查看状态和停止任务。").font(.footnote).foregroundStyle(.secondary)
            }
            Section("离开 Mika 后") {
                Toggle("灵动岛与锁屏实时活动",isOn:$coordinator.systemEnabled).accessibilityIdentifier("capsuleSystemEnabled")
                Text("任务进行期间显示系统胶囊；选择“总是显示”且本机控制已开启时，也保留就绪入口。长按可查看或停止，点按返回 Mika。系统胶囊不显示任务正文、密钥或读屏内容；显示时长由 iOS 管理。").font(.footnote).foregroundStyle(.secondary)
                Text(coordinator.systemStatus).font(.footnote).accessibilityIdentifier("capsuleSystemStatus")
                if coordinator.lastAction=="intent_stop_preview" {Text("已通过系统按钮结束预览").font(.footnote).accessibilityIdentifier("capsuleIntentResult")}
                Button("预览系统胶囊") {coordinator.preview()}.disabled(coordinator.state.active || !coordinator.systemEnabled || coordinator.mode=="off").accessibilityIdentifier("capsulePreview")
            }
            Section {Text("iPhone 不支持安卓式覆盖桌面和任意 App 的自由悬浮球。应用内胶囊与系统实时活动各有显示位置；切换到其他 App 后不会出现可拖动的悬浮球。").font(.footnote).foregroundStyle(.secondary)}
        }.navigationTitle("悬浮胶囊").navigationBarTitleDisplayMode(.inline)
    }
}
