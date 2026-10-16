import SwiftUI
import MapKit
import FarecartKit

/// Tab 1: map of nearby food with floating glass controls and a draggable results sheet.
struct FindFoodView: View {
    @Bindable var model: FindFoodModel
    @Binding var selectedTab: AppTab
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                PlaceMap(model: model)
                    .ignoresSafeArea(edges: .bottom)

                VStack(spacing: 12) {
                    originBar
                    FilterChipRow(selection: model.filter) { filter in Task { await model.setFilter(filter) } }
                    if let configurationError = environment.configurationError {
                        MessageBanner(text: String(localized: "Showing sample data: the app is missing its Supabase settings. \(configurationError)"))
                    } else if let error = model.errorMessage {
                        MessageBanner(text: error) { Task { await model.reload() } }
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }
            .navigationTitle("Find Food")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $model.isListPresented) {
                ResultsSheet(model: model)
                    .presentationDetents([.height(120), .medium, .large])
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                    .presentationDragIndicator(.visible)
                    .presentationCornerRadius(28)
            }
            .overlay(alignment: .bottomTrailing) {
                if !model.isListPresented && model.hasSearchedOnce {
                    Button {
                        model.isListPresented = true
                    } label: {
                        Label("Show list (\(model.places.count))", systemImage: "list.bullet")
                            .font(.headline)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.glassProminent)
                    .padding()
                    .accessibilityHint("Opens the list of nearby places")
                }
            }
        }
        .task { await model.loadInitialIfNeeded() }
        .onChange(of: selectedTab) { _, tab in
            if tab == .find {
                if model.hasSearchedOnce { model.isListPresented = true }
            } else {
                model.isListPresented = false
            }
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

/// Floating glass chips: All / Grocery / Pantry / Giveaway.
struct FilterChipRow: View {
    let selection: PlaceFilter
    let onSelect: (PlaceFilter) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
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
                                .padding(.horizontal, 4)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.glass)
                        .tint(isSelected ? filter.color : nil)
                        .foregroundStyle(isSelected ? filter.color : .primary)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
            }
            .padding(.horizontal, 2)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
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
