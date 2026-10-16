import SwiftUI
import MapKit
import FarecartKit

/// Tab 1: map of nearby food with a glass search field on top (address or current location),
/// filter chips, suggestions while typing, and a draggable results panel.
struct FindFoodView: View {
    @Environment(\.openURL) private var openURL
    @Bindable var model: FindFoodModel
    @Environment(AppEnvironment.self) private var environment
    @FocusState private var searchFocused: Bool
    @Environment(\.locale) private var locale

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                ZStack(alignment: .top) {
                    PlaceMap(model: model)
                        .ignoresSafeArea(edges: .bottom)

                    if model.isEditingSearch {
                        // Tap anywhere on the map to stop editing.
                        Color.black.opacity(0.08)
                            .ignoresSafeArea()
                            .onTapGesture { searchFocused = false }
                            .transition(.opacity)
                    }

                    VStack(spacing: Spacing.s) {
                        OriginSearchField(model: model, isFocused: $searchFocused)
                            .padding(.horizontal, Spacing.m)
                        if model.isEditingSearch {
                            SearchSuggestions(model: model) { searchFocused = false }
                                .padding(.horizontal, Spacing.m)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        } else {
                            FilterChipRow(selection: model.filter) { filter in Task { await model.setFilter(filter) } }
                        }
                        Group {
                            if let configurationError = environment.configurationError {
                                MessageBanner(text: String(localized: "Showing sample data: the app is missing its Supabase settings. \(configurationError)", bundle: LanguageBundle.current))
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

                    if model.isListPresented && !model.isEditingSearch {
                        ResultsPanel(model: model, availableHeight: proxy.size.height - Spacing.xs)
                            .padding(.horizontal, Spacing.xs)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.snappy, value: model.isListPresented)
                .animation(.snappy, value: model.isEditingSearch)
            }
            .navigationTitle("Find Food")
            .toolbarVisibility(.hidden, for: .navigationBar)
            .navigationDestination(item: $model.selectedPlace) { place in
                #if DEBUG
                PlaceDetailView(place: place, origin: model.origin, originLabel: model.originLabel, initialTab: DebugLaunch.placeDetailTab)
                #else
                PlaceDetailView(place: place, origin: model.origin, originLabel: model.originLabel)
                #endif
            }
            .visitDestinations()
        }
        .onChange(of: searchFocused) { _, focused in
            if focused { model.beginEditingSearch() } else if model.isEditingSearch { model.endEditingSearch() }
        }
        .onChange(of: model.isEditingSearch) { _, editing in
            if !editing { searchFocused = false }
        }
        .onChange(of: locale) { model.refreshLocalizedLabels() }
        .task { await environment.pantry.loadVisitsIfNeeded() }
        .task {
            #if DEBUG
            // `xcrun simctl launch <udid> org.farecart.app -farecart-use-location` taps "Use my location" on launch.
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("-farecart-use-location") {
                await model.useMyLocation()
            } else {
                await model.loadInitialIfNeeded()
            }
            // `-farecart-search Austin` focuses the field with that text so suggestions show.
            if let index = arguments.firstIndex(of: "-farecart-search"), index + 1 < arguments.count {
                try? await Task.sleep(for: .seconds(1))
                searchFocused = true
                try? await Task.sleep(for: .milliseconds(300))
                model.searchText = arguments[index + 1]
            }
            // `-farecart-open-place` opens the first result's detail; `-farecart-open-place-directions`
            // lands on its Directions tab; `-farecart-open-place-far` picks the first result over a mile
            // away so the route is not walk-only; `-farecart-open-place-named Jewel` picks the first
            // result whose name contains that text.
            if arguments.contains(where: { $0.hasPrefix("-farecart-open-place") }) {
                let far = arguments.contains("-farecart-open-place-far")
                let named = arguments.firstIndex(of: "-farecart-open-place-named")
                    .flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
                let place: Place?
                if let named {
                    place = model.places.first { $0.name.localizedCaseInsensitiveContains(named) }
                } else {
                    place = far ? model.places.first { ($0.distanceMeters ?? 0) > 1800 } : model.places.first
                }
                if let place {
                    // Let the panel finish appearing before pushing; a push during that transition is
                    // sometimes dropped.
                    try? await Task.sleep(for: .seconds(2))
                    model.select(place)
                }
            }
            #else
            await model.loadInitialIfNeeded()
            #endif
        }
    }
}

/// Glass search field: shows the current origin when idle, the typed text while editing, and a
/// location-arrow button for "Use my location".
struct OriginSearchField: View {
    @Bindable var model: FindFoodModel
    @FocusState.Binding var isFocused: Bool

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: !model.isEditingSearch && model.originIsCurrentLocation ? "location.fill" : "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(text: $model.searchText, prompt: Text("Address, neighborhood or ZIP")) {
                Text("Search address")
            }
            .focused($isFocused)
            .textInputAutocapitalization(.words)
            .autocorrectionDisabled()
            .submitLabel(.search)
            .onSubmit {
                Task { await model.searchAndUseFirstMatch() }
            }
            .task(id: model.searchText) {
                // Debounced suggestions while typing.
                guard model.isEditingSearch, !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                await model.geocode()
            }
            if model.isEditingSearch && !model.searchText.isEmpty {
                Button {
                    model.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
            Divider().frame(height: 22)
            Button {
                isFocused = false
                Task { await model.useMyLocation() }
            } label: {
                Group {
                    if model.isLocating {
                        ProgressView()
                    } else {
                        Image(systemName: "location.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                    }
                }
                .font(.title2)
                .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .disabled(model.isLocating)
            .accessibilityLabel("Use my location")
        }
        .font(.body)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glassEffect(.regular.interactive(), in: Capsule())
        .accessibilityElement(children: .contain)
    }
}

/// Dropdown under the search field: geocoder matches for what was typed, or neighborhoods and
/// "Use my location" when nothing has been typed yet.
struct SearchSuggestions: View {
    @Bindable var model: FindFoodModel
    let dismiss: () -> Void

    private let neighborhoods = [
        "Austin, Chicago", "Garfield Park, Chicago", "North Lawndale, Chicago",
        "Humboldt Park, Chicago", "Little Village, Chicago", "West Town, Chicago",
    ]

    private var typedSomething: Bool { !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if typedSomething {
                if model.isGeocoding && model.geocodeResults.isEmpty {
                    HStack(spacing: Spacing.s) {
                        ProgressView()
                        Text("Looking up address…").foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, Spacing.m)
                    .padding(.vertical, Spacing.s)
                } else if model.geocodeResults.isEmpty, model.errorMessage == nil {
                    Text("Keep typing, then pick a match.")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Spacing.m)
                        .padding(.vertical, Spacing.s)
                }
                ForEach(model.geocodeResults) { result in
                    row(title: result.label, systemImage: "mappin.and.ellipse") {
                        Task { await model.choose(result) }
                    }
                }
            } else {
                row(title: String(localized: "Use my location", bundle: LanguageBundle.current), systemImage: "location.fill", tint: Color.accentColor) {
                    dismiss()
                    Task { await model.useMyLocation() }
                }
                Text("Neighborhoods")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Spacing.m)
                    .padding(.top, Spacing.s)
                    .padding(.bottom, 4)
                ForEach(neighborhoods, id: \.self) { name in
                    row(title: name, systemImage: "building.2") {
                        model.searchText = name
                        Task { await model.searchAndUseFirstMatch() }
                    }
                }
            }
        }
        .padding(.vertical, Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .accessibilityLabel("Suggestions")
    }

    private func row(title: String, systemImage: String, tint: Color = .primary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label {
                Text(title).lineLimit(2)
            } icon: {
                Image(systemName: systemImage).foregroundStyle(tint == .primary ? Color.secondary : tint)
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, Spacing.m)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                        PlacePin(type: place.type, logoURL: place.logoURL, selected: model.selectedPlace?.id == place.id)
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
    let environment = AppEnvironment.preview()
    FindFoodView(model: FindFoodModel(environment: environment))
        .environment(environment)
}

#Preview("Error") {
    let environment = AppEnvironment.preview(failure: APIError.invalidResponse)
    FindFoodView(model: FindFoodModel(environment: environment))
        .environment(environment)
}
