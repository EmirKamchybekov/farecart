import Foundation
import Observation
import FarecartKit

/// Pantry stock, visit slots and the phone's bookings (root README, "Pantry inventory and visit
/// scheduling"). One per app; `AppEnvironment.pantry`. Availability is cached per place for the
/// session so the results list can show a "Book a visit" pill without extra calls; the device id
/// and the staff session live in the Keychain through `SecureStore`.
@MainActor
@Observable
final class PantryStore {
    let service: any PantryService
    let feedAmerica: FeedAmericaClient?
    let deviceID: String
    private let secureStore: any SecureStore
    private static let staffKey = "farecart.staff_session"

    /// Everything `my_visits` returned, upcoming first.
    private(set) var visits: [PantryVisit] = []
    private(set) var visitsLoaded = false
    private(set) var isLoadingVisits = false
    private(set) var visitsError: String?
    /// Per-place availability fetched this session (merged with Feed America when known).
    private(set) var availability: [UUID: PantryAvailability] = [:]
    private(set) var staffSession: StaffSession?

    init(service: any PantryService, secureStore: any SecureStore, feedAmerica: FeedAmericaClient? = FeedAmericaClient()) {
        self.service = service
        self.secureStore = secureStore
        self.feedAmerica = feedAmerica
        self.deviceID = DeviceID.current(store: secureStore)
        if let raw = try? secureStore.readString(key: Self.staffKey),
           let session = try? JSONDecoder().decode(StaffSession.self, from: Data(raw.utf8)) {
            staffSession = session
        }
    }

    // MARK: Visits

    var upcomingVisits: [PantryVisit] {
        visits.filter { $0.isUpcoming() }.sorted { $0.startsAt < $1.startsAt }
    }

    var pastVisits: [PantryVisit] {
        visits.filter { !$0.isUpcoming() }.sorted { $0.startsAt > $1.startsAt }
    }

    var nextVisit: PantryVisit? { upcomingVisits.first }

    func upcomingVisit(at placeID: UUID) -> PantryVisit? {
        upcomingVisits.first { $0.locationID == placeID }
    }

    private var visitsTask: Task<Void, Never>?

    /// Loads once per launch. Several screens call this; later callers wait for the first load
    /// instead of starting another one, and a load outlives the view that started it.
    func loadVisitsIfNeeded() async {
        if visitsLoaded { return }
        if let visitsTask {
            await visitsTask.value
            if visitsLoaded { return }
        }
        await refreshVisits()
    }

    func refreshVisits() async {
        if let visitsTask, isLoadingVisits {
            await visitsTask.value
            return
        }
        // An unstructured task is not cancelled when the calling view disappears.
        let task = Task { await self.performVisitsLoad() }
        visitsTask = task
        await task.value
    }

    private func performVisitsLoad() async {
        isLoadingVisits = true
        defer { isLoadingVisits = false }
        do {
            visits = try await service.myVisits(deviceID: deviceID)
            visitsLoaded = true
            visitsError = nil
        } catch is CancellationError {
            // Caller went away; the next screen asks again.
        } catch {
            visitsError = PantryError.wrap(error).userMessage
        }
    }

    // MARK: Availability

    func cachedAvailability(for placeID: UUID) -> PantryAvailability? {
        availability[placeID]
    }

    /// `pantry_availability` for this place, plus Feed America's status when the listing has a
    /// `feedam_id`. Cached for the session; `force` reloads.
    @discardableResult
    func loadAvailability(for place: Place, force: Bool = false) async throws -> PantryAvailability {
        if !force, let cached = availability[place.id] { return cached }
        async let base = service.availability(locationID: place.id)
        async let status: FeedAmericaStatus? = {
            guard let feedamID = place.feedamID, let feedAmerica else { return nil }
            return await feedAmerica.status(feedamID: feedamID)
        }()
        let merged = try await base.merging(feedAmerica: await status)
        availability[place.id] = merged
        return merged
    }

    // MARK: Booking

    func book(slot: PantrySlot, at place: Place, partySize: Int, userID: UUID?) async throws -> PantryVisit {
        var visit = try await service.bookVisit(slotID: slot.id, deviceID: deviceID, partySize: partySize, userID: userID)
        if visit.locationID == nil { visit.locationID = place.id }
        if visit.latitude == nil { visit.latitude = place.latitude; visit.longitude = place.longitude }
        if visit.locationName.isEmpty { visit.locationName = place.name }
        if visit.address.isEmpty { visit.address = place.address }
        visits.removeAll { $0.id == visit.id }
        visits.insert(visit, at: 0)
        adjustCachedSlot(placeID: place.id, slotID: slot.id, by: 1)
        return visit
    }

    func cancel(_ visit: PantryVisit) async throws {
        guard let token = visit.cancelToken else { throw PantryError.visitNotFound }
        try await service.cancelVisit(visitID: visit.id, cancelToken: token)
        if let index = visits.firstIndex(where: { $0.id == visit.id }) {
            visits[index].status = .cancelled
        }
        if let placeID = visit.locationID, let slotID = visit.slotID {
            adjustCachedSlot(placeID: placeID, slotID: slotID, by: -1)
        }
    }

    private func adjustCachedSlot(placeID: UUID, slotID: UUID, by delta: Int) {
        guard var cached = availability[placeID], let index = cached.slots.firstIndex(where: { $0.id == slotID }) else { return }
        cached.slots[index].booked = max(0, cached.slots[index].booked + delta)
        availability[placeID] = cached
    }

    // MARK: Staff mode

    var isStaff: Bool { staffSession != nil }

    @discardableResult
    func staffLogin(code: String) async throws -> StaffSession {
        let session = try await service.staffLogin(code: code)
        staffSession = session
        if let data = try? JSONEncoder().encode(session), let raw = String(data: data, encoding: .utf8) {
            try? secureStore.writeString(raw, key: Self.staffKey)
        }
        return session
    }

    func staffSignOut() {
        staffSession = nil
        try? secureStore.removeValue(key: Self.staffKey)
    }

    /// Staff edits change what clients see; drop the cached copy so the detail reloads.
    func invalidateAvailability(for placeID: UUID) {
        availability[placeID] = nil
    }
}

extension PantryError {
    /// Localized, friendly copy for each case (the Kit's `errorDescription` is English only).
    var userMessage: String {
        let bundle = LanguageBundle.current
        switch self {
        case .slotFull: return String(localized: "That time just filled up. Pick another one.", bundle: bundle)
        case .slotPast: return String(localized: "That time has already passed.", bundle: bundle)
        case .alreadyBooked: return String(localized: "You already have a visit booked for that time.", bundle: bundle)
        case .badCode: return String(localized: "That code didn't work. Check it and try again.", bundle: bundle)
        case .slotNotFound: return String(localized: "That time is no longer available.", bundle: bundle)
        case .visitNotFound: return String(localized: "We couldn't find that visit.", bundle: bundle)
        case .alreadyArrived: return String(localized: "This visit was already checked in.", bundle: bundle)
        case .visitCancelled: return String(localized: "This visit was cancelled.", bundle: bundle)
        case .capacityBelowBooked: return String(localized: "More people are booked than that. Raise the capacity.", bundle: bundle)
        case .badTimes: return String(localized: "The end time must be after the start time.", bundle: bundle)
        case .server: return String(localized: "Something went wrong on our side. Please try again.", bundle: bundle)
        case .network: return String(localized: "Could not reach the pantry service. Check your connection and try again.", bundle: bundle)
        }
    }
}
