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
    @AppStorage(OnboardingKeys.needsSignIn) private var needsSignIn = false
    @Environment(AccountModel.self) private var account

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
        if onboardingDone && !account.isSignedIn {
            // An account is required: anyone signed out sees the account screen (language, role and theme stay).
            AccountGateView()
                .transition(.opacity)
        } else if onboardingDone {
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
            .task {
                // Pantry staff land on their staff screen (Settings → Pantry staff) on launch.
                guard StaffLanding.shouldLand(environment: environment) else { return }
                StaffLanding.pending = true
                selectedTab = .settings
            }
        } else {
            ProgressView()
                .task { findModel = FindFoodModel(environment: environment) }
        }
    }
}

/// Once per launch, a staff user (role `staff` with a saved staff session) starts on Settings with
/// the staff screen pushed instead of hunting for it.
@MainActor
enum StaffLanding {
    private static var decided = false
    /// Set by `RootTabView`, consumed by `SettingsView`.
    static var pending = false

    static func shouldLand(environment: AppEnvironment) -> Bool {
        guard !decided else { return false }
        decided = true
        let role = UserDefaults.standard.string(forKey: UserRole.storageKey)
        return role == UserRole.staff.rawValue && environment.pantry.staffSession != nil && !DebugLaunch.hasTabOverride
    }

    static func consume() -> Bool {
        defer { pending = false }
        return pending
    }
}

#if !DEBUG
enum DebugLaunch {
    static var initialTab: AppTab { .find }
    static var settingsRoutes: [SettingsRoute] { [] }
    static var onboardingPage: Int { 0 }
    static var splashHold: Bool { false }
    static var splashSpeedFactor: Double { 1 }
    static func applyOnboardingOverrides() {}
    static var hasTabOverride: Bool { false }
    static var authPrefill: (name: String, email: String, password: String) { ("", "", "") }
    static var showPassword: Bool { false }
    static var confirmDeleteAccount: Bool { false }
}
#else
/// Launch arguments for `xcrun simctl launch <udid> org.farecart.app …` (Debug builds only):
/// - `-farecart-open-route` opens RouteView straight away (Madison & Pulaski → Pete's Fresh Market);
///   add `-answers.householdSNAP 1` to see the Access price.
/// - `-farecart-reset-onboarding` shows the welcome screens again; any other `-farecart-…` argument
///   skips them so screenshots of inner screens never land on onboarding.
/// - `-farecart-tab discounts|settings` starts on that tab.
/// - `-farecart-reset-onboarding -farecart-onboarding-page 2` opens onboarding on that page (0–5);
///   `-farecart-role staff|client` presets the "How will you use Farecart?" answer.
/// - Accounts: `-farecart-open-signup` / `-farecart-open-signin` open the email sheet (onboarding's
///   account page or Settings), `-farecart-auth-name|email|password <value>` prefill it,
///   `-farecart-auth-submit` presses its button, `-farecart-show-password` starts unmasked,
///   `-farecart-sign-out` signs out at launch, `-farecart-open-delete-account` pushes Delete
///   account and `-farecart-confirm-delete-account` confirms it (deletes for real).
/// - `-farecart-language es -farecart-theme dark` preset (and persist) the Settings values.
/// - `-farecart-splash-hold` keeps the launch splash on screen at its final frame;
///   `-farecart-splash-slow` plays the splash at a quarter of its speed.
/// - Pantry: `-farecart-open-visits` / `-farecart-open-staff` push those Settings screens;
///   `-farecart-staff-code A7GBQZ` signs in to staff mode; `-farecart-open-booking` /
///   `-farecart-book-first-slot` open (and confirm) the booking sheet on an opened pantry;
///   `-farecart-cancel-first-visit`, `-farecart-staff-cycle produce`, `-farecart-staff-add-slot`,
///   `-farecart-staff-arrive-first` drive the other steps.
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

    /// `-farecart-open-visits` → Your visits; `-farecart-open-staff` (or `-farecart-staff-code X`) → staff mode.
    static var settingsRoutes: [SettingsRoute] {
        if arguments.contains("-farecart-open-visits") { return [.visits] }
        if arguments.contains("-farecart-open-delete-account") { return [.deleteAccount] }
        if arguments.contains("-farecart-open-staff") || arguments.contains("-farecart-staff-code") { return [.staff] }
        return []
    }

    static var onboardingPage: Int {
        guard let index = arguments.firstIndex(of: "-farecart-onboarding-page"), index + 1 < arguments.count else { return 0 }
        return min(max(Int(arguments[index + 1]) ?? 0, 0), 5)
    }

    /// `-farecart-tab …` given: don't move a staff user to Settings on launch.
    static var hasTabOverride: Bool { arguments.contains("-farecart-tab") }

    private static func value(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    static var authPrefill: (name: String, email: String, password: String) {
        (value(after: "-farecart-auth-name") ?? "", value(after: "-farecart-auth-email") ?? "", value(after: "-farecart-auth-password") ?? "")
    }
    static var authSubmit: Bool { arguments.contains("-farecart-auth-submit") }
    static var showPassword: Bool { arguments.contains("-farecart-show-password") }
    static var signOutAtLaunch: Bool { arguments.contains("-farecart-sign-out") }
    static var confirmDeleteAccount: Bool { arguments.contains("-farecart-confirm-delete-account") }

    @MainActor private static var authSheetConsumed = false
    /// The email sheet to open once (`-farecart-open-signup` / `-farecart-open-signin`).
    @MainActor static func consumeAuthSheet() -> EmailSheet? {
        guard !authSheetConsumed else { return nil }
        let kind: EmailSheet? = arguments.contains("-farecart-open-signup") ? .signUp : arguments.contains("-farecart-open-signin") ? .signIn : nil
        if kind != nil { authSheetConsumed = true }
        return kind
    }

    /// `-farecart-splash-hold`: the splash animates in and then stays (screenshots).
    static var splashHold: Bool { arguments.contains("-farecart-splash-hold") }

    /// Multiplier for every splash duration: 4 with `-farecart-splash-slow`.
    static var splashSpeedFactor: Double { arguments.contains("-farecart-splash-slow") ? 4 : 1 }

    static func applyOnboardingOverrides() {
        if let index = arguments.firstIndex(of: "-farecart-language"), index + 1 < arguments.count {
            UserDefaults.standard.set(arguments[index + 1], forKey: AppLanguage.storageKey)
        }
        if let index = arguments.firstIndex(of: "-farecart-theme"), index + 1 < arguments.count {
            UserDefaults.standard.set(arguments[index + 1], forKey: AppTheme.storageKey)
        }
        if arguments.contains("-farecart-reset-onboarding") {
            UserDefaults.standard.set(false, forKey: OnboardingKeys.done)
            UserDefaults.standard.set(false, forKey: OnboardingKeys.needsSignIn)
            UserDefaults.standard.removeObject(forKey: UserRole.storageKey)
        } else if arguments.contains(where: { $0.hasPrefix("-farecart-") }) {
            UserDefaults.standard.set(true, forKey: OnboardingKeys.done)
        }
        if let role = value(after: "-farecart-role"), UserRole(rawValue: role) != nil {
            UserDefaults.standard.set(role, forKey: UserRole.storageKey)
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
