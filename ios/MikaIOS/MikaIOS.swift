import SwiftUI
@main @MainActor struct MikaApp: App {
    init() {MikaLiveActions.stopHandler={id in try await MikaCapsuleCoordinator.shared.stop(id)}}
    var body: some Scene { WindowGroup { ContentView() } }
}
