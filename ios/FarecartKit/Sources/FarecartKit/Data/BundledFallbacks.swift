import Foundation

/// Last-known copies of the `fares` and `programs` rows, used only when the network is
/// unavailable. They mirror `supabase/migrations/0001_init.sql` and the UI labels them as
/// "last known" so nobody mistakes them for live prices. The live tables are the source of truth.
public enum BundledFallbacks {
    public static let effectiveOn = PostgresDate.parse("2026-10-01")

    public static let fares: [Fare] = [
        Fare(id: 1, mode: .bus, rider: .full, priceCents: 225, label: "Full fare bus", effectiveOn: effectiveOn,
             sourceURL: "https://www.transitchicago.com/fares/"),
        Fare(id: 2, mode: .train, rider: .full, priceCents: 250, label: "Full fare train", effectiveOn: effectiveOn,
             sourceURL: "https://www.transitchicago.com/fares/"),
        Fare(id: 3, mode: .bus, rider: .reducedAccess, priceCents: 110, label: "Access reduced fare bus",
             howToGet: "Apply for an Access permit (SNAP households)", signupURL: "https://getaccess.org",
             effectiveOn: effectiveOn, sourceURL: "https://nita.illinois.gov/riders/access"),
        Fare(id: 4, mode: .train, rider: .reducedAccess, priceCents: 125, label: "Access reduced fare train",
             howToGet: "Apply for an Access permit (SNAP households)", signupURL: "https://getaccess.org",
             effectiveOn: effectiveOn, sourceURL: "https://nita.illinois.gov/riders/access"),
        Fare(id: 5, mode: .bus, rider: .student, priceCents: 75, label: "Student reduced fare bus",
             howToGet: "Ventra Student Card from your school, school days only",
             signupURL: "https://www.transitchicago.com/fares/reduced-fare/", effectiveOn: effectiveOn,
             sourceURL: "https://www.transitchicago.com/fares/reduced-fare/"),
        Fare(id: 6, mode: .train, rider: .student, priceCents: 75, label: "Student reduced fare train",
             howToGet: "Ventra Student Card from your school, school days only",
             signupURL: "https://www.transitchicago.com/fares/reduced-fare/", effectiveOn: effectiveOn,
             sourceURL: "https://www.transitchicago.com/fares/reduced-fare/"),
    ]

    public static let programs: [Program] = [
        Program(
            key: "access",
            name: "Access reduced fare",
            who: "Anyone in a household that receives SNAP in Cook, DuPage, Kane, Lake, McHenry or Will County.",
            what: "Half-price rides: $1.10 CTA bus, $1.25 CTA train, $1 Pace. Permit lasts 4 years.",
            how: "Apply online at GetAccess.org with your SNAP decision letter and a state ID with the same address (ages 12–64).",
            signupURL: "https://getaccess.org",
            phone: "312-913-3110",
            sourceURL: "https://nita.illinois.gov/riders/access"
        ),
        Program(
            key: "student",
            name: "Student reduced fare",
            who: "K–12 students (ages 7–20) on school days.",
            what: "Reduced fare of $0.75 per ride on CTA bus and train on school days, 5:30am–8:30pm.",
            how: "Ask your school for a Ventra Student Card. CPS students: see your school office.",
            signupURL: "https://www.transitchicago.com/fares/reduced-fare/",
            phone: nil,
            sourceURL: "https://www.transitchicago.com/fares/reduced-fare/"
        ),
    ]
}
