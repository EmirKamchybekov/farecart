import SwiftUI
import FarecartKit

/// Pick how many people are coming, confirm, and get the confirmation screen in place.
struct BookingSheet: View {
    let place: Place
    let slot: PantrySlot
    var onDirections: () -> Void = {}

    @Environment(AppEnvironment.self) private var environment
    @Environment(AccountModel.self) private var account
    @Environment(\.dismiss) private var dismiss
    @State private var partySize = 1
    @State private var isBooking = false
    @State private var errorMessage: String?
    @State private var visit: PantryVisit?

    var body: some View {
        NavigationStack {
            Group {
                if let visit {
                    VisitConfirmationView(visit: visit, onDirections: {
                        dismiss()
                        onDirections()
                    })
                } else {
                    form
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(visit == nil ? Text("Book a visit") : Text("Your visit"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(visit == nil ? "Cancel" : "Done") { dismiss() }
                }
            }
        }
        .interactiveDismissDisabled(isBooking)
        #if DEBUG
        .task {
            // `-farecart-book-first-slot`: confirm automatically so the flow can be screenshotted.
            guard ProcessInfo.processInfo.arguments.contains("-farecart-book-first-slot"), visit == nil else { return }
            try? await Task.sleep(for: .seconds(1.5))
            await book()
        }
        #endif
    }

    private var form: some View {
        ScrollView {
            VStack(spacing: Spacing.m) {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    InfoRow(systemImage: "calendar", tint: .accentColor, title: "When") {
                        Text(VisitFormat.day(slot.startsAt)).fontWeight(.semibold)
                        Text(VisitFormat.timeRange(slot.startsAt, slot.endsAt))
                    }
                    Divider()
                    InfoRow(systemImage: "mappin.and.ellipse", tint: .accentColor, title: "Where") {
                        Text(place.name).fontWeight(.semibold)
                        Text(place.address).foregroundStyle(.secondary)
                    }
                }
                .card()

                VStack(alignment: .leading, spacing: Spacing.s) {
                    SectionCaption("People coming")
                    HStack {
                        Text(partySize, format: .number)
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .frame(minWidth: 56)
                        Text("\(partySize) people")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Stepper("People coming", value: $partySize.animation(.snappy), in: 1...6)
                            .labelsHidden()
                            .controlSize(.large)
                    }
                    Text("Count everyone picking up food with you, up to 6. The pantry uses this to plan.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .card()

                if let errorMessage {
                    MessageBanner(text: errorMessage)
                }

                Text("\(Text(place.pantryRequirementsLine)) Your phone keeps a confirmation code; no name, email or account is needed.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
            .padding(.horizontal, Spacing.m)
            .padding(.top, Spacing.xs)
        }
        .floatingBottomBar {
            Button {
                Task { await book() }
            } label: {
                if isBooking {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .padding(.vertical, 8)
                } else {
                    BigButtonLabel(title: "Confirm visit", systemImage: "checkmark")
                }
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.capsule)
            .disabled(isBooking)
        }
    }

    private func book() async {
        guard !isBooking else { return }
        isBooking = true
        errorMessage = nil
        defer { isBooking = false }
        do {
            let booked = try await environment.pantry.book(slot: slot, at: place, partySize: partySize, userID: account.session?.user.id)
            withAnimation(.snappy) { visit = booked }
        } catch {
            let pantryError = PantryError.wrap(error)
            errorMessage = pantryError.userMessage
            if pantryError == .slotFull || pantryError == .slotPast || pantryError == .slotNotFound {
                _ = try? await environment.pantry.loadAvailability(for: place, force: true)
            }
        }
    }
}

#Preview {
    let environment = AppEnvironment.preview()
    let slots = MockPantryService.demoSlots(for: MockData.samplePantry, now: Date(), seed: 0)
    Color.clear
        .sheet(isPresented: .constant(true)) {
            BookingSheet(place: MockData.samplePantry, slot: slots[0])
        }
        .environment(environment)
        .environment(AccountModel())
}
