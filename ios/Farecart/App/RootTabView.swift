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

#Preview {
    RootTabView()
        .environment(AppEnvironment.preview())
}
