import Foundation

/// The two yes/no answers from the Discounts tab.
public struct EligibilityAnswers: Sendable, Hashable, Codable {
    public var householdReceivesSNAP: Bool
    public var isK12Student: Bool

    public init(householdReceivesSNAP: Bool = false, isK12Student: Bool = false) {
        self.householdReceivesSNAP = householdReceivesSNAP
        self.isK12Student = isK12Student
    }

    public static let none = EligibilityAnswers()
}

public enum Eligibility {
    /// Discount categories the user qualifies for, best first.
    ///
    /// Access (SNAP) is listed before Student on purpose: the Access permit works every day and
    /// every hour for four years, while the student fare only applies on school days 5:30am–8:30pm.
    /// The Student fare is cheaper, so callers may still surface it as an alternative.
    public static func eligibleRiders(for answers: EligibilityAnswers) -> [RiderCategory] {
        var riders: [RiderCategory] = []
        if answers.householdReceivesSNAP { riders.append(.reducedAccess) }
        if answers.isK12Student { riders.append(.student) }
        return riders
    }

    /// The single program key to feature in the result card, or `nil` for full fare.
    public static func primaryProgramKey(for answers: EligibilityAnswers) -> String? {
        eligibleRiders(for: answers).first?.programKey
    }
}
