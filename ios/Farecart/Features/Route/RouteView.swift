import MapKit
import SwiftUI
import FarecartKit

/// In-app CTA directions: summary + cost, a map of the legs, and plain-language steps.
/// Falls back to Apple / Google Maps when Transitous is down or finds nothing.
struct RouteView: View {
    let request: RouteRequest
    @Environment(AppEnvironment.self) private var environment
    @State private var model: RouteModel?
    @State private var camera: MapCameraPosition = .automatic
    @AppStorage(DiscountsKeys.householdSNAP) private var householdSNAP = false
    @AppStorage(DiscountsKeys.isStudent) private var isStudent = false

    private var answers: EligibilityAnswers {
        EligibilityAnswers(householdReceivesSNAP: householdSNAP, isK12Student: isStudent)
    }

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                loading
            }
        }
        .navigationTitle("Directions by CTA")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemGroupedBackground))
        .task {
            if model == nil {
                let m = RouteModel(request: request, router: environment.router)
                model = m
                async let fares: Void = environment.fareStore.loadIfNeeded()
                await m.load()
                _ = await fares
            }
        }
    }

    // MARK: States

    @ViewBuilder
    private func content(_ model: RouteModel) -> some View {
        if model.isLoading {
            loading
        } else if let itinerary = model.selected {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 16) {
                        tripHeader
                        if model.itineraries.count > 1 {
                            options(model)
                        }
                        summary(itinerary)
                        routeMap(itinerary)
                        steps(itinerary)
                            .id("steps")
                        otherApps(prominent: false)
                    }
                    .padding()
                }
                .onChange(of: itinerary.id, initial: true) {
                    withAnimation(.smooth) { camera = RouteModel.cameraPosition(for: itinerary) }
                }
                #if DEBUG
                .onAppear {
                    // `-farecart-scroll-steps` with `-farecart-open-route`: screenshot the step list.
                    if ProcessInfo.processInfo.arguments.contains("-farecart-scroll-steps") {
                        proxy.scrollTo("steps", anchor: .top)
                    }
                }
                #endif
            }
        } else {
            fallback(model)
        }
    }

    private var loading: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Finding CTA routes…")
                .font(.title3.weight(.semibold))
            Text("Leaving now from \(originName)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func fallback(_ model: RouteModel) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                tripHeader
                VStack(spacing: 12) {
                    Image(systemName: model.failure == .noRoutes ? "bus.doubledecker" : "wifi.exclamationmark")
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(model.failure == .noRoutes ? "No CTA route found for this trip right now." : "We couldn't reach the trip planner.")
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                    Text("No problem. Open the trip in a maps app instead; it shows the same buses and trains.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button {
                        Task { await model.load() }
                    } label: {
                        Label("Try again", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.glass)
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity)
                .padding(20)
                .background(.background, in: RoundedRectangle(cornerRadius: 20))
                .accessibilityElement(children: .contain)
                otherApps(prominent: true)
            }
            .padding()
        }
    }

    // MARK: Sections

    private var originName: String {
        request.originLabel.isEmpty ? String(localized: "West Side, Chicago") : request.originLabel
    }

    private var tripHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(originName)
            } icon: {
                Image(systemName: "circle.fill").foregroundStyle(.green).font(.caption)
            }
            Label {
                Text(request.place.name).bold()
            } icon: {
                Image(systemName: "mappin.circle.fill").foregroundStyle(request.place.type.color)
            }
        }
        .font(.body)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("From \(originName) to \(request.place.name)")
    }

    private func options(_ model: RouteModel) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(model.itineraries.enumerated()), id: \.element.id) { index, itinerary in
                    let isSelected = itinerary.id == model.selected?.id
                    Button {
                        model.select(itinerary)
                    } label: {
                        VStack(spacing: 2) {
                            Text(ChicagoTime.short(itinerary.startTime))
                                .font(.headline)
                            Text(optionTag(for: itinerary, in: model.itineraries))
                                .font(.caption)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.glass)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                    .overlay(
                        Capsule().stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2)
                    )
                    .accessibilityLabel("Option \(index + 1): leaves \(ChicagoTime.short(itinerary.startTime)), \(itinerary.durationMinutes) minutes")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 2)
        }
        .accessibilityLabel("Route options")
    }

    /// "Fastest" / "Fewest transfers" when that option stands out, else just the length.
    private func optionTag(for itinerary: TransitItinerary, in all: [TransitItinerary]) -> LocalizedStringResource {
        let fastest = all.min { $0.duration < $1.duration }
        let fewest = all.min { $0.transfers < $1.transfers }
        if let fastest, fastest.id == itinerary.id, all.contains(where: { $0.duration > fastest.duration }) {
            return "Fastest · \(itinerary.durationMinutes) min"
        }
        if let fewest, fewest.id == itinerary.id, all.contains(where: { $0.transfers > fewest.transfers }) {
            return "Fewest transfers · \(itinerary.durationMinutes) min"
        }
        return "\(itinerary.durationMinutes) min"
    }

    private func summary(_ itinerary: TransitItinerary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            summaryLine(itinerary)
                .font(.title2.weight(.bold))
            Text("Arrive \(ChicagoTime.short(itinerary.endTime))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Divider()
            costLine(itinerary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .combine)
    }

    /// "22 min · 1 bus · leaves 3:27 PM"
    private func summaryLine(_ itinerary: TransitItinerary) -> Text {
        var parts: [Text] = [Text("\(itinerary.durationMinutes) min")]
        if itinerary.isWalkOnly {
            parts.append(Text("walk only"))
        } else {
            if itinerary.busCount > 0 { parts.append(Text("\(itinerary.busCount) buses")) }
            if itinerary.trainCount > 0 { parts.append(Text("\(itinerary.trainCount) trains")) }
        }
        parts.append(Text("leaves \(ChicagoTime.short(itinerary.startTime))"))
        return parts.dropFirst().reduce(parts[0]) { $0 + Text(verbatim: " · ") + $1 }
    }

    @ViewBuilder
    private func costLine(_ itinerary: TransitItinerary) -> some View {
        let store = environment.fareStore
        let cost = TripFareCalculator(fares: store.fares).cost(of: itinerary, answers: answers)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "dollarsign.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                if cost.isFree && itinerary.isWalkOnly {
                    Text("Free. It's all walking.").font(.title3.weight(.semibold))
                } else if cost.hasDiscount {
                    let price = Text(cost.priceText()).bold()
                    let program = Text(programShortName(forKey: cost.rider.programKey))
                    Text("\(price) with your \(program) discount (instead of \(cost.fullPriceText()))")
                        .font(.title3)
                } else {
                    let price = Text(cost.priceText()).bold()
                    Text("\(price) full fare").font(.title3)
                }
            }
            if cost.boardings > 1 {
                Text("Transfers are included in that price.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(cost.notes, id: \.self) { note in
                Label(noteText(note), systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if !cost.hasDiscount && !answers.householdReceivesSNAP && !answers.isK12Student && cost.boardings > 0 {
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
    }

    private func noteText(_ note: TripCostNote) -> LocalizedStringResource {
        switch note {
        case .nonCTALegNotIncluded: "Includes a non-CTA leg; fare not included"
        case .missingFareData: "Fare data is missing for part of this trip"
        }
    }

    private func routeMap(_ itinerary: TransitItinerary) -> some View {
        Map(position: $camera, interactionModes: [.pan, .zoom]) {
            ForEach(itinerary.legs) { leg in
                let coordinates = leg.polyline.isEmpty ? [leg.from.coordinate, leg.to.coordinate] : leg.polyline
                MapPolyline(coordinates: coordinates.map(\.clCoordinate))
                    .stroke(
                        leg.displayColor,
                        style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round, dash: leg.mode == .walk ? [2, 10] : [])
                    )
            }
            ForEach(itinerary.transitLegs) { leg in
                Annotation(leg.from.name, coordinate: leg.from.coordinate.clCoordinate, anchor: .center) {
                    StopDot(color: leg.displayColor)
                }
                .annotationTitles(.hidden)
                Annotation(leg.to.name, coordinate: leg.to.coordinate.clCoordinate, anchor: .center) {
                    StopDot(color: leg.displayColor)
                }
                .annotationTitles(.hidden)
            }
            Annotation(originName, coordinate: request.origin.clCoordinate, anchor: .center) {
                EndpointPin(systemImage: "figure.walk", color: .green)
            }
            .annotationTitles(.hidden)
            Annotation(request.place.name, coordinate: request.place.clCoordinate, anchor: .center) {
                EndpointPin(systemImage: request.place.type.symbolName, color: request.place.type.color)
            }
            .annotationTitles(.hidden)
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .mapControlVisibility(.hidden)
        // Inside a ScrollView the map inherits the navigation bar's safe-area inset and would
        // centre the route in the lower part of the frame; it is not at a screen edge, so ignore it.
        .ignoresSafeArea()
        .frame(height: 300)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .accessibilityLabel("Map of the route from \(originName) to \(request.place.name)")
    }

    private func steps(_ itinerary: TransitItinerary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(itinerary.legs.enumerated()), id: \.element.id) { index, leg in
                StepRow(leg: leg, isLast: index == itinerary.legs.count - 1, originName: originName, destinationName: request.place.name)
            }
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Steps")
    }

    private func otherApps(prominent: Bool) -> some View {
        VStack(spacing: 12) {
            Button {
                Directions.openAppleMapsTransit(to: request.place)
            } label: {
                BigButtonLabel(title: "Open in Apple Maps", systemImage: "map.fill")
            }
            .buttonStyle(.glass)
            .accessibilityHint("Opens Apple Maps with bus and train directions")

            Button {
                Directions.openGoogleMapsTransit(to: request.place)
            } label: {
                BigButtonLabel(title: "Open in Google Maps", systemImage: "map")
            }
            .buttonStyle(.glass)
            .accessibilityHint("Opens Google Maps with transit directions")
        }
        .padding(.top, prominent ? 0 : 4)
    }
}

// MARK: - Pieces

/// One line of the step list, with a colored icon and the leg's details.
private struct StepRow: View {
    let leg: TransitLeg
    let isLast: Bool
    let originName: String
    let destinationName: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                Image(systemName: leg.symbolName)
                    .font(.body.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(leg.displayColor, in: Circle())
                if !isLast {
                    Rectangle()
                        .fill(Color(.systemGray4))
                        .frame(width: 3)
                        .frame(maxHeight: .infinity)
                        .padding(.vertical, 4)
                }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                title
                    .font(.body.weight(.semibold))
                detail
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, isLast ? 0 : 18)
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    private var toName: String {
        switch leg.to.name {
        case "END", "": destinationName
        default: leg.to.name
        }
    }

    @ViewBuilder
    private var title: some View {
        switch leg.mode {
        case .walk:
            Text("Walk \(leg.durationMinutes) min to \(toName)")
        case .bus:
            if let route = leg.routeDisplayName, let headsign = leg.headsign {
                Text("Bus \(route) toward \(headsign)")
            } else if let route = leg.routeDisplayName {
                Text("Bus \(route)")
            } else {
                Text("Bus")
            }
        case .train:
            if let route = leg.routeDisplayName, let headsign = leg.headsign {
                Text("\(route) train toward \(headsign)")
            } else if let route = leg.routeDisplayName {
                Text("\(route) train")
            } else {
                Text("Train")
            }
        case .other:
            if let route = leg.routeDisplayName {
                Text("Ride \(route)")
            } else {
                Text("Ride")
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch leg.mode {
        case .walk:
            if let time = leg.to.time {
                Text("Arrive \(ChicagoTime.short(time))")
            }
        default:
            let stops = Text("\(leg.intermediateStopCount + 1) stops")
            let getOff = Text("get off at \(toName)")
            let minutes = Text("\(leg.durationMinutes) min")
            VStack(alignment: .leading, spacing: 2) {
                Text("Board at \(leg.from.name)")
                minutes + Text(verbatim: " · ") + stops + Text(verbatim: " · ") + getOff
                if let agency = leg.agencyName, !leg.isCTA {
                    Text("Run by \(agency); fare not included")
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}

private struct StopDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(.white)
            .frame(width: 14, height: 14)
            .overlay(Circle().stroke(color, lineWidth: 4))
    }
}

private struct EndpointPin: View {
    let systemImage: String
    let color: Color

    var body: some View {
        ZStack {
            Circle()
                .fill(color)
                .frame(width: 32, height: 32)
                .shadow(radius: 2, y: 1)
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
        }
        .overlay(Circle().stroke(.white, lineWidth: 2))
    }
}

#Preview("Route") {
    NavigationStack {
        RouteView(request: RouteRequest(origin: .westSideChicago, originLabel: "Madison & Pulaski", place: MockData.samplePlace))
    }
    .environment(AppEnvironment.preview())
}
