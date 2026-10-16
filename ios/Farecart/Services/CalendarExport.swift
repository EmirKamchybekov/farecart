import EventKit
import Foundation
import FarecartKit

/// "Add to Calendar" for a booked visit. Write-only access: the app never reads the calendar.
enum CalendarExport {
    enum Outcome: Equatable {
        case added
        case denied
        case failed
    }

    static func add(_ visit: PantryVisit) async -> Outcome {
        let store = EKEventStore()
        do {
            guard try await store.requestWriteOnlyAccessToEvents() else { return .denied }
        } catch {
            return .denied
        }
        let event = EKEvent(eventStore: store)
        let bundle = LanguageBundle.current
        event.title = String(localized: "Pantry visit: \(visit.locationName)", bundle: bundle)
        event.location = visit.address
        event.startDate = visit.startsAt
        event.endDate = visit.endsAt
        event.notes = String(localized: "Confirmation code \(visit.confirmationCode). Booked with Farecart.", bundle: bundle)
        event.calendar = store.defaultCalendarForNewEvents
        event.addAlarm(EKAlarm(relativeOffset: -3600))
        do {
            try store.save(event, span: .thisEvent)
            return .added
        } catch {
            return .failed
        }
    }
}
