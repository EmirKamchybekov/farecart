import SwiftUI
import FarecartKit

/// The booked visit: a big confirmation code, when and where, Add to Calendar, Directions by CTA
/// and Cancel visit. Shown right after booking (in the sheet) and from "Your visits".
struct VisitConfirmationView: View {
    let visit: PantryVisit
    /// Set when the place screen is underneath: dismisses and switches to its Directions tab.
    /// `nil` pushes the route screen for the visit instead.
    var onDirections: (() -> Void)? = nil

    @Environment(AppEnvironment.self) private var environment
    @State private var confirmCancel = false
    @State private var isCancelling = false
    @State private var calendarOutcome: CalendarExport.Outcome?
    @State private var errorMessage: String?

    /// The store's copy when it has one (status changes after cancelling).
    private var current: PantryVisit {
        environment.pantry.visits.first { $0.id == visit.id } ?? visit
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.m) {
                header
                codeCard
                detailsCard
                if let errorMessage {
                    MessageBanner(text: errorMessage)
                }
                actions
            }
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.xs)
        }
        .background(Color(.systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Cancel this visit?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Cancel visit", role: .destructive) { Task { await cancel() } }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("Your spot goes back to the pantry so someone else can use it.")
        }
    }

    // MARK: Pieces

    private var status: PantryVisitStatus { current.status }

    private var header: some View {
        VStack(spacing: Spacing.xs) {
            Image(systemName: status == .cancelled ? "xmark.circle.fill" : (status == .arrived ? "person.fill.checkmark" : "checkmark.circle.fill"))
                .font(.system(size: 56))
                .foregroundStyle(status == .cancelled ? Color.secondary : Color.green)
                .accessibilityHidden(true)
            Text(headline)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
            Text(current.locationName)
                .font(.headline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, Spacing.s)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var headline: LocalizedStringResource {
        switch status {
        case .booked: current.isUpcoming() ? "You're booked" : "Past visit"
        case .cancelled: "Visit cancelled"
        case .arrived: "Checked in"
        }
    }

    private var codeCard: some View {
        VStack(spacing: Spacing.xs) {
            SectionCaption("Confirmation code")
            QRCodeView(payload: "farecart://visit/\(current.confirmationCode)", dimmed: status == .cancelled)
                .frame(width: 200, height: 200)
                .padding(.vertical, Spacing.xs)
            Text(current.confirmationCode)
                .font(.system(size: 48, weight: .heavy, design: .rounded))
                .monospaced()
                .tracking(6)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .foregroundStyle(status == .cancelled ? Color.secondary : Color.primary)
                .accessibilityLabel(Text("Confirmation code \(current.confirmationCode.map(String.init).joined(separator: " "))"))
            Text(status == .cancelled ? "This code is no longer valid." : "Show this QR code or the code when you arrive.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .card()
    }

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            InfoRow(systemImage: "calendar", tint: .accentColor, title: "When") {
                Text(VisitFormat.day(current.startsAt)).fontWeight(.semibold)
                Text(VisitFormat.timeRange(current.startsAt, current.endsAt))
            }
            Divider()
            InfoRow(systemImage: "mappin.and.ellipse", tint: .accentColor, title: "Where") {
                Text(current.locationName).fontWeight(.semibold)
                Text(current.address).foregroundStyle(.secondary)
            }
            Divider()
            InfoRow(systemImage: "person.2.fill", tint: .accentColor, title: "People coming") {
                Text("\(current.partySize) people")
            }
        }
        .card()
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: Spacing.s) {
            if status != .cancelled {
                if let onDirections {
                    Button(action: onDirections) {
                        BigButtonLabel(title: "Directions by CTA", systemImage: "bus.fill")
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.capsule)
                } else if current.coordinate != nil {
                    NavigationLink(value: VisitRoute(visit: current)) {
                        BigButtonLabel(title: "Directions by CTA", systemImage: "bus.fill")
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.capsule)
                }
                Button {
                    Task { calendarOutcome = await CalendarExport.add(current) }
                } label: {
                    BigButtonLabel(title: calendarOutcome == .added ? "Added to Calendar" : "Add to Calendar", systemImage: calendarOutcome == .added ? "checkmark" : "calendar.badge.plus")
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .disabled(calendarOutcome == .added)
                if calendarOutcome == .denied {
                    Text("Calendar access is off. Allow it in Settings → Privacy → Calendars to add visits.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else if calendarOutcome == .failed {
                    Text("Could not add the visit to your calendar.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if current.canCancel && current.isUpcoming() {
                Button(role: .destructive) {
                    confirmCancel = true
                } label: {
                    if isCancelling {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 32).padding(.vertical, 8)
                    } else {
                        BigButtonLabel(title: "Cancel visit", systemImage: "xmark")
                    }
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .tint(.red)
                .disabled(isCancelling)
            }
        }
        .padding(.top, Spacing.xs)
    }

    private func cancel() async {
        isCancelling = true
        errorMessage = nil
        defer { isCancelling = false }
        do {
            try await environment.pantry.cancel(current)
        } catch {
            errorMessage = PantryError.wrap(error).userMessage
        }
    }
}

/// Navigation value for "Directions by CTA" from a visit (outside the place screen).
struct VisitRoute: Hashable {
    let visit: PantryVisit
}

/// Resolves the origin (the phone's location when allowed, else the West Side) and shows the route.
struct VisitRouteView: View {
    let visit: PantryVisit
    @Environment(AppEnvironment.self) private var environment
    @State private var request: RouteRequest?

    var body: some View {
        Group {
            if let request {
                RouteView(request: request)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemGroupedBackground))
            }
        }
        .task {
            guard request == nil, let place = visit.asPlace() else { return }
            var origin = GeoPoint.westSideChicago
            var label = String(localized: "West Side, Chicago", bundle: LanguageBundle.current)
            if environment.location.isAuthorized, let here = try? await environment.location.currentLocation(timeout: .seconds(5)) {
                origin = here
                label = String(localized: "My location", bundle: LanguageBundle.current)
            }
            request = RouteRequest(origin: origin, originLabel: label, place: place)
        }
    }
}

extension View {
    /// Presents a visit's ticket (QR, code, details, directions, cancel) as a sheet.
    func visitTicketSheet(_ visit: Binding<PantryVisit?>) -> some View {
        sheet(item: visit) { item in
            NavigationStack {
                VisitConfirmationView(visit: item)
                    .navigationTitle(Text("Your visit"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { visit.wrappedValue = nil }
                        }
                    }
                    .visitDestinations()
            }
        }
    }

    /// Registers the destinations a visit can push: its confirmation screen and its route.
    func visitDestinations() -> some View {
        self
            .navigationDestination(for: PantryVisit.self) { visit in
                VisitConfirmationView(visit: visit)
                    .navigationTitle(Text("Your visit"))
            }
            .navigationDestination(for: VisitRoute.self) { route in
                VisitRouteView(visit: route.visit)
            }
    }
}

#Preview("Booked") {
    NavigationStack {
        VisitConfirmationView(visit: PantryVisit(
            locationID: MockData.samplePantry.id,
            locationName: MockData.samplePantry.name,
            address: MockData.samplePantry.address,
            latitude: MockData.samplePantry.latitude,
            longitude: MockData.samplePantry.longitude,
            startsAt: Date().addingTimeInterval(86400),
            endsAt: Date().addingTimeInterval(86400 + 1800),
            partySize: 3,
            confirmationCode: "K7PX2M"
        ))
        .visitDestinations()
    }
    .environment(AppEnvironment.preview())
}
