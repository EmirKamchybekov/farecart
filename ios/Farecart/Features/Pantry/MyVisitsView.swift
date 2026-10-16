import SwiftUI
import FarecartKit

/// Every booking this phone made: upcoming first, then the past 30 days. Tap for the code,
/// swipe (or open) to cancel.
struct MyVisitsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var cancelTarget: PantryVisit?
    @State private var errorMessage: String?

    private var store: PantryStore { environment.pantry }

    var body: some View {
        List {
            if let errorMessage {
                Section {
                    MessageBanner(text: errorMessage) { Task { await store.refreshVisits() } }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
            }
            if store.visitsLoaded && store.visits.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("No visits yet", systemImage: "calendar.badge.plus")
                    } description: {
                        Text("Open a pantry in Find Food and pick a time. Your confirmation code will show here.")
                    }
                    .listRowBackground(Color.clear)
                }
            }
            if !store.upcomingVisits.isEmpty {
                Section("Upcoming") {
                    ForEach(store.upcomingVisits) { visit in
                        NavigationLink(value: visit) {
                            VisitRow(visit: visit)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if visit.canCancel {
                                Button(role: .destructive) {
                                    cancelTarget = visit
                                } label: {
                                    Label("Cancel visit", systemImage: "xmark")
                                }
                            }
                        }
                    }
                }
            }
            if !store.pastVisits.isEmpty {
                Section("Past and cancelled") {
                    ForEach(store.pastVisits) { visit in
                        NavigationLink(value: visit) {
                            VisitRow(visit: visit)
                        }
                    }
                }
            }
        }
        .overlay {
            if !store.visitsLoaded && store.isLoadingVisits {
                ProgressView()
            }
        }
        .navigationTitle("Your visits")
        .navigationBarTitleDisplayMode(.large)
        .refreshable { await store.refreshVisits() }
        .task {
            await store.loadVisitsIfNeeded()
            errorMessage = store.visitsError
            #if DEBUG
            // `-farecart-cancel-first-visit`: cancel the next visit after loading (screenshots).
            if ProcessInfo.processInfo.arguments.contains("-farecart-cancel-first-visit"), let first = store.upcomingVisits.first {
                try? await Task.sleep(for: .seconds(1.5))
                await cancel(first)
            }
            #endif
        }
        .confirmationDialog("Cancel this visit?", isPresented: Binding(get: { cancelTarget != nil }, set: { if !$0 { cancelTarget = nil } }), titleVisibility: .visible, presenting: cancelTarget) { visit in
            Button("Cancel visit", role: .destructive) { Task { await cancel(visit) } }
            Button("Keep it", role: .cancel) {}
        } message: { visit in
            Text("\(visit.locationName), \(VisitFormat.dayAndTime(visit.startsAt)). Your spot goes back to the pantry.")
        }
    }

    private func cancel(_ visit: PantryVisit) async {
        do {
            try await store.cancel(visit)
            errorMessage = nil
        } catch {
            errorMessage = PantryError.wrap(error).userMessage
        }
    }
}

/// Pantry, day and time, status, and the code on the right.
struct VisitRow: View {
    let visit: PantryVisit

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.s) {
            VStack(alignment: .leading, spacing: 3) {
                Text(visit.locationName)
                    .font(.headline)
                    .lineLimit(2)
                Text(VisitFormat.dayAndTime(visit.startsAt))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                switch visit.status {
                case .cancelled:
                    Text("Cancelled").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                case .arrived:
                    Label("Checked in", systemImage: "checkmark").font(.caption.weight(.semibold)).foregroundStyle(.green)
                case .booked:
                    if visit.partySize > 1 {
                        Text("\(visit.partySize) people").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: Spacing.xs)
            Text(visit.confirmationCode)
                .font(.body.weight(.bold).monospaced())
                .foregroundStyle(visit.status == .cancelled ? Color.secondary : Color.primary)
                .strikethrough(visit.status == .cancelled)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// The next visit, for the top of Find Food's results and the Settings section: pantry, time,
/// code and a Directions button.
struct UpcomingVisitCard: View {
    let visit: PantryVisit
    var compact = false

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            Image(systemName: "calendar.badge.checkmark")
                .font(.title2)
                .foregroundStyle(.green)
                .frame(width: 32)
                .padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                SectionCaption("Your visit")
                Text(visit.locationName)
                    .font(.headline)
                    .lineLimit(2)
                Text(VisitFormat.dayAndTime(visit.startsAt))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: Spacing.s) {
                    Text(visit.confirmationCode)
                        .font(.subheadline.weight(.bold).monospaced())
                    if visit.coordinate != nil {
                        HStack(spacing: 4) {
                            Image(systemName: "bus.fill")
                            Text("Directions by CTA")
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows your confirmation code, directions and lets you cancel")
    }
}

#Preview {
    NavigationStack {
        MyVisitsView()
            .visitDestinations()
    }
    .environment(AppEnvironment.preview())
}
