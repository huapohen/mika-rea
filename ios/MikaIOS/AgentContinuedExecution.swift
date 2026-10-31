import UIKit
import BackgroundTasks

@MainActor protocol AgentContinuedExecution:AnyObject {
    var active:Bool {get}
    var status:String {get}
    func start(expiration:@escaping ()->Void) async
    func advance(round:Int)
    func finish(success:Bool)
}

@MainActor func makeAgentContinuedExecution()->AgentContinuedExecution? {
    if #available(iOS 26.0,*) {return SystemAgentContinuedExecution()}
    return nil
}

/// Explicitly foreground-initiated, immediate-or-fail work. Never queues phone
/// operations for an unspecified future launch, and requests CPU/network only.
@available(iOS 26.0,*) @MainActor private final class SystemAgentContinuedExecution:AgentContinuedExecution {
    private let identifier="com.huapohen.mikaremote.agent."+UUID().uuidString
    private var task:BGContinuedProcessingTask?
    private var closed=false
    private(set) var status="not_requested"
    var active:Bool {task != nil && !closed}
    func start(expiration:@escaping ()->Void) async {
        guard UIApplication.shared.applicationState == .active else {status="not_foreground";return}
        let registered=BGTaskScheduler.shared.register(forTaskWithIdentifier:identifier,using:.main) { [weak self] value in
            Task { @MainActor in
                guard let self,!self.closed,let task=value as? BGContinuedProcessingTask else {value.setTaskCompleted(success:false);return}
                self.task=task;self.status="running"
                task.progress.totalUnitCount=24
                task.progress.completedUnitCount=0
                task.expirationHandler={ [weak self] in
                    Task { @MainActor in
                        guard let self,!self.closed else {return}
                        self.status="expired";self.finish(success:false);expiration()
                    }
                }
            }
        }
        guard registered else {status="registration_rejected";return}
        let request=BGContinuedProcessingTaskRequest(identifier:identifier,title:"Mika 手机任务",subtitle:"正在开始处理")
        request.strategy = .fail
        do {try BGTaskScheduler.shared.submit(request)}
        catch {status="submission_failed_\((error as NSError).code)";closed=true;return}
        // A successful submit is not proof the system granted execution time.
        for _ in 0..<50 {
            if active || closed {return}
            do {try await Task.sleep(nanoseconds:100_000_000)} catch {finish(success:false);return}
        }
        status="launch_timeout";finish(success:false)
    }
    func advance(round:Int) {
        guard let task,active else {return}
        task.progress.completedUnitCount=Int64(min(round,23))
        task.updateTitle("Mika 手机任务",subtitle:"已完成 \(round) 轮处理")
    }
    func finish(success:Bool) {
        guard !closed else {return}
        closed=true
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier:identifier)
        if let task {
            if success {task.progress.completedUnitCount=task.progress.totalUnitCount}
            task.setTaskCompleted(success:success);self.task=nil
        }
        if status=="running" {status=success ? "completed" : "stopped"}
    }
}
