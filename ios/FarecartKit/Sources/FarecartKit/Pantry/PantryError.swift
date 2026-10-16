import Foundation

/// Typed failures from the pantry functions. PostgREST reports a `raise exception` as HTTP 400
/// with `{"code":"P0001","message":"slot_full"}`; the message is the contract.
public enum PantryError: Error, Sendable, Hashable {
    case slotFull
    case slotPast
    case alreadyBooked
    case badCode
    case slotNotFound
    case visitNotFound
    case alreadyArrived
    case visitCancelled
    case capacityBelowBooked
    case badTimes
    /// Any other `message` the server raised.
    case server(String)
    /// Transport, HTTP or decoding failure (already described).
    case network(String)

    public init(message: String) {
        switch message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "slot_full": self = .slotFull
        case "slot_past": self = .slotPast
        case "already_booked": self = .alreadyBooked
        case "bad_code": self = .badCode
        case "slot_not_found": self = .slotNotFound
        case "visit_not_found": self = .visitNotFound
        case "already_arrived": self = .alreadyArrived
        case "visit_cancelled": self = .visitCancelled
        case "capacity_below_booked": self = .capacityBelowBooked
        case "bad_times": self = .badTimes
        default: self = .server(message)
        }
    }

    /// Maps whatever the transport threw. A 4xx PostgREST body with a `message` becomes the typed
    /// case; everything else is `.network`.
    public static func wrap(_ error: any Error) -> PantryError {
        if let pantry = error as? PantryError { return pantry }
        if case APIError.httpStatus(let code, let body) = error {
            if let message = Self.message(fromBody: body) {
                let mapped = PantryError(message: message)
                if case .server = mapped, code >= 500 { return .network("Server error \(code).") }
                return mapped
            }
            return .network("Server error \(code).")
        }
        if let api = error as? APIError { return .network(api.localizedDescription) }
        if (error as NSError).domain == NSURLErrorDomain { return .network("You seem to be offline.") }
        return .network(error.localizedDescription)
    }

    static func message(fromBody body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = object["message"] as? String, !message.isEmpty else { return nil }
        return message
    }

    /// Stable identifier for logging and tests (`slot_full`, …).
    public var code: String {
        switch self {
        case .slotFull: "slot_full"
        case .slotPast: "slot_past"
        case .alreadyBooked: "already_booked"
        case .badCode: "bad_code"
        case .slotNotFound: "slot_not_found"
        case .visitNotFound: "visit_not_found"
        case .alreadyArrived: "already_arrived"
        case .visitCancelled: "visit_cancelled"
        case .capacityBelowBooked: "capacity_below_booked"
        case .badTimes: "bad_times"
        case .server(let message): message
        case .network: "network"
        }
    }
}

extension PantryError: LocalizedError {
    /// English fallback; the app shows its own localized copy per case.
    public var errorDescription: String? {
        switch self {
        case .slotFull: "That time just filled up. Pick another one."
        case .slotPast: "That time has already passed."
        case .alreadyBooked: "You already have a visit booked for that time."
        case .badCode: "That code didn't work. Check it and try again."
        case .slotNotFound: "That time is no longer available."
        case .visitNotFound: "We couldn't find that visit."
        case .alreadyArrived: "This visit was already checked in."
        case .visitCancelled: "This visit was cancelled."
        case .capacityBelowBooked: "More people are booked than that. Raise the capacity."
        case .badTimes: "The end time must be after the start time."
        case .server(let message): "The pantry service answered: \(message)."
        case .network(let message): message
        }
    }
}
