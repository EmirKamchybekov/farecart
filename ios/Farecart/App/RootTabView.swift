import SwiftUI
import CoreLocation
import FarecartKit

enum AppTab: Hashable {
    case find
    case discounts
    case settings
}

/// Onboarding on first launch, then the tabs.
struct RootView: View {
    @AppStorage(OnboardingKeys.done) private var onboardingDone = false

    var body: some View {
        #if DEBUG
        if let request = DebugLaunch.routeRequest() {
            // Debug launch argument: show the route screen as the root, nothing else to tap through.
            NavigationStack { RouteView(request: request) }
        } else {
            gate
        }
        #else
        gate
        #endif
    }

    @ViewBuilder
    private var gate: some View {
        if onboardingDone {
            RootTabView()
                .transition(.opacity)
        } else {
            OnboardingView()
                .transition(.move(edge: .leading).combined(with: .opacity))
        }
    }
}

/// Three tabs on the iOS 26 tab bar: Find Food (map + search), Discounts, Settings.
struct RootTabView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var selectedTab: AppTab = DebugLaunch.initialTab
    @State private var findModel: FindFoodModel?

    var body: some View {
        if let findModel {
            TabView(selection: $selectedTab) {
                Tab("Find Food", systemImage: "basket.fill", value: .find) {
                    FindFoodView(model: findModel)
                }
                Tab("Discounts", systemImage: "ticket.fill", value: .discounts) {
                    DiscountsView()
                }
                Tab("Settings", systemImage: "gearshape.fill", value: .settings) {
                    SettingsView()
                }
            }
            .tabBarMinimizeBehavior(.onScrollDown)
            .tint(.accentColor)
        } else {
            ProgressView()
                .task { findModel = FindFoodModel(environment: environment) }
        }
    }
}

#if !DEBUG
enum DebugLaunch {
    static var initialTab: AppTab { .find }
    static var onboardingPage: Int { 0 }
    static func applyOnboardingOverrides() {}
}
#else
/// Launch arguments for `xcrun simctl launch <udid> org.farecart.app …` (Debug builds only):
/// - `-farecart-open-route` opens RouteView straight away (Madison & Pulaski → Pete's Fresh Market);
///   add `-answers.householdSNAP 1` to see the Access price.
/// - `-farecart-reset-onboarding` shows the welcome screens again; any other `-farecart-…` argument
///   skips them so screenshots of inner screens never land on onboarding.
/// - `-farecart-tab discounts|settings` starts on that tab.
/// - `-farecart-reset-onboarding -farecart-onboarding-page 2` opens onboarding on that page (0–3).
/// - `-farecart-language es -farecart-theme dark` preset (and persist) the Settings values.
enum DebugLaunch {
    private static var arguments: [String] { ProcessInfo.processInfo.arguments }

    static var initialTab: AppTab {
        guard let index = arguments.firstIndex(of: "-farecart-tab"), index + 1 < arguments.count else { return .find }
        switch arguments[index + 1] {
        case "discounts": return .discounts
        case "settings": return .settings
        default: return .find
        }
    }

    static var onboardingPage: Int {
        guard let index = arguments.firstIndex(of: "-farecart-onboarding-page"), index + 1 < arguments.count else { return 0 }
        return min(max(Int(arguments[index + 1]) ?? 0, 0), 3)
    }

    static func applyOnboardingOverrides() {
        if let index = arguments.firstIndex(of: "-farecart-language"), index + 1 < arguments.count {
            UserDefaults.standard.set(arguments[index + 1], forKey: AppLanguage.storageKey)
        }
        if let index = arguments.firstIndex(of: "-farecart-theme"), index + 1 < arguments.count {
            UserDefaults.standard.set(arguments[index + 1], forKey: AppTheme.storageKey)
        }
        if arguments.contains("-farecart-reset-onboarding") {
            UserDefaults.standard.set(false, forKey: OnboardingKeys.done)
        } else if arguments.contains(where: { $0.hasPrefix("-farecart-") }) {
            UserDefaults.standard.set(true, forKey: OnboardingKeys.done)
        }
    }

    /// `-farecart-open-place` opens the first result; `-farecart-open-place-directions` lands on its Directions tab.
    static var placeDetailTab: PlaceDetailTab {
        arguments.contains("-farecart-open-place-directions") ? .directions : .info
    }

    static func routeRequest() -> RouteRequest? {
        guard arguments.contains("-farecart-open-route") else { return nil }
        let petes = Place(
            id: UUID(uuidString: "deb00000-0000-4000-8000-000000000001")!,
            name: "Pete's Fresh Market - Madison & Western",
            type: .grocery,
            address: "2333 W Madison St, Chicago, IL 60612",
            neighborhood: "Near West Side",
            latitude: 41.881089,
            longitude: -87.684793,
            hoursText: "Mon-Sun 7am-10pm",
            acceptsEBT: true,
            sourceURL: "https://www.petesfresh.com/stores"
        )
        return RouteRequest(origin: GeoPoint(latitude: 41.8807, longitude: -87.7262), originLabel: "Madison & Pulaski", place: petes)
    }
}
#endif

#Preview {
    RootTabView()
        .environment(AppEnvironment.preview())
        .environment(AccountModel())
}
