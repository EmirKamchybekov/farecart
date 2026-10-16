import SwiftUI
import FarecartKit

/// "Add a slot": day, start time, 30 or 60 minutes, capacity. Saves through `staff_upsert_slot`.
struct StaffSlotEditorView: View {
    let session: StaffSession
    var onSaved: (PantrySlot) -> Void

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.calendar) private var calendar
    @State private var day = Date()
    @State private var startTime = StaffSlotEditorView.nextHour()
    @State private var minutes = 30
    @State private var capacity = 10
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var startsAt: Date {
        let time = calendar.dateComponents([.hour, .minute], from: startTime)
        return calendar.date(bySettingHour: time.hour ?? 9, minute: time.minute ?? 0, second: 0, of: day) ?? day
    }

    private var endsAt: Date { startsAt.addingTimeInterval(TimeInterval(minutes * 60)) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Day", selection: $day, in: calendar.startOfDay(for: Date())..., displayedComponents: .date)
                    DatePicker("Start time", selection: $startTime, displayedComponents: .hourAndMinute)
                    Picker("Length", selection: $minutes) {
                        Text("30 min").tag(30)
                        Text("60 min").tag(60)
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(VisitFormat.timeRange(startsAt, endsAt))
                }
                Section {
                    Stepper(value: $capacity, in: 1...60) {
                        HStack {
                            Text("Capacity")
                            Spacer()
                            Text("\(capacity) people")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                } footer: {
                    Text("How many households can book this time. People see \"spots left\" counting down from here.")
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add a slot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving { ProgressView() } else { Text("Save").bold() }
                    }
                    .disabled(isSaving || endsAt <= Date())
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let slot = try await environment.pantry.service.staffUpsertSlot(code: session.code, slotID: nil, startsAt: startsAt, endsAt: endsAt, capacity: capacity, notes: nil)
            onSaved(slot)
            dismiss()
        } catch {
            errorMessage = PantryError.wrap(error).userMessage
        }
    }

    /// The next full hour, so a slot added mid-morning defaults to something sensible.
    static func nextHour(from date: Date = Date()) -> Date {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: date)
        return calendar.date(bySettingHour: min(hour + 1, 23), minute: 0, second: 0, of: date) ?? date
    }
}

#Preview {
    StaffSlotEditorView(session: StaffSession(code: "DEMO01", locationID: MockData.samplePantry.id, name: "Pantry", address: "")) { _ in }
        .environment(AppEnvironment.preview())
}
