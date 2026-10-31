import Foundation

enum AgentExecutionMode:String,CaseIterable,Identifiable {
    case background,continuous,compatibility
    var id:String {rawValue}
    var label:String {
        switch self {case .background:return "后台运行";case .continuous:return "连续操作";case .compatibility:return "兼容模式"}
    }
}
struct AgentExecutionPreferences {
    var mode:AgentExecutionMode
    var returnAfterTask:Bool
    static func load(_ defaults:UserDefaults)->Self {
        let saved=defaults.string(forKey:"localExecutionMode").flatMap(AgentExecutionMode.init(rawValue:))
        let mode=saved ?? ((defaults.object(forKey:"localSmoothExecution") as? Bool)==false ? .compatibility : .background)
        return Self(mode:mode,returnAfterTask:defaults.object(forKey:"localReturnAfterTask") as? Bool ?? false)
    }
}
