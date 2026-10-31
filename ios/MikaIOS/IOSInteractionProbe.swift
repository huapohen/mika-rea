import Foundation

#if DEBUG
extension RemoteIOSReceiver {
    /// Explicit read-only development scenario: taps the real owner UI using the
    /// phone's existing runner; never runs for an ordinary remote-assistance session.
    func runOwnerUIProbeIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("--mika-owner-handoff-ui-probe") else {return}
        let file=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("IOSOwnerHandoffAcceptance.json")
        try? FileManager.default.removeItem(at:file)
        var evidence:[String:Any]=["automated_owner_ui_test":true,"success":false]
        do {
            var found:IOSReceivedTask?
            for _ in 0..<90 {
                try Task.checkCancellation()
                if let task=activeTask,task.interaction?.kind == .handoff,task.interaction?.prompt=="MIKA_OWNER_UI_ACCEPTANCE" {found=task;break}
                try await Task.sleep(nanoseconds:1_000_000_000)
            }
            guard let task=found,let item=task.interaction,item.bundleID=="com.nebula.clashmi" else {throw IOSReceiverTasks.ReceiverIssue("未收到指定的只读本人操作测试")}
            let capsule=MikaCapsuleCoordinator.shared
            capsule.expanded=false;capsule.expand()
            try await Task.sleep(nanoseconds:500_000_000)
            let control=OnDeviceControl.shared
            _ = try await control.execute(["action":"tap","bundle_id":"com.huapohen.mikaremote","label":"打开目标 App，交给我操作"],returnToMika:false)
            try await Task.sleep(nanoseconds:500_000_000)
            let screen=try await control.execute(["action":"source","bundle_id":"com.nebula.clashmi"])
            guard (screen["elements"] as? [[String:Any]])?.isEmpty==false,activeTask?.interaction?.id==item.id else {throw IOSReceiverTasks.ReceiverIssue("本人步骤等待状态或实际目标界面未确认")}
            evidence["manual_target_screen_read"]=true;evidence["opening_app_did_not_answer"]=true
            // Let the separate controller render waiting_on_phone before this
            // automated owner fixture returns control. Ordinary sessions have no timer.
            try await Task.sleep(nanoseconds:3_000_000_000)
            _ = try await control.execute(["action":"tap","bundle_id":"com.huapohen.mikaremote","label":"我已处理，继续核实"])
            evidence["owner_continue_button_tapped"]=true;evidence["success"]=true
            capsule.expanded=false
        } catch {evidence["error"]=error.localizedDescription}
        evidence["timestamp"]=ISO8601DateFormatter().string(from:Date())
        if let data=try? JSONSerialization.data(withJSONObject:evidence,options:[.sortedKeys]) {try? data.write(to:file,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])}
    }
}
#endif
