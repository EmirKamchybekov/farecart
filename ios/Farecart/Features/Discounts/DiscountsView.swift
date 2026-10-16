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
struct DiscountsView: View {
    @Environment(AppEnvironment.self) private var environment
    @AppStorage(DiscountsKeys.householdSNAP) private var householdSNAP = false
    @AppStorage(DiscountsKeys.isStudent) private var isStudent = false
    @AppStorage(DiscountsKeys.hasAnswered) private var hasAnswered = false
    @State private var showsAbout = false

    private var answers: EligibilityAnswers {
        EligibilityAnswers(householdReceivesSNAP: householdSNAP, isK12Student: isStudent)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Text("Answer two questions to see if you can ride CTA for less.")
                        .font(.title3)
                        .frame(maxWidth: .infinity, alignment: .leading)

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
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Discounts")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showsAbout = true
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .accessibilityLabel("About Farecart")
                }
            }
            .sheet(isPresented: $showsAbout) { AboutView() }
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
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text(question).font(.title3.weight(.semibold))
            } icon: {
                Image(systemName: systemImage).foregroundStyle(Color.accentColor)
            }
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    choice(title: "Yes", value: true)
                    choice(title: "No", value: false)
                }
            }
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 20))
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

/// Program name, your price vs full price, how to sign up, Sign up button, phone.
struct ProgramCard: View {
    let program: Program
    let rider: RiderCategory
    let calculator: FareCalculator
    var isPrimary = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
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

            VStack(alignment: .leading, spacing: 8) {
                ForEach(TransitMode.allCases) { mode in
                    if let discounted = calculator.fare(mode: mode, rider: rider), let full = calculator.fare(mode: mode, rider: .full) {
                        HStack(alignment: .firstTextBaseline) {
                            Image(systemName: mode.symbolName).frame(width: 24).foregroundStyle(.secondary)
                            Text(mode.title)
                            Spacer()
                            Text(Money.format(cents: full.priceCents))
                                .strikethrough()
                                .foregroundStyle(.secondary)
                            Text(Money.format(cents: discounted.priceCents))
                                .font(.title3.weight(.bold))
                                .foregroundStyle(.green)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(Text("\(Text(mode.title)): \(Money.format(cents: discounted.priceCents)) instead of \(Money.format(cents: full.priceCents))"))
                    }
                }
            }
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))

            detail(title: "Who qualifies", text: program.who)
            detail(title: "What you get", text: program.what)
            detail(title: "How to sign up", text: program.how)

            if let url = program.signupLink {
                Link(destination: url) {
                    BigButtonLabel(title: "Sign up", systemImage: "arrow.up.right.square.fill")
                }
                .buttonStyle(.glassProminent)
            }
            if let phone = program.phone, let url = program.phoneURL {
                Link(destination: url) {
                    BigButtonLabel(title: "Call \(phone)", systemImage: "phone.fill")
                }
                .buttonStyle(.glass)
            }
            if let source = program.sourceURL, let url = URL(string: source) {
                Link(destination: url) {
                    Label("Official details", systemImage: "link").font(.footnote)
                }
            }
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 20))
    }

    private func detail(title: LocalizedStringResource, text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            Text(text)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Shown when neither answer applies.
struct FullFareCard: View {
    let calculator: FareCalculator

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Full fare")
                .font(.title2.weight(.bold))
            Text("Based on your answers you pay the regular CTA fare.")
                .foregroundStyle(.secondary)
            ForEach(TransitMode.allCases) { mode in
                if let full = calculator.fare(mode: mode, rider: .full) {
                    HStack {
                        Image(systemName: mode.symbolName).frame(width: 24).foregroundStyle(.secondary)
                        Text(mode.title)
                        Spacer()
                        Text(Money.format(cents: full.priceCents)).font(.title3.weight(.semibold))
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            Text("If your situation changes, come back and update your answers. Seniors and people with disabilities may qualify for other RTA reduced fares.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 20))
    }
}

#Preview {
    DiscountsView()
        .environment(AppEnvironment.preview())
}
