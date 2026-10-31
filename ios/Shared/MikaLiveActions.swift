import AppIntents
import Foundation

@MainActor enum MikaLiveActions {
    static var stopHandler:((String) async throws -> Void)?
    static func stop(_ id:String) async throws {
        guard !id.isEmpty,let handler=stopHandler else {throw ActionError.unavailable}
        try await handler(id)
    }
    enum ActionError:LocalizedError {case unavailable;var errorDescription:String? {"请打开 Mika 查看任务状态。"}}
}

@available(iOS 17.0, *)
struct StopMikaTaskIntent:LiveActivityIntent {
    static var title:LocalizedStringResource="停止 Mika 任务"
    static var isDiscoverable:Bool=false
    static var openAppWhenRun:Bool=false
    @Parameter(title:"任务编号") var operationID:String
    init() {operationID=""}
    init(operationID:String) {self.operationID=operationID}
    func perform() async throws -> some IntentResult {
        // LiveActivityIntent runs in the app process. The app installs this handler
        // at startup, including when launched in the background for an intent.
        try await MikaLiveActions.stop(operationID)
        return .result()
    }
}
