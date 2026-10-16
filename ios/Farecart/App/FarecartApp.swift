import SwiftUI
import FarecartKit

@main
struct FarecartApp: App {
    @State private var environment = AppEnvironment.live()

    init() {
        // Place logos load through AsyncImage → URLSession.shared → URLCache.shared. The default
        // cache is small; give it room so logos survive across launches.
        URLCache.shared = URLCache(memoryCapacity: 50 * 1024 * 1024, diskCapacity: 200 * 1024 * 1024)
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(environment)
                .task { await environment.fareStore.loadIfNeeded() }
        }
    }
}
