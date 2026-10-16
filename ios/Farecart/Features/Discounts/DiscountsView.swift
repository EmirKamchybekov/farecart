import SwiftUI
import UIKit
import FarecartKit

/// UserDefaults keys shared by the Discounts tab and the fare line on place detail.
enum DiscountsKeys {
    static let householdSNAP = "answers.householdSNAP"
    static let isStudent = "answers.isStudent"
    static let hasAnswered = "answers.hasAnswered"
}

/// Tab 2: two big yes/no questions, then which program fits and how to sign up.
/// The same questions appear in onboarding; both read and write the same `DiscountsKeys`.
struct DiscountsView: View {
    @Environment(AppEnvironment.self) private var environment
    @AppStorage(DiscountsKeys.householdSNAP) private var householdSNAP = false
    @AppStorage(DiscountsKeys.isStudent) private var isStudent = false
    @AppStorage(DiscountsKeys.hasAnswered) private var hasAnswered = false

    private var answers: EligibilityAnswers {
        EligibilityAnswers(householdReceivesSNAP: householdSNAP, isK12Student: isStudent)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.m) {
                    Text("Answer two questions to see if you can ride CTA for less.")
                        .font(.title3.weight(.medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, Spacing.xs)

                    YesNoCard(
                        question: "Does anyone in your household get SNAP?",
                        detail: "SNAP is also called food stamps or the Link card.",
                        systemImage: "fork.knife",
                        answer: $householdSNAP,
                        hasAnswered: $hasAnswered
                    )
                    YesNoCard(
                        question: "Are you a K–12 student?",
                        detail: "Any grade from kindergarten through 12th grade.",
                        systemImage: "backpack.fill",
                        answer: $isStudent,
                        hasAnswered: $hasAnswered
                    )

                    if hasAnswered {
                        resultSection
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding(Spacing.m)
                .animation(.snappy, value: hasAnswered)
                .animation(.snappy, value: answers)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Discounts")
            .task { await environment.fareStore.loadIfNeeded() }
            .refreshable { await environment.fareStore.reload() }
        }
    }

    @ViewBuilder
    private var resultSection: some View {
        let store = environment.fareStore
        let riders = Eligibility.eligibleRiders(for: answers)
        if riders.isEmpty {
            FullFareCard(calculator: store.calculator)
        } else {
            ForEach(riders, id: \.self) { rider in
                if let program = store.program(forKey: rider.programKey) {
                    ProgramCard(program: program, rider: rider, calculator: store.calculator, isPrimary: rider == riders.first)
                }
            }
        }
        if store.isUsingFallback {
            Label("Showing last known prices and program details (offline).", systemImage: "wifi.slash")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

/// One question with two large Yes / No buttons.
struct YesNoCard: View {
    let question: LocalizedStringResource
    let detail: LocalizedStringResource
    let systemImage: String
    @Binding var answer: Bool
    @Binding var hasAnswered: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Label {
                Text(question).font(.title3.weight(.semibold))
            } icon: {
                Image(systemName: systemImage).foregroundStyle(Color.accentColor)
            }
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            GlassEffectContainer(spacing: Spacing.s) {
                HStack(spacing: Spacing.s) {
                    choice(title: "Yes", value: true)
                    choice(title: "No", value: false)
                }
            }
        }
        .card()
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func choice(title: LocalizedStringResource, value: Bool) -> some View {
        let selected = hasAnswered && answer == value
        Button {
            withAnimation(.snappy) {
                answer = value
                hasAnswered = true
            }
        } label: {
            Text(title)
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 36)
                .padding(.vertical, 6)
        }
        .buttonStyle(.glass)
        .tint(selected ? .accentColor : nil)
        .foregroundStyle(selected ? Color.accentColor : .primary)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Reads like a receipt: program name, then per mode a big "$1.10" next to a struck-through "$2.25",
/// one line each for who / what / how, and a big Sign up button.
struct ProgramCard: View {
    let program: Program
    let rider: RiderCategory
    let calculator: FareCalculator
    var isPrimary = true

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: 4) {
                Label {
                    Group {
                        if isPrimary { Text("You qualify") } else { Text("You may also qualify") }
                    }
                    .font(.caption.weight(.bold))
                    .textCase(.uppercase)
                } icon: {
                    Image(systemName: "checkmark.seal.fill")
                }
                .foregroundStyle(.green)
                Text(program.name)
                    .font(.title2.weight(.bold))
            }

            receipt

            VStack(alignment: .leading, spacing: Spacing.xs) {
                detail(systemImage: "person.2.fill", title: "Who", text: program.who)
                detail(systemImage: "ticket.fill", title: "What", text: program.what)
                detail(systemImage: "signature", title: "How", text: program.how)
            }

            if let url = program.signupLink {
                Link(destination: url) {
                    BigButtonLabel(title: "Sign up", systemImage: "arrow.up.right.square.fill")
                }
                .buttonStyle(.glassProminent)
            }
            HStack(spacing: Spacing.m) {
                if let phone = program.phone, let url = program.phoneURL {
                    Link(destination: url) {
                        Label("Call \(phone)", systemImage: "phone.fill")
                    }
                }
                Spacer(minLength: 0)
                if let source = program.sourceURL, let url = URL(string: source) {
                    Link(destination: url) {
                        Label("Official details", systemImage: "link")
                    }
                }
            }
            .font(.footnote.weight(.medium))
        }
        .card()
    }

    private var receipt: some View {
        VStack(spacing: 0) {
            ForEach(Array(TransitMode.allCases.enumerated()), id: \.element) { index, mode in
                if let discounted = calculator.fare(mode: mode, rider: rider), let full = calculator.fare(mode: mode, rider: .full) {
                    if index > 0 {
                        ReceiptDivider()
                    }
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                        Image(systemName: mode.symbolName)
                            .frame(width: 24)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text(mode.title)
                            .font(.body.weight(.medium))
                        Spacer()
                        Text(Money.format(cents: full.priceCents))
                            .font(.body)
                            .strikethrough()
                            .foregroundStyle(.secondary)
                        Text(Money.format(cents: discounted.priceCents))
                            .font(.system(.title, design: .rounded).weight(.bold))
                            .foregroundStyle(.green)
                            .monospacedDigit()
                    }
                    .padding(.vertical, Spacing.xs)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Text("\(Text(mode.title)): \(Money.format(cents: discounted.priceCents)) instead of \(Money.format(cents: full.priceCents))"))
                }
            }
            if let savings = perRideSavings {
                ReceiptDivider()
                HStack {
                    Text("You save per ride")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Pill(text: Text(savings), systemImage: "arrow.down", tint: .green)
                }
                .padding(.top, Spacing.xs)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, Spacing.xs)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
    }

    /// "$1.15" when the saving is the same on bus and train, else "$1.15–$1.25".
    private var perRideSavings: String? {
        let savings = TransitMode.allCases.compactMap { mode -> Int? in
            guard let d = calculator.fare(mode: mode, rider: rider), let f = calculator.fare(mode: mode, rider: .full) else { return nil }
            return f.priceCents - d.priceCents
        }.filter { $0 > 0 }
        guard let low = savings.min(), let high = savings.max() else { return nil }
        return low == high ? Money.format(cents: low) : "\(Money.format(cents: low))–\(Money.format(cents: high))"
    }

    private func detail(systemImage: String, title: LocalizedStringResource, text: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
                .padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                SectionCaption(title)
                Text(text)
                    .font(.subheadline)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Dashed line between receipt rows.
private struct ReceiptDivider: View {
    var body: some View {
        Line()
            .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            .foregroundStyle(Color(.separator))
            .frame(height: 1)
            .accessibilityHidden(true)
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return path
        }
    }
}

/// Shown when neither answer applies.
struct FullFareCard: View {
    let calculator: FareCalculator

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Full fare")
                .font(.title2.weight(.bold))
            Text("Based on your answers you pay the regular CTA fare.")
                .foregroundStyle(.secondary)
            VStack(spacing: Spacing.xs) {
                ForEach(TransitMode.allCases) { mode in
                    if let full = calculator.fare(mode: mode, rider: .full) {
                        HStack {
                            Image(systemName: mode.symbolName).frame(width: 24).foregroundStyle(.secondary)
                            Text(mode.title)
                            Spacer()
                            Text(Money.format(cents: full.priceCents))
                                .font(.system(.title3, design: .rounded).weight(.bold))
                                .monospacedDigit()
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .padding(Spacing.s)
            .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
            Text("If your situation changes, come back and update your answers. Seniors and people with disabilities may qualify for other RTA reduced fares.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .card()
    }
}

#Preview {
    DiscountsView()
        .environment(AppEnvironment.preview())
}
