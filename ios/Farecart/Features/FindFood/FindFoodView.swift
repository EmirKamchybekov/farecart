import SwiftUI
import MapKit
import FarecartKit

/// Tab 1: map of nearby food with floating glass controls and a draggable results panel.
struct FindFoodView: View {
    @Environment(\.openURL) private var openURL
    @Bindable var model: FindFoodModel
    @Binding var selectedTab: AppTab
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                ZStack(alignment: .top) {
                    PlaceMap(model: model)
                        .ignoresSafeArea(edges: .bottom)

                    VStack(spacing: Spacing.s) {
                        originBar
                            .padding(.horizontal, Spacing.m)
                        FilterChipRow(selection: model.filter) { filter in Task { await model.setFilter(filter) } }
                        Group {
                            if let configurationError = environment.configurationError {
                                MessageBanner(text: String(localized: "Showing sample data: the app is missing its Supabase settings. \(configurationError)"))
                            } else if let error = model.errorMessage, model.locationDenied {
                                MessageBanner(text: error, systemImage: "location.slash.fill", actionTitle: "Open Settings") {
                                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                                }
                            } else if let error = model.errorMessage {
                                MessageBanner(text: error) { Task { await model.reload() } }
                            }
                        }
                        .padding(.horizontal, Spacing.m)
                    }
                    .padding(.top, Spacing.xs)

                    if model.isListPresented {
                        ResultsPanel(model: model, availableHeight: proxy.size.height - Spacing.xs)
                            .padding(.horizontal, Spacing.xs)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.snappy, value: model.isListPresented)
            }
            .navigationTitle("Find Food")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $model.selectedPlace) { place in
                #if DEBUG
                PlaceDetailView(place: place, origin: model.origin, originLabel: model.originLabel, initialTab: DebugLaunch.placeDetailTab)
                #else
                PlaceDetailView(place: place, origin: model.origin, originLabel: model.originLabel)
                #endif
            }
        }
        .task {
            #if DEBUG
            // `xcrun simctl launch <udid> org.farecart.app -farecart-use-location` taps "Use my location" on launch.
            if ProcessInfo.processInfo.arguments.contains("-farecart-use-location") {
                await model.useMyLocation()
            } else {
                await model.loadInitialIfNeeded()
            }
            // `-farecart-open-place` opens the first result's detail; `-farecart-open-place-directions`
            // lands on its Directions tab; `-farecart-open-place-far` picks the first result over a mile
            // away so the route is not walk-only.
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains(where: { $0.hasPrefix("-farecart-open-place") }) {
                let far = arguments.contains("-farecart-open-place-far")
                let place = far ? model.places.first { ($0.distanceMeters ?? 0) > 1800 } : model.places.first
                if let place {
                    // Let the panel finish appearing before pushing; a push during that transition is
                    // sometimes dropped.
                    try? await Task.sleep(for: .seconds(1.2))
                    model.select(place)
                }
            }
            #else
            await model.loadInitialIfNeeded()
            #endif
        }
    }

    /// "Where are you?" row: current origin + Use my location, floating over the map.
    private var originBar: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    selectedTab = .search
                } label: {
                    HStack {
                        Image(systemName: model.originIsCurrentLocation ? "location.fill" : "magnifyingglass")
                            .foregroundStyle(.secondary)
                        Text(model.originLabel.isEmpty ? String(localized: "Enter an address or neighborhood") : model.originLabel)
                            .lineLimit(1)
                            .foregroundStyle(model.originLabel.isEmpty ? .secondary : .primary)
                        Spacer(minLength: 0)
                    }
                    .font(.body)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Search address")
                .accessibilityValue(model.originLabel)

                Button {
                    Task { await model.useMyLocation() }
                } label: {
                    Group {
                        if model.isLocating {
                            ProgressView()
                        } else {
                            Image(systemName: "location.fill")
                        }
                    }
                    .font(.title3)
                    .frame(width: 24, height: 24)
                    .padding(10)
                }
                .buttonStyle(.glassProminent)
                .disabled(model.isLocating)
                .accessibilityLabel("Use my location")
            }
        }
    }
}

/// MapKit map with colored annotations per type.
struct PlaceMap: View {
    @Bindable var model: FindFoodModel

    var body: some View {
        Map(position: $model.cameraPosition) {
            UserAnnotation()
            if let origin = model.origin, !model.originIsCurrentLocation {
                Annotation(model.originLabel, coordinate: origin.clCoordinate) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.title)
                        .foregroundStyle(.white, .blue)
                        .accessibilityLabel("Search starting point")
                }
            }
            ForEach(model.places) { place in
                Annotation(place.name, coordinate: place.clCoordinate) {
                    Button {
                        model.select(place)
                    } label: {
                        PlacePin(type: place.type, selected: model.selectedPlace?.id == place.id)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("\(place.name), \(Text(place.type.title))"))
                }
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .mapControls {
            MapCompass()
            MapScaleView()
        }
    }
}

/// Floating glass chips: All / Grocery / Pantry / Giveaway. Full-bleed horizontal scroll with the
/// page margin as content inset, so a chip is never cut by the padding and the row still scrolls
/// at large text sizes.
struct FilterChipRow: View {
    let selection: PlaceFilter
    let onSelect: (PlaceFilter) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: Spacing.xs) {
                HStack(spacing: Spacing.xs) {
                    ForEach(PlaceFilter.allCases) { filter in
                        let isSelected = selection == filter
                        Button {
                            onSelect(filter)
                        } label: {
                            Label {
                                Text(filter.title)
                            } icon: {
                                Image(systemName: filter.symbolName)
                            }
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .padding(.horizontal, 2)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.glass)
                        .tint(isSelected ? filter.color : nil)
                        .foregroundStyle(isSelected ? filter.color : .primary)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .contentMargins(.horizontal, Spacing.m, for: .scrollContent)
        .scrollIndicators(.hidden)
        .accessibilityLabel("Filter by type")
    }
}

#Preview("Find Food") {
    @Previewable @State var tab: AppTab = .find
    let environment = AppEnvironment.preview()
    FindFoodView(model: FindFoodModel(environment: environment), selectedTab: $tab)
        .environment(environment)
}

#Preview("Error") {
    @Previewable @State var tab: AppTab = .find
    let environment = AppEnvironment.preview(failure: APIError.invalidResponse)
    FindFoodView(model: FindFoodModel(environment: environment), selectedTab: $tab)
        .environment(environment)
}
