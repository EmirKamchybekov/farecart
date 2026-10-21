import SwiftUI
import UIKit
import FarecartKit

/// The list under the map, sorted by distance. It is a panel inside the tab (not a sheet) so the
/// tab bar stays reachable; drag the handle or the header between peek / half / full.
struct ResultsPanel: View {
    @Bindable var model: FindFoodModel
    @Environment(AppEnvironment.self) private var environment
    @State private var ticket: PantryVisit?
    /// Height available to the panel (the map area), from the parent's GeometryReader.
    let availableHeight: CGFloat
    @State private var dragOffset: CGFloat = 0

    private static let peekHeight: CGFloat = 76

    private func height(for state: ResultsPanelState) -> CGFloat {
        switch state {
        case .peek: Self.peekHeight
        case .half: max(Self.peekHeight, availableHeight * 0.46)
        case .full: max(Self.peekHeight, availableHeight - Spacing.xs)
        }
    }

    private var currentHeight: CGFloat {
        min(max(height(for: model.panelState) - dragOffset, Self.peekHeight), height(for: .full))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .frame(maxWidth: .infinity)
        .frame(height: currentHeight, alignment: .top)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .background(Color(.systemBackground).opacity(0.6), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 12, y: -2)
        .animation(.snappy, value: model.panelState)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Nearby places")
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: Spacing.xs) {
            Capsule()
                .fill(Color(.systemGray3))
                .frame(width: 36, height: 5)
                .padding(.top, Spacing.xs)
                .accessibilityHidden(true)
            HStack(spacing: Spacing.s) {
                Image(systemName: "chevron.down.circle.fill")
                    .font(.title2)
                    .hidden()   // balances the button on the right so the title is centered
                Spacer(minLength: 0)
                headerTitle
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 0)

                Button {
                    toggle()
                } label: {
                    Image(systemName: model.panelState == .peek ? "chevron.up.circle.fill" : "chevron.down.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(model.panelState == .peek ? Text("Show list") : Text("Hide list"))
            }
            .padding(.horizontal, Spacing.m)
            .padding(.bottom, Spacing.s)
        }
        .contentShape(Rectangle())
        .gesture(dragGesture)
        .onTapGesture { toggle() }
        .accessibilityAction(named: Text("Show list")) { model.panelState = .half }
        .accessibilityAction(named: Text("Expand list")) { model.panelState = .full }
        .accessibilityAction(named: Text("Hide list")) { model.panelState = .peek }
    }

    private var headerTitle: Text {
        if model.isLoading && model.places.isEmpty {
            return Text("Finding food near you…")
        }
        if model.places.isEmpty {
            return Text("Nearby places")
        }
        return Text("\(model.places.count) places within \(model.radius.miles) mi")
    }

    private func toggle() {
        withAnimation(.snappy) {
            model.panelState = model.panelState == .peek ? .half : .peek
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                dragOffset = value.translation.height
            }
            .onEnded { value in
                let projected = height(for: model.panelState) - value.predictedEndTranslation.height
                let candidates: [ResultsPanelState] = [.peek, .half, .full]
                let nearest = candidates.min { abs(height(for: $0) - projected) < abs(height(for: $1) - projected) } ?? .half
                withAnimation(.snappy) {
                    dragOffset = 0
                    model.panelState = nearest
                }
            }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if model.isLoading && model.places.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.showsEmptyState {
            emptyState
        } else {
            list
                .visitTicketSheet($ticket)
        }
    }

    private var list: some View {
        List {
            if let next = environment.pantry.nextVisit {
                Section {
                    Button { ticket = next } label: {
                        HStack {
                            UpcomingVisitCard(visit: next, compact: true)
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
                            .fill(Color(.secondarySystemGroupedBackground))
                            .padding(.horizontal, Spacing.xs)
                    )
                    .listRowInsets(EdgeInsets(top: Spacing.s, leading: Spacing.m + Spacing.xs, bottom: Spacing.s, trailing: Spacing.m + Spacing.xs))
                    .listRowSeparator(.hidden)
                }
            }
            Section {
                ForEach(model.places) { place in
                    Button {
                        model.select(place)
                    } label: {
                        PlaceRow(place: place)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: Spacing.xs, leading: Spacing.m, bottom: Spacing.xs, trailing: Spacing.m))
                }
            } footer: {
                if let wider = model.radius.wider {
                    Button {
                        Task { await model.widenSearch() }
                    } label: {
                        Label("Search within \(wider.miles) miles", systemImage: "plus.magnifyingglass")
                    }
                    .padding(.top, Spacing.xs)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
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

/// One result: logo (or the type tile), name and "Grocery · Takes Link/EBT" on the left; distance
/// big and open/closed small on the right.
struct PlaceRow: View {
    let place: Place
    @Environment(AppEnvironment.self) private var environment

    /// Only once this pantry's availability was loaded (opening its detail); no extra calls for the list.
    private var canBook: Bool {
        place.type == .pantry && (place.isBookable || environment.pantry.cachedAvailability(for: place.id)?.hasUpcomingSlots() == true)
    }

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.s) {
            PlaceIcon(place: place, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(place.name)
                    .font(.headline)
                    .lineLimit(2)
                detailLine
                    .font(.subheadline)
                    .lineLimit(1)
                if canBook {
                    Pill(text: Text("Book a visit"), systemImage: "calendar.badge.plus", tint: .accentColor)
                        .font(.caption.weight(.semibold))
                        .padding(.top, 2)
                } else if place.type == .pantry {
                    Pill(text: Text("Walk-in"), systemImage: "figure.walk", tint: .secondary)
                        .font(.caption.weight(.semibold))
                        .padding(.top, 2)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: Spacing.xs)
            VStack(alignment: .trailing, spacing: 2) {
                if let meters = place.distanceMeters {
                    Text(Distance.milesText(meters: meters))
                        .font(.title3.weight(.bold))
                        .monospacedDigit()
                }
                OpenStatusLabel(status: place.openStatus(), compact: true)
                    .font(.caption.weight(.semibold))
            }
            .fixedSize()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// "Grocery · Takes Link/EBT", "Pantry · Photo ID", "Giveaway · No requirements".
    private var detailLine: Text {
        let type = Text(place.type.title).foregroundStyle(place.type.color).bold()
        let detail: Text
        if place.type == .grocery {
            switch place.acceptsEBT {
            case true?: detail = Text("Takes Link/EBT").foregroundStyle(.green)
            case false?: detail = Text("No Link/EBT").foregroundStyle(.secondary)
            default: detail = Text("Link/EBT unknown").foregroundStyle(.secondary)
            }
        } else if let requirements = place.requirements, !requirements.isEmpty {
            detail = Text(requirements).foregroundStyle(.secondary)
        } else {
            detail = Text("No requirements").foregroundStyle(.secondary)
        }
        return type + Text(verbatim: " · ").foregroundStyle(.secondary) + detail
    }
}

#Preview("Results") {
    let environment = AppEnvironment.preview()
    let model = FindFoodModel(environment: environment)
    ZStack(alignment: .bottom) {
        Color.gray.ignoresSafeArea()
        ResultsPanel(model: model, availableHeight: 700)
            .padding(.horizontal, Spacing.xs)
    }
    .environment(environment)
    .task { await model.loadInitialIfNeeded() }
}
