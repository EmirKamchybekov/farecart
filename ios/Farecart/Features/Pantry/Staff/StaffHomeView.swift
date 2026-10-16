import SwiftUI
import FarecartKit

/// Staff mode for one pantry: today's stock (tap to cycle plenty → low → out), visit slots for
/// the next 7 days (add / delete) and today's bookings with an Arrived button. Big targets,
/// few taps, every change saved immediately.
struct StaffHomeView: View {
    let session: StaffSession
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.calendar) private var calendar
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var availability: PantryAvailability?
    @State private var bookings: [StaffBooking] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var savingCategories: Set<PantryCategory> = []
    @State private var savedCategory: PantryCategory?
    @State private var showsAddSlot = false
    @State private var slotToDelete: PantrySlot?
    @State private var confirmSignOut = false
    @State private var arrivingVisits: Set<UUID> = []

    private var service: any PantryService { environment.pantry.service }

    private static let bottomAnchor = "staff-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if let errorMessage {
                    Section {
                        MessageBanner(text: errorMessage) { Task { await load() } }
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets())
                    }
                }
                stockSection
                slotsSection
                bookingsSection
                Section {
                    Button(role: .destructive) {
                        confirmSignOut = true
                    } label: {
                        Label("Sign out of staff mode", systemImage: "rectangle.portrait.and.arrow.right")
                        .foregroundStyle(.red)
                    }
                } footer: {
                    Text("Signing out only forgets the code on this phone. Stock and slots stay as posted.")
                }
                .id(Self.bottomAnchor)
            }
            #if DEBUG
            .onChange(of: bookings.count) {
                // `-farecart-staff-scroll-bottom`: show the slots and bookings sections (screenshots).
                guard ProcessInfo.processInfo.arguments.contains("-farecart-staff-scroll-bottom") else { return }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2.5))
                    withAnimation { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
                }
            }
            #endif
        }
        .navigationTitle(Text(verbatim: session.name))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .sheet(isPresented: $showsAddSlot) {
            StaffSlotEditorView(session: session) { slot in
                availability?.slots.append(slot)
                environment.pantry.invalidateAvailability(for: session.locationID)
            }
        }
        .confirmationDialog("Delete this slot?", isPresented: Binding(get: { slotToDelete != nil }, set: { if !$0 { slotToDelete = nil } }), titleVisibility: .visible, presenting: slotToDelete) { slot in
            Button("Delete slot", role: .destructive) { Task { await delete(slot) } }
            Button("Keep it", role: .cancel) {}
        } message: { slot in
            if slot.booked > 0 {
                Text("\(slot.booked) people are booked for \(VisitFormat.dayAndTime(slot.startsAt)). Deleting the slot cancels their visits.")
            } else {
                Text(VisitFormat.dayAndTime(slot.startsAt))
            }
        }
        .confirmationDialog("Sign out of staff mode?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { environment.pantry.staffSignOut() }
        }
    }

    // MARK: Stock

    private var stockSection: some View {
        Section {
            // Two tiles per row; one at accessibility text sizes so names never hyphenate.
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.xs), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2), spacing: Spacing.xs) {
                ForEach(PantryCategory.allCases) { category in
                    StockTile(
                        category: category,
                        level: currentLevel(category),
                        isSaving: savingCategories.contains(category),
                        isSaved: savedCategory == category
                    ) {
                        Task { await cycle(category) }
                    }
                }
            }
            .listRowInsets(EdgeInsets(top: Spacing.xs, leading: Spacing.m, bottom: Spacing.xs, trailing: Spacing.m))
            .listRowBackground(Color.clear)
        } header: {
            HStack {
                Text("Today's stock")
                Spacer()
                if isLoading && availability == nil { ProgressView().controlSize(.small) }
            }
        } footer: {
            Text("Tap a category to change it: plenty → low → out. People see it right away. Posts expire after 24 hours, so tap through them again each day you open.")
        }
    }

    private func currentLevel(_ category: PantryCategory) -> PantryLevel? {
        availability?.currentInventory().first { $0.category == category }?.level
    }

    private func cycle(_ category: PantryCategory) async {
        guard !savingCategories.contains(category) else { return }
        let next = currentLevel(category)?.next ?? .plenty
        savingCategories.insert(category)
        errorMessage = nil
        let previous = availability
        // Optimistic: show the new level at once, revert on failure.
        withAnimation(.snappy) { applyLocally(PantryInventoryItem(category: category, level: next, source: "staff")) }
        do {
            let saved = try await service.staffSetInventory(code: session.code, category: category, level: next, note: nil)
            withAnimation(.snappy) { applyLocally(saved) }
            environment.pantry.invalidateAvailability(for: session.locationID)
            savedCategory = category
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                if savedCategory == category { withAnimation { savedCategory = nil } }
            }
        } catch {
            withAnimation(.snappy) { availability = previous }
            errorMessage = PantryError.wrap(error).userMessage
            if case PantryError.badCode = PantryError.wrap(error) { environment.pantry.staffSignOut() }
        }
        savingCategories.remove(category)
    }

    private func applyLocally(_ item: PantryInventoryItem) {
        var current = availability ?? PantryAvailability(locationID: session.locationID)
        current.inventory.removeAll { $0.category == item.category }
        current.inventory.append(item)
        availability = current
    }

    // MARK: Slots

    private var upcomingWeek: [(day: Date, slots: [PantrySlot])] {
        guard let availability, let limit = calendar.date(byAdding: .day, value: 7, to: calendar.startOfDay(for: Date())) else { return [] }
        return availability.slotsByDay(calendar: calendar).filter { $0.day < limit }
    }

    private var slotsSection: some View {
        Section {
            if upcomingWeek.isEmpty && availability != nil {
                Text("No slots in the next 7 days. People can still walk in during your open hours.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(upcomingWeek, id: \.day) { entry in
                Text(dayHeading(entry.day))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
                ForEach(entry.slots) { slot in
                    slotRow(slot)
                }
            }
            Button {
                showsAddSlot = true
            } label: {
                Label("Add a slot", systemImage: "plus.circle.fill")
                    .font(.body.weight(.semibold))
                    .frame(minHeight: 32)
            }
            .accessibilityHint("Opens a form for a new visit slot")
        } header: {
            Text("Visit slots · next 7 days")
        }
    }

    private func dayHeading(_ day: Date) -> String {
        if calendar.isDateInToday(day) { return String(localized: "Today", bundle: LanguageBundle.current) }
        if calendar.isDateInTomorrow(day) { return String(localized: "Tomorrow", bundle: LanguageBundle.current) }
        return VisitFormat.day(day)
    }

    private func slotRow(_ slot: PantrySlot) -> some View {
        HStack(spacing: Spacing.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(VisitFormat.timeRange(slot.startsAt, slot.endsAt))
                    .font(.headline)
                    .monospacedDigit()
                Text("\(slot.booked) of \(slot.capacity) booked")
                    .font(.subheadline)
                    .foregroundStyle(slot.isFull ? Color.orange : Color.secondary)
            }
            Spacer()
            Button(role: .destructive) {
                slotToDelete = slot
            } label: {
                Image(systemName: "trash")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Delete slot")
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { slotToDelete = slot } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private func delete(_ slot: PantrySlot) async {
        errorMessage = nil
        do {
            try await service.staffDeleteSlot(code: session.code, slotID: slot.id)
            withAnimation(.snappy) { availability?.slots.removeAll { $0.id == slot.id } }
            environment.pantry.invalidateAvailability(for: session.locationID)
            await loadBookings()
        } catch {
            errorMessage = PantryError.wrap(error).userMessage
        }
    }

    // MARK: Bookings

    private var bookingsSection: some View {
        Section {
            if bookings.isEmpty {
                Text("No bookings yet today.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(bookings) { booking in
                bookingRow(booking)
            }
        } header: {
            Text("Today's bookings")
        } footer: {
            if !bookings.isEmpty {
                Text("Ask for the code when someone arrives, then tap Arrived.")
            }
        }
    }

    private func bookingRow(_ booking: StaffBooking) -> some View {
        HStack(spacing: Spacing.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(VisitFormat.time(booking.startsAt))
                    .font(.headline)
                    .monospacedDigit()
                Text("\(booking.partySize) people")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text(booking.confirmationCode)
                .font(.title3.weight(.bold).monospaced())
                .strikethrough(booking.status == .cancelled)
                .foregroundStyle(booking.status == .cancelled ? Color.secondary : Color.primary)
            Spacer()
            switch booking.status {
            case .arrived:
                Label("Arrived", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            case .cancelled:
                Text("Cancelled")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            case .booked:
                Button {
                    Task { await markArrived(booking) }
                } label: {
                    if arrivingVisits.contains(booking.id) {
                        ProgressView().frame(minWidth: 72, minHeight: 28)
                    } else {
                        Text("Arrived")
                            .font(.subheadline.weight(.semibold))
                            .frame(minWidth: 72, minHeight: 28)
                    }
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .disabled(arrivingVisits.contains(booking.id))
                .accessibilityLabel(Text("Mark \(booking.confirmationCode) as arrived"))
            }
        }
        .padding(.vertical, 4)
    }

    private func markArrived(_ booking: StaffBooking) async {
        arrivingVisits.insert(booking.id)
        errorMessage = nil
        do {
            try await service.staffMarkArrived(code: session.code, visitID: booking.id)
            if let index = bookings.firstIndex(where: { $0.id == booking.id }) {
                withAnimation(.snappy) { bookings[index].status = .arrived }
            }
        } catch {
            errorMessage = PantryError.wrap(error).userMessage
        }
        arrivingVisits.remove(booking.id)
    }

    // MARK: Loading

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let stock = service.availability(locationID: session.locationID)
            async let today = service.staffBookings(code: session.code, day: Date())
            let (loadedStock, loadedBookings) = try await (stock, today)
            availability = loadedStock
            bookings = loadedBookings
            errorMessage = nil
        } catch {
            let pantryError = PantryError.wrap(error)
            errorMessage = pantryError.userMessage
            if pantryError == .badCode { environment.pantry.staffSignOut() }
        }
        #if DEBUG
        await runDebugActions()
        #endif
    }

    private func loadBookings() async {
        bookings = (try? await service.staffBookings(code: session.code, day: Date())) ?? bookings
    }

    #if DEBUG
    @State private var debugActionsDone = false

    /// `-farecart-staff-cycle produce` taps that category once; `-farecart-staff-add-slot` opens the
    /// add-slot form; `-farecart-staff-arrive-first` taps Arrived on the first booking.
    private func runDebugActions() async {
        guard !debugActionsDone else { return }
        debugActionsDone = true
        let arguments = ProcessInfo.processInfo.arguments
        try? await Task.sleep(for: .seconds(1))
        if let index = arguments.firstIndex(of: "-farecart-staff-cycle"), index + 1 < arguments.count,
           let category = PantryCategory(rawValue: arguments[index + 1]) {
            await cycle(category)
        }
        if arguments.contains("-farecart-staff-arrive-first"), let first = bookings.first(where: { $0.status == .booked }) {
            await markArrived(first)
        }
        if arguments.contains("-farecart-staff-add-slot") {
            showsAddSlot = true
        }
    }
    #endif
}

/// One category in the staff grid. Tap cycles the level; the tile shows "Saving…" / "Saved".
struct StockTile: View {
    let category: PantryCategory
    let level: PantryLevel?
    let isSaving: Bool
    let isSaved: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: category.symbolName)
                        .font(.title2)
                        .foregroundStyle(level?.color ?? .secondary)
                    Spacer()
                    if isSaving {
                        ProgressView().controlSize(.small)
                    } else if isSaved {
                        Label("Saved", systemImage: "checkmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.green)
                            .transition(.opacity)
                    }
                }
                Text(category.title)
                    .font(.headline)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Text(level?.title ?? "Not posted")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(level?.color ?? .secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
            .padding(Spacing.s)
            .background((level?.color ?? .gray).opacity(level == nil ? 0.04 : 0.16), in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
                    .strokeBorder((level?.color ?? .gray).opacity(level == nil ? 0.5 : 0.35), style: StrokeStyle(lineWidth: 1, dash: level == nil ? [5, 4] : []))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(Text(category.title)): \(Text(level?.title ?? "Not posted"))"))
        .accessibilityHint(Text("Changes it to \(Text((level?.next ?? .plenty).title))"))
    }
}

#Preview {
    NavigationStack {
        StaffHomeView(session: StaffSession(code: "DEMO01", locationID: MockData.samplePantry.id, name: MockData.samplePantry.name, address: MockData.samplePantry.address))
    }
    .environment(AppEnvironment.preview())
}
