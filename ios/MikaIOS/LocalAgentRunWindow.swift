import UIKit

@MainActor protocol AgentRunEnvironment:AnyObject {
    var foreground:Bool {get}
    var remaining:TimeInterval {get}
    func begin(_ expiration:@escaping ()->Void)
    func end()
}

@MainActor private final class UIKitAgentRunEnvironment:AgentRunEnvironment {
    private var identifier:UIBackgroundTaskIdentifier = .invalid
    var foreground:Bool {UIApplication.shared.applicationState == .active}
    var remaining:TimeInterval {UIApplication.shared.backgroundTimeRemaining}
    func begin(_ expiration:@escaping ()->Void) {
        end()
        identifier=UIApplication.shared.beginBackgroundTask(withName:"Mika 连续手机任务",expirationHandler:expiration)
    }
    func end() {
        if identifier != .invalid {UIApplication.shared.endBackgroundTask(identifier);identifier = .invalid}
    }
}

/// One finite background assertion spans model requests and UI operations.
/// The OS budget is monitored; repeated assertions never imply unlimited runtime.
@MainActor final class LocalAgentRunWindow {
    typealias Command=([String:Any],Bool) async throws -> [String:Any]
    private let smooth:Bool
    private let environment:AgentRunEnvironment
    private let command:Command
    private var monitor:Task<Void,Never>?
    private var returning:Task<Void,Error>?
    private var operating=false
    private var expired=false
    private var closed=false
    private var counts:[String:Int]=["commands":0,"per_command_returns":0,"background_commands":0,"budget_returns":0,"interaction_returns":0,"final_returns":0]
    init(smooth:Bool,environment:AgentRunEnvironment?=nil,command:@escaping Command) {
        self.smooth=smooth;self.environment=environment ?? UIKitAgentRunEnvironment();self.command=command
    }
    func start() {
        if smooth {beginLease()}
        saveDiagnostics()
        monitor=Task { [weak self] in
            while !Task.isCancelled {
                do {try await Task.sleep(nanoseconds:1_000_000_000)} catch {return}
                guard let self,!self.closed else {return}
                if self.smooth,!self.operating,!self.environment.foreground,self.environment.remaining<12 {
                    do {try await self.bringToMika(reason:"budget_returns")} catch {self.expired=true;self.saveDiagnostics()}
                }
            }
        }
    }
    private func beginLease() {
        environment.begin { [weak self] in
            guard let self else {return}
            self.expired=true;self.environment.end();self.saveDiagnostics()
        }
    }
    func prepare() async throws {
        try Task.checkCancellation()
        guard !expired,!closed else {throw Model.Issue.message("系统后台时间已结束，后续操作已停止。请返回 Mika 核对结果后再继续。")}
        if let returning {try await returning.value}
        if smooth,!environment.foreground,environment.remaining<12 {try await bringToMika(reason:"budget_returns")}
        guard !expired else {throw Model.Issue.message("系统后台时间已结束，未派发后续手机操作。")}
    }
    func execute(_ args:[String:Any]) async throws -> [String:Any] {
        try await prepare()
        operating=true
        defer {operating=false;saveDiagnostics()}
        counts["commands",default:0]+=1
        if !smooth {counts["per_command_returns",default:0]+=1}
        let result=try await command(args,!smooth)
        if !environment.foreground {counts["background_commands",default:0]+=1}
        // A response after expiration cannot authorize another action or imply success.
        guard !expired else {throw Model.Issue.message("系统后台时间结束；本步结果请在手机核对，后续操作已停止，不会自动重试。")}
        return result
    }
    func showInteraction() async throws {
        try await prepare()
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
                    if self.smooth,!self.closed,!self.expired {self.beginLease()}
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
    func finish() async {
        monitor?.cancel();monitor=nil
        if let returning {_ = try? await returning.value}
        // Finish/cancel/error brings the user back once, never after every tool.
        if !environment.foreground {_ = try? await bringToMika(reason:"final_returns")}
        closed=true;environment.end();saveDiagnostics()
    }
    private func saveDiagnostics() {
        #if DEBUG
        let value:[String:Any]=["continuous":smooth,"counts":counts,"expired":expired,"closed":closed,"timestamp":ISO8601DateFormatter().string(from:Date())]
        let path=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("LocalPresentationDiagnostics.json")
        if let data=try? JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]) {try? data.write(to:path,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])}
        #endif
    }
}
