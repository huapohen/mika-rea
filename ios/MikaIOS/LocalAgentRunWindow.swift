import UIKit

@MainActor protocol AgentRunEnvironment:AnyObject {
    var foreground:Bool {get}
    var remaining:TimeInterval {get}
    func begin(_ expiration:@escaping @MainActor @Sendable ()->Void)
    func end()
}

@MainActor private final class UIKitAgentRunEnvironment:AgentRunEnvironment {
    private var identifier:UIBackgroundTaskIdentifier = .invalid
    var foreground:Bool {UIApplication.shared.applicationState == .active}
    var remaining:TimeInterval {UIApplication.shared.backgroundTimeRemaining}
    func begin(_ expiration:@escaping @MainActor @Sendable ()->Void) {
        end()
        identifier=UIApplication.shared.beginBackgroundTask(withName:"Mika 连续手机任务",expirationHandler:expiration)
    }
    func end() {
        if identifier != .invalid {UIApplication.shared.endBackgroundTask(identifier);identifier = .invalid}
    }
}

/// Uses system-continued execution when granted, with a finite fallback spanning
/// model requests and UI operations. Background mode pauses instead of bouncing UI.
@MainActor final class LocalAgentRunWindow {
    typealias Command=([String:Any],Bool) async throws -> [String:Any]
    private let policy:AgentExecutionPreferences
    private var smooth:Bool {policy.mode != .compatibility}
    private let environment:AgentRunEnvironment
    private let continuation:AgentContinuedExecution?
    private let command:Command
    private let onPause:()->Void
    private let onResume:() async throws ->Void
    private let onExpiration:()->Void
    private var monitor:Task<Void,Never>?
    private var returning:Task<Void,Error>?
    private var pausing:Task<Void,Error>?
    private var operating=false
    private var expired=false
    private var closed=false
    private var screenGeneration=0
    private var snapshots:[String:Int]=[:]
    private var counts:[String:Int]=["commands":0,"per_command_returns":0,"background_commands":0,"budget_returns":0,"interaction_returns":0,"final_returns":0]
    init(policy:AgentExecutionPreferences,environment:AgentRunEnvironment?=nil,continuation:AgentContinuedExecution?=nil,onPause:@escaping ()->Void={},onResume:@escaping () async throws ->Void={},onExpiration:@escaping ()->Void={},command:@escaping Command) {
        self.policy=policy;self.environment=environment ?? UIKitAgentRunEnvironment();self.command=command
        self.continuation=continuation ?? (environment == nil && policy.mode == .background ? makeAgentContinuedExecution() : nil)
        self.onPause=onPause;self.onResume=onResume;self.onExpiration=onExpiration
    }
    convenience init(smooth:Bool,environment:AgentRunEnvironment?=nil,command:@escaping Command) {
        self.init(policy:.init(mode:smooth ? .continuous : .compatibility,returnAfterTask:true),environment:environment,command:command)
    }
    func start() async {
        if smooth {beginLease()}
        if policy.mode == .background,let continuation {
            await continuation.start { [weak self] in self?.expire() }
            if continuation.active {environment.end()}
        }
        saveDiagnostics()
        monitor=Task { [weak self] in
            while !Task.isCancelled {
                do {try await Task.sleep(nanoseconds:1_000_000_000)} catch {return}
                guard let self,!self.closed else {return}
                if self.needsBudgetHandling,!self.operating {
                    do {try await self.handleLowBudget()}
                    catch is CancellationError {return}
                    catch {if !self.closed {self.expire()}}
                }
            }
        }
    }
    private func beginLease() {
        environment.begin { [weak self] in
            guard let self else {return}
            self.expire()
        }
    }
    private var needsBudgetHandling:Bool {smooth && continuation?.active != true && !environment.foreground && environment.remaining<12}
    private func expire() {
        guard !closed,!expired else {return}
        expired=true;environment.end();onExpiration();saveDiagnostics()
    }
    private func handleLowBudget() async throws {
        if policy.mode == .background {try await pauseUntilForeground()}
        else {try await bringToMika(reason:"budget_returns")}
    }
    private func pauseUntilForeground() async throws {
        if let pausing {try await waitForPause(pausing);return}
        let wait=Task { @MainActor in
            self.onPause();self.environment.end();self.saveDiagnostics()
            while !self.environment.foreground {
                try Task.checkCancellation()
                guard !self.closed,!self.expired else {throw CancellationError()}
                try await Task.sleep(nanoseconds:100_000_000)
            }
            try Task.checkCancellation()
            guard !self.closed,!self.expired else {throw CancellationError()}
            self.beginLease();self.screenGeneration+=1
            try await self.onResume()
        }
        pausing=wait
        defer {pausing=nil;saveDiagnostics()}
        try await waitForPause(wait)
    }
    private func waitForPause(_ task:Task<Void,Error>) async throws {
        try await withTaskCancellationHandler {try await task.value} onCancel: {task.cancel()}
    }
    func prepare() async throws {
        try Task.checkCancellation()
        guard !expired,!closed else {throw Model.Issue.message("系统后台时间已结束，后续操作已停止。请返回 Mika 核对结果后再继续。")}
        if let returning {try await returning.value}
        if let pausing {try await waitForPause(pausing)}
        if needsBudgetHandling {try await handleLowBudget()}
        guard !expired else {throw Model.Issue.message("系统后台时间已结束，未派发后续手机操作。")}
    }
    func execute(_ args:[String:Any]) async throws -> [String:Any] {
        try await prepare()
        let action=args["action"] as? String ?? ""
        let bundle=args["bundle_id"] as? String ?? ""
        if screenGeneration>0,["tap","type","swipe"].contains(action),snapshots[bundle] != screenGeneration {
            return ["applied":false,"requires_fresh_screen":true,"note":"暂停或本人交接后，旧画面与坐标已过期。本步没有执行；请重新读屏，再决定是否操作。"]
        }
        operating=true
        defer {operating=false;saveDiagnostics()}
        counts["commands",default:0]+=1
        if !smooth {counts["per_command_returns",default:0]+=1}
        let result=try await command(args,!smooth)
        if action=="source",result["elements"] as? [[String:Any]] != nil {snapshots[bundle]=screenGeneration}
        if !environment.foreground {counts["background_commands",default:0]+=1}
        // A response after expiration cannot authorize another action or imply success.
        guard !expired else {throw Model.Issue.message("系统后台时间结束；本步结果请在手机核对，后续操作已停止，不会自动重试。")}
        return result
    }
    func showInteraction() async throws {
        try await prepare()
        screenGeneration+=1
        if !environment.foreground {try await bringToMika(reason:"interaction_returns")}
    }
    private func bringToMika(reason:String) async throws {
        if let returning {try await returning.value;return}
        guard !environment.foreground else {return}
        let request=Task { @MainActor in
            _ = try await self.command(["action":"return"],false)
            for _ in 0..<50 {
                if self.environment.foreground {
                    self.counts[reason,default:0]+=1
                    self.screenGeneration+=1
                    if self.smooth,self.continuation?.active != true,!self.closed,!self.expired {self.beginLease()}
                    self.saveDiagnostics();return
                }
                try await Task.sleep(nanoseconds:100_000_000)
            }
            throw Model.Issue.message("未确认 Mika 已回到前台，后续操作已停止。")
        }
        returning=request
        defer {returning=nil}
        try await request.value
    }
    func advance(round:Int) {continuation?.advance(round:round)}
    func finish(success:Bool=true) async {
        closed=true
        monitor?.cancel();monitor=nil
        pausing?.cancel()
        if let returning {_ = try? await returning.value}
        if policy.returnAfterTask,!environment.foreground {_ = try? await bringToMika(reason:"final_returns")}
        continuation?.finish(success:success && !expired)
        environment.end();saveDiagnostics()
    }
    private func saveDiagnostics() {
        #if DEBUG
        let value:[String:Any]=["mode":policy.mode.rawValue,"return_after_task":policy.returnAfterTask,"continuous":smooth,"continued_execution":continuation?.status ?? "unsupported","paused":pausing != nil,"screen_generation":screenGeneration,"counts":counts,"expired":expired,"closed":closed,"timestamp":ISO8601DateFormatter().string(from:Date())]
        let path=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("LocalPresentationDiagnostics.json")
        if let data=try? JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]) {try? data.write(to:path,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])}
        #endif
    }
}
