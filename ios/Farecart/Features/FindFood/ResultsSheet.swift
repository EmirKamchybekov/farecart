import SwiftUI
import UIKit
import FarecartKit

/// The draggable list under the map, sorted by distance. Tapping a row pushes the detail.
struct ResultsSheet: View {
    @Bindable var model: FindFoodModel
    @State private var showsAbout = false

    var body: some View {
        NavigationStack {
            Group {
                if model.isLoading && model.places.isEmpty {
                    ProgressView("Finding food near you…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.showsEmptyState {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle(headerTitle)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $model.selectedPlace) { place in
                PlaceDetailView(place: place, origin: model.origin, originLabel: model.originLabel)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showsAbout = true
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .accessibilityLabel("About Farecart")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        model.isListPresented = false
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Hide list")
                }
            }
            .sheet(isPresented: $showsAbout) {
                AboutView()
            }
        }
    }

    private var headerTitle: Text {
        if model.places.isEmpty {
            return Text("Nearby places")
        }
        return Text("\(model.places.count) places within \(model.radius.miles) mi")
    }

    private var list: some View {
        List {
            Section {
                ForEach(model.places) { place in
                    Button {
                        model.select(place)
                    } label: {
                        PlaceRow(place: place)
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                if let wider = model.radius.wider {
                    Button {
                        Task { await model.widenSearch() }
                    } label: {
                        Label("Search within \(wider.miles) miles", systemImage: "plus.magnifyingglass")
                    }
                    .padding(.top, 8)
                }
            }
        }
        .listStyle(.plain)
        .refreshable { await model.reload() }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Nothing within \(model.radius.miles) miles", systemImage: "mappin.slash")
        } description: {
            Text("Try a wider search, a different filter, or another address.")
        } actions: {
            if let wider = model.radius.wider {
                Button {
                    Task { await model.widenSearch() }
                } label: {
                    Text("Search within \(wider.miles) miles")
                }
                .buttonStyle(.glassProminent)
            }
            if model.filter != .all {
                Button("Show all types") {
                    Task { await model.setFilter(.all) }
                }
                .buttonStyle(.glass)
            }
        }
    }
}

/// One result: name, type badge, distance, open/closed, EBT or requirements.
struct PlaceRow: View {
    let place: Place

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            PlacePin(type: place.type)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                Text(place.name)
                    .font(.headline)
                HStack(spacing: 8) {
                    TypeBadge(type: place.type)
                    if let meters = place.distanceMeters {
                        Text("\(Distance.milesText(meters: meters)) away")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                hoursLine
                requirementsLine
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 6)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var hoursLine: some View {
        let status = place.openStatus()
        if case .unknown = status {
            if let text = place.hoursText, !text.isEmpty {
                Label(text, systemImage: "clock").font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
        } else {
            OpenStatusLabel(status: status).font(.subheadline.weight(.medium))
        }
    }

    @ViewBuilder
    private var requirementsLine: some View {
        if place.type == .grocery {
            if place.acceptsEBT == true {
                Label("Takes Link/EBT", systemImage: "creditcard.fill")
                    .font(.subheadline).foregroundStyle(.green)
            } else if place.acceptsEBT == false {
                Label("Does not take Link/EBT", systemImage: "creditcard")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        } else if let requirements = place.requirements, !requirements.isEmpty {
            Label(requirements, systemImage: "checklist")
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
        } else {
            Label("No requirements listed", systemImage: "checkmark.circle")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

#Preview("Results") {
    let environment = AppEnvironment.preview()
    let model = FindFoodModel(environment: environment)
    ResultsSheet(model: model)
        .environment(environment)
        .task { await model.loadInitialIfNeeded() }
}

#Preview("Empty") {
    let environment = AppEnvironment.preview(places: [])
    let model = FindFoodModel(environment: environment)
    ResultsSheet(model: model)
        .environment(environment)
        .task { await model.loadInitialIfNeeded() }
}
