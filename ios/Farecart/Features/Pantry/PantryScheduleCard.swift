import SwiftUI
import FarecartKit

/// "Schedule a visit": the next days with open slots as a horizontal day picker, then the slots
/// of the chosen day as chips ("10:00 AM · 3 spots left"). Tapping a chip opens `BookingSheet`.
/// Without slots: walk-ins during open hours, with the phone number.
struct PantryScheduleCard: View {
    let place: Place
    let availability: PantryAvailability?
    let isLoading: Bool
    /// Switches the place screen to its Directions tab (from the confirmation screen).
    var onDirections: () -> Void = {}

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.calendar) private var calendar
    @State private var selectedDay: Date?
    @State private var bookingSlot: PantrySlot?
    @State private var showingVisit: PantryVisit?

    private var days: [(day: Date, slots: [PantrySlot])] {
        availability?.slotsByDay(calendar: calendar) ?? []
    }

    private var currentDay: (day: Date, slots: [PantrySlot])? {
        if let selectedDay, let match = days.first(where: { $0.day == selectedDay }) { return match }
        return days.first
    }

    private var existingVisit: PantryVisit? { environment.pantry.upcomingVisit(at: place.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack {
                SectionCaption("Schedule a visit")
                Spacer()
                if isLoading && availability == nil {
                    ProgressView().controlSize(.small)
                }
            }
            if let existingVisit {
                bookedRow(existingVisit)
            }
            if !days.isEmpty {
                dayPicker
                if let currentDay {
                    slotGrid(currentDay.slots)
                }
                Text("Booking holds your spot for the time you pick. No account needed, and you can cancel any time.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if !isLoading || availability != nil {
                walkInState
            }
        }
        .card()
        .sheet(item: $bookingSlot) { slot in
            BookingSheet(place: place, slot: slot, onDirections: onDirections)
        }
        .sheet(item: $showingVisit) { visit in
            NavigationStack {
                VisitConfirmationView(visit: visit, onDirections: {
                    showingVisit = nil
                    onDirections()
                })
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showingVisit = nil }
                    }
                }
            }
        }
        #if DEBUG
        .task(id: availability?.slots.count ?? -1) {
            // `-farecart-open-booking` opens the sheet on the first open slot; `-farecart-book-first-slot`
            // also confirms it (BookingSheet). Both are screenshot helpers for Debug builds.
            let arguments = ProcessInfo.processInfo.arguments
            guard arguments.contains("-farecart-open-booking") || arguments.contains("-farecart-book-first-slot"),
                  bookingSlot == nil,
                  let slot = availability?.upcomingSlots().first(where: { $0.isBookable() }) else { return }
            try? await Task.sleep(for: .seconds(1))
            bookingSlot = slot
        }
        #endif
    }

    // MARK: Pieces

    private func bookedRow(_ visit: PantryVisit) -> some View {
        Button {
            showingVisit = visit
        } label: {
            HStack(spacing: Spacing.s) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("You're booked")
                        .font(.headline)
                    Text(VisitFormat.dayAndTime(visit.startsAt))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: Spacing.xs)
                Text(visit.confirmationCode)
                    .font(.body.weight(.bold).monospaced())
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(Spacing.s)
            .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows your confirmation code and lets you cancel")
    }

    private var dayPicker: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Spacing.xs) {
                ForEach(days, id: \.day) { entry in
                    let selected = entry.day == (currentDay?.day ?? entry.day)
                    Button {
                        withAnimation(.snappy) { selectedDay = entry.day }
                    } label: {
                        VStack(spacing: 2) {
                            Text(dayLabel(entry.day))
                                .font(.caption.weight(.semibold))
                                .textCase(.uppercase)
                            Text(VisitFormat.dayNumber(entry.day))
                                .font(.title3.weight(.bold))
                                .monospacedDigit()
                        }
                        .frame(minWidth: 56, minHeight: 60)
                        .padding(.horizontal, 6)
                        .background(selected ? Color.accentColor : Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
                        .foregroundStyle(selected ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(VisitFormat.day(entry.day)))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
        .scrollIndicators(.hidden)
        .contentMargins(.vertical, 2, for: .scrollContent)
    }

    private func dayLabel(_ day: Date) -> String {
        if calendar.isDateInToday(day) { return String(localized: "Today", bundle: LanguageBundle.current) }
        if calendar.isDateInTomorrow(day) { return String(localized: "Tomorrow", bundle: LanguageBundle.current) }
        return VisitFormat.weekday(day)
    }

    private func slotGrid(_ slots: [PantrySlot]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: Spacing.xs)], alignment: .leading, spacing: Spacing.xs) {
            ForEach(slots) { slot in
                SlotChip(slot: slot) {
                    bookingSlot = slot
                }
            }
        }
    }

    private var walkInState: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Label("Walk-ins welcome during open hours", systemImage: "figure.walk")
                .foregroundStyle(.secondary)
            if let phone = place.phone, let url = place.phoneURL {
                Link(destination: url) {
                    Label(phone, systemImage: "phone.fill")
                }
                .font(.body.weight(.semibold))
            }
        }
    }
}

/// One slot: its start time, then "3 spots left" / "Full". Disabled when full or past.
struct SlotChip: View {
    let slot: PantrySlot
    let action: () -> Void

    private var bookable: Bool { slot.isBookable() }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(VisitFormat.time(slot.startsAt))
                    .font(.headline)
                    .monospacedDigit()
                Group {
                    if slot.isFull {
                        Text("Full")
                    } else {
                        Text("\(slot.remaining) spots left")
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(slot.isFull ? Color.secondary : (slot.remaining <= 2 ? Color.orange : Color.green))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.s)
            .padding(.vertical, 10)
            .background(bookable ? Color.accentColor.opacity(0.12) : Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                    .strokeBorder(bookable ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!bookable)
        .foregroundStyle(bookable ? .primary : .secondary)
        .accessibilityElement(children: .combine)
        .accessibilityHint(bookable ? Text("Books a visit at this time") : Text(verbatim: ""))
    }
}

#Preview("Slots") {
    let environment = AppEnvironment.preview()
    ScrollView {
        VStack(spacing: Spacing.m) {
            PantryScheduleCard(place: MockData.samplePantry, availability: PantryAvailability(slots: MockPantryService.demoSlots(for: MockData.samplePantry, now: Date(), seed: 0)), isLoading: false)
            PantryScheduleCard(place: MockData.samplePantry, availability: .empty, isLoading: false)
        }
        .padding()
    }
    .background(Color(.systemGroupedBackground))
    .environment(environment)
    .environment(AccountModel())
}
