import SwiftUI
import FarecartKit

enum AppTab: Hashable {
    case find
    case discounts
    case search
}

/// Three tabs on the iOS 26 tab bar: Find Food (map), Discounts, and a search-role tab for addresses.
struct RootTabView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var selectedTab: AppTab = .find
    @State private var findModel: FindFoodModel?

    var body: some View {
        #if DEBUG
        if let request = DebugLaunch.routeRequest() {
            // Debug launch argument: show the route screen as the root, nothing else to tap through.
            NavigationStack { RouteView(request: request) }
        } else {
            tabs
        }
        #else
        tabs
        #endif
    }

    @ViewBuilder
    private var tabs: some View {
        if let findModel {
            TabView(selection: $selectedTab) {
                Tab("Find Food", systemImage: "basket.fill", value: .find) {
                    FindFoodView(model: findModel, selectedTab: $selectedTab)
                }
                Tab("Discounts", systemImage: "ticket.fill", value: .discounts) {
                    DiscountsView()
                }
                Tab(value: .search, role: .search) {
                    SearchTabView(model: findModel, selectedTab: $selectedTab)
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

#if DEBUG
/// `xcrun simctl launch <udid> org.farecart.app -farecart-open-route` opens RouteView straight away
/// (Madison & Pulaski → Pete's Fresh Market, Madison & Western) so the screen can be checked
/// without tapping through the app. Add `-answers.householdSNAP 1` to see the Access price.
enum DebugLaunch {
    static func routeRequest() -> RouteRequest? {
        guard ProcessInfo.processInfo.arguments.contains("-farecart-open-route") else { return nil }
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
}
