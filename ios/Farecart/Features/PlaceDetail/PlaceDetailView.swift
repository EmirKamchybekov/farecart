import SwiftUI
import UIKit
import FarecartKit

/// Which half of the place screen is showing.
enum PlaceDetailTab: String, CaseIterable, Identifiable {
    case info
    case directions

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .info: "Info"
        case .directions: "Directions"
        }
    }

    var symbolName: String {
        switch self {
        case .info: "info.circle"
        case .directions: "bus.fill"
        }
    }
}

/// Find Food → row → this. A compact hero, then **Info** (address, hours, what to bring) and
/// **Directions** (the in-app CTA route with its cost) behind a segmented picker. Each tab has one
/// sticky primary action at the bottom.
struct PlaceDetailView: View {
    let place: Place
    /// Where the Find Food tab is searching from; the in-app route starts here.
    var origin: GeoPoint? = nil
    var originLabel: String = ""
    var initialTab: PlaceDetailTab = .info
    @State private var tab: PlaceDetailTab = .info
    @Environment(AppEnvironment.self) private var environment

    private static let bottomAnchor = "place-detail-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: Spacing.m) {
                    hero
                    picker
                    switch tab {
                    case .info:
                        PlaceInfoView(place: place)
                    case .directions:
                        RouteContent(request: routeRequest)
                    }
                }
                .padding(.horizontal, Spacing.m)
                .padding(.bottom, Spacing.m)
                .id(Self.bottomAnchor)
            }
            #if DEBUG
            .onAppear {
                // `-farecart-scroll-bottom` with `-farecart-open-place`: screenshot the footer above the bar.
                if ProcessInfo.processInfo.arguments.contains("-farecart-scroll-bottom") {
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(2))
                        withAnimation { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
                    }
                }
            }
            #endif
        }
        .scrollDismissesKeyboard(.immediately)
        .background(Color(.systemGroupedBackground))
        .navigationTitle(Text(verbatim: ""))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.hidden, for: .tabBar)
        // The bar is a safe-area inset, so the scroll content is inset by exactly its height and the
        // footer's last lines are reachable. Content still scrolls *under* the inset on iOS 26, so
        // the bar carries a toolbar-style backdrop that also covers the home-indicator area.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar
                .background(.bar, ignoresSafeAreaEdges: .bottom)
        }
        .onAppear { tab = initialTab }
    }

    // MARK: Hero

    private var hero: some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            PlaceIcon(place: place, size: 52)
            VStack(alignment: .leading, spacing: 6) {
                Text(place.name)
                    .font(.title3.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Spacing.xs) {
                        TypeBadge(type: place.type)
                        statusLine.lineLimit(1)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        TypeBadge(type: place.type)
                        statusLine
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, Spacing.xs)
        .accessibilityElement(children: .combine)
    }

    /// "1.3 mi · 25 min walk · Open now" on one line, in one `Text` so it wraps cleanly at large type.
    private var statusLine: some View {
        var parts: [Text] = []
        if let meters = place.distanceMeters {
            parts.append(Text(Distance.milesText(meters: meters)))
            parts.append(Text("\(Distance.walkingMinutes(meters: meters)) min walk"))
        }
        switch place.openStatus() {
        case .open: parts.append(Text("Open now").foregroundStyle(.green).bold())
        case .closed: parts.append(Text("Closed").foregroundStyle(.red).bold())
        case .unknown: break
        }
        let line = parts.dropFirst().reduce(parts.first ?? Text(verbatim: "")) { $0 + Text(verbatim: " · ") + $1 }
        return line
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    // MARK: Tabs

    private var picker: some View {
        Picker("Section", selection: $tab) {
            ForEach(PlaceDetailTab.allCases) { tab in
                Label(tab.title, systemImage: tab.symbolName).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.large)
        .accessibilityLabel("Info or Directions")
    }

    private var routeRequest: RouteRequest {
        RouteRequest(
            origin: origin ?? .westSideChicago,
            originLabel: originLabel.isEmpty ? String(localized: "West Side, Chicago") : originLabel,
            place: place
        )
    }

    @ViewBuilder
    private var bottomBar: some View {
        switch tab {
        case .info:
            Button {
                withAnimation(.snappy) { tab = .directions }
            } label: {
                BigButtonLabel(title: "Directions by CTA", systemImage: "bus.fill")
            }
            .buttonStyle(.glassProminent)
            .accessibilityHint("Shows bus and train directions with your fare")
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.xs)
        case .directions:
            MapsActionBar(place: place)
        }
    }
}

/// "Bus: $1.10 with your Access discount (instead of $2.25)" for each mode, from the fares table
/// and the saved Discounts answers. Shown when a trip could not be priced.
struct FareLineView: View {
    @Environment(AppEnvironment.self) private var environment
    @AppStorage(DiscountsKeys.householdSNAP) private var householdSNAP = false
    @AppStorage(DiscountsKeys.isStudent) private var isStudent = false

    private var answers: EligibilityAnswers {
        EligibilityAnswers(householdReceivesSNAP: householdSNAP, isK12Student: isStudent)
    }

    var body: some View {
        let store = environment.fareStore
        let quotes = store.calculator.quotes(answers: answers)
        VStack(alignment: .leading, spacing: Spacing.xs) {
            SectionCaption("Your fare")
            if quotes.isEmpty {
                Text("Fare prices are not available right now.")
                    .foregroundStyle(.secondary)
            }
            ForEach(quotes, id: \.mode) { quote in
                fareLine(quote)
            }
            if !answers.householdReceivesSNAP && !answers.isK12Student {
                Text("Get SNAP or go to school? Check the Discounts tab to see if you can ride for less.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if store.isUsingFallback {
                Text("Showing last known prices (offline).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .card()
        .task { await environment.fareStore.loadIfNeeded() }
    }

    @ViewBuilder
    private func fareLine(_ quote: FareQuote) -> some View {
        let modeName = Text(quote.mode.title)
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            Image(systemName: quote.mode.symbolName)
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            if quote.hasDiscount, let discounted = quote.discounted {
                let program = Text(programShortName(forKey: discounted.rider.programKey))
                let price = Text(quote.priceText()).bold()
                Text("\(modeName): \(price) with your \(program) discount (instead of \(quote.fullPriceText()))")
            } else {
                let price = Text(quote.priceText()).bold()
                Text("\(modeName): \(price) full fare")
            }
        }
        .font(.body)
        .accessibilityElement(children: .combine)
    }
}

#Preview("Grocery") {
    NavigationStack {
        PlaceDetailView(place: MockData.samplePlace)
    }
    .environment(AppEnvironment.preview())
}

#Preview("Pantry, unverified") {
    NavigationStack {
        PlaceDetailView(place: MockData.samplePantry)
    }
    .environment(AppEnvironment.preview())
}

#Preview("Directions") {
    NavigationStack {
        PlaceDetailView(place: MockData.samplePlace, originLabel: "Madison & Pulaski", initialTab: .directions)
    }
    .environment(AppEnvironment.preview())
}
