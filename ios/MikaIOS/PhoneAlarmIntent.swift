import AppIntents
import Foundation

/// A narrow system action, usable from Siri and Shortcuts without presenting chat.
/// This does not grant the agent access to other apps while the device is locked.
@available(iOS 26.0,*)
struct CreateMikaAlarmIntent:AppIntent {
    static var title:LocalizedStringResource="创建 Mika 闹钟"
    static var description=IntentDescription("在指定时间创建一次 Mika 系统闹钟，不需要电脑或 Wi-Fi。首次使用请在 Mika 中允许闹钟权限。")
    static var openAppWhenRun=false
    static var authenticationPolicy:IntentAuthenticationPolicy = .alwaysAllowed
    @Parameter(title:"响铃时间") var date:Date
    static var parameterSummary:some ParameterSummary {Summary("在 \(\.$date) 创建 Mika 闹钟")}
    @MainActor func perform() async throws ->some IntentResult & ProvidesDialog {
        let parts=Calendar.current.dateComponents([.hour,.minute],from:date)
        let plan=PhoneAlarmPlan(date:date,hour:parts.hour!,minute:parts.minute!)
        let record=try await PhoneAlarms.shared.create(plan,requestID:"shortcut-"+UUID().uuidString,mayRequestAuthorization:false)
        return .result(dialog:IntentDialog(stringLiteral:PhoneAlarms.shared.summary(record)))
    }
}

@available(iOS 26.0,*)
struct MikaAlarmShortcuts:AppShortcutsProvider {
    static var appShortcuts:[AppShortcut] {
        AppShortcut(intent:CreateMikaAlarmIntent(),phrases:["在 \(.applicationName) 创建闹钟","用 \(.applicationName) 设置闹钟"],shortTitle:"创建 Mika 闹钟",systemImageName:"alarm")
    }
}
