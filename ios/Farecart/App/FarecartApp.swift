import SwiftUI
import FarecartKit

@main
struct FarecartApp: App {
    @State private var environment = AppEnvironment.live()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(environment)
                .task { await environment.fareStore.loadIfNeeded() }
        }
    }
}
