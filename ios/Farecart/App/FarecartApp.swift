import SwiftUI
import FarecartKit

@main
struct FarecartApp: App {
    @State private var environment = AppEnvironment.live()
    @State private var account = AccountModel()
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.system.rawValue
    @AppStorage(AppTheme.storageKey) private var themeCode = AppTheme.system.rawValue

    init() {
        // Place logos load through AsyncImage → URLSession.shared → URLCache.shared. The default
        // cache is small; give it room so logos survive across launches.
        URLCache.shared = URLCache(memoryCapacity: 50 * 1024 * 1024, diskCapacity: 200 * 1024 * 1024)
        DebugLaunch.applyOnboardingOverrides()
    }

    private var language: AppLanguage { AppLanguage(rawValue: languageCode) ?? .system }
    private var theme: AppTheme { AppTheme(rawValue: themeCode) ?? .system }

    var body: some Scene {
        WindowGroup {
            RootView()
                // Animated splash over the root on cold launch; the main UI loads beneath it.
                .launchSplash()
                .environment(environment)
                .environment(account)
                // Language and theme apply instantly: SwiftUI text re-resolves against this locale,
                // and `LanguageBundle.current` covers the few `String(localized:)` call sites.
                .environment(\.locale, language.locale ?? .current)
                .transformEnvironment(\.layoutDirection) { direction in
                    if let override = language.layoutDirection { direction = override }
                }
                .preferredColorScheme(theme.colorScheme)
                .task { await environment.fareStore.loadIfNeeded() }
                .task { await account.restore(environment: environment) }
                // farecart://auth-callback opened outside the web authentication session.
                .onOpenURL { url in Task { await account.handleOpenURL(url) } }
        }
    }
}
