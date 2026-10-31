import Foundation

@MainActor protocol PhoneControlConnection:AnyObject {
    var requested:Bool {get}
    var ready:Bool {get}
    func ensureReadyIfRequested() async throws
}

enum PhoneControlResumePolicy {
    static func requested(saved:Bool?,hasPairing:Bool,hasPreviousSession:Bool)->Bool {
        saved ?? (hasPairing && hasPreviousSession)
    }
}

extension OnDeviceControl:PhoneControlConnection {
    func restoreIfRequested() {
        guard requested,!ready,!starting else {return}
        start()
    }
    func ensureReadyIfRequested() async throws {
        guard requested else {return}
        if ready {try await verifySessionAndReconnectIfNeeded();return}
        restoreIfRequested()
        for _ in 0..<125 {
            try Task.checkCancellation()
            if ready {return}
            if !starting {break}
            try await Task.sleep(nanoseconds:1_000_000_000)
        }
        throw Model.Issue.message("本机执行器未连接，本次没有执行手机操作。\(detail) 可在顶部点「重连」或进入设置 → 本机控制。")
    }
}
