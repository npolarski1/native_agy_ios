import AntigravityCore
import SwiftUI

@main
struct AntigravityMonitorApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = MonitorStore()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(store)
                .onOpenURL { url in
                    store.handleDeepLink(url)
                }
                .task {
                    store.start()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        Task {
                            await store.refreshAll()
                        }
                    }
                }
        }
    }
}
