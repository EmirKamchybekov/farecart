import SwiftUI
import CoreLocation
import FarecartKit

/// First launch: language → location → discounts → optional account. Skippable at any point.
struct OnboardingView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AccountModel.self) private var account
    @AppStorage(OnboardingKeys.done) private var onboardingDone = false
    @State private var page = DebugLaunch.onboardingPage

    private let pageCount = 4

    var body: some View {
        ZStack(alignment: .top) {
            Color(.systemGroupedBackground).ignoresSafeArea()
            TabView(selection: $page) {
                WelcomePage(next: advance).tag(0)
                LocationPage(next: advance).tag(1)
                DiscountsPage(next: advance).tag(2)
                AccountPage(finish: finish).tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            HStack {
                Spacer()
                Button {
                    finish()
                } label: {
                    Text("Skip")
                        .font(.body.weight(.semibold))
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.glass)
                .padding(.horizontal, Spacing.m)
                .accessibilityLabel("Skip the welcome screens")
            }
        }
        .onChange(of: account.isSignedIn) { _, signedIn in
            if signedIn { finish() }
        }
    }

    private func advance() {
        withAnimation(.snappy) { page = min(page + 1, pageCount - 1) }
    }

    private func finish() {
        withAnimation(.snappy) { onboardingDone = true }
    }
}

/// Shared layout: big icon, title, text, then the page's own content and buttons at the bottom.
private struct OnboardingPage<Content: View, Actions: View>: View {
    let systemImage: String
    /// Show the Farecart logo instead of the SF Symbol (welcome page).
    var logo = false
    let title: LocalizedStringResource
    let text: LocalizedStringResource
    /// `scrollTo` is set by a page that wants to reveal something that appeared below the fold.
    var scrollTo: String? = nil
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    pageBody
                }
                .onChange(of: scrollTo) { _, target in
                    guard let target else { return }
                    withAnimation(.snappy) { proxy.scrollTo(target, anchor: .bottom) }
                }
                .task {
                    // Answers already given (returning user): reveal the payoff straight away.
                    guard let scrollTo else { return }
                    try? await Task.sleep(for: .milliseconds(400))
                    withAnimation(.snappy) { proxy.scrollTo(scrollTo, anchor: .bottom) }
                }
            }
            VStack(spacing: Spacing.s) {
                actions
            }
            .padding(.horizontal, Spacing.m)
            .padding(.bottom, 44)   // above the page dots
        }
    }

    private var pageBody: some View {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    Group {
                        if logo {
                            Image("Logo")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 88, height: 88)
                                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                                .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
                        } else {
                            Image(systemName: systemImage)
                                .font(.system(size: 44, weight: .bold))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .padding(.top, Spacing.l)
                    .accessibilityHidden(true)
                    Text(title)
                        .font(.largeTitle.weight(.bold))
                    Text(text)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Spacing.m)
                .padding(.top, Spacing.l)
                .padding(.bottom, Spacing.m)
    }
}

private struct WelcomePage: View {
    let next: () -> Void

    var body: some View {
        OnboardingPage(systemImage: "basket.fill", logo: true, title: "Welcome to Farecart", text: "Find food near you and get there for less on the CTA. First, pick your language.") {
            VStack(spacing: 0) {
                LanguageRows(large: true)
                    .padding(.horizontal, Spacing.m)
            }
            .padding(.vertical, Spacing.xs)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        } actions: {
            Button(action: next) {
                BigButtonLabel(title: "Continue", systemImage: "arrow.right")
            }
            .buttonStyle(.glassProminent)
        }
    }
}

private struct LocationPage: View {
    @Environment(AppEnvironment.self) private var environment
    let next: () -> Void
    @State private var isAsking = false

    var body: some View {
        OnboardingPage(systemImage: "location.fill", title: "Find food near you", text: "Farecart uses your location only to find grocery stores, pantries and giveaways nearby. It is never stored. You can type an address instead at any time.") {
            EmptyView()
        } actions: {
            Button {
                isAsking = true
                Task {
                    _ = await environment.location.requestWhenInUsePermission()
                    isAsking = false
                    next()
                }
            } label: {
                BigButtonLabel(title: "Allow location", systemImage: "location.fill")
            }
            .buttonStyle(.glassProminent)
            .disabled(isAsking)
            Button(action: next) {
                BigButtonLabel(title: "Type an address instead", systemImage: "magnifyingglass")
            }
            .buttonStyle(.glass)
        }
    }
}

private struct DiscountsPage: View {
    @Environment(AppEnvironment.self) private var environment
    @AppStorage(DiscountsKeys.householdSNAP) private var householdSNAP = false
    @AppStorage(DiscountsKeys.isStudent) private var isStudent = false
    @AppStorage(DiscountsKeys.hasAnswered) private var hasAnswered = false
    let next: () -> Void

    private var answers: EligibilityAnswers {
        EligibilityAnswers(householdReceivesSNAP: householdSNAP, isK12Student: isStudent)
    }

    var body: some View {
        OnboardingPage(systemImage: "ticket.fill", title: "Ride for less?", text: "Two quick questions. Your answers stay on this phone.",
                       scrollTo: hasAnswered ? "payoff-\(householdSNAP)-\(isStudent)" : nil) {
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
                payoff
                    .id("payoff-\(householdSNAP)-\(isStudent)")
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        } actions: {
            Button(action: next) {
                BigButtonLabel(title: "Continue", systemImage: "arrow.right")
            }
            .buttonStyle(.glassProminent)
        }
        .animation(.snappy, value: hasAnswered)
        .animation(.snappy, value: answers)
    }

    /// "You could pay $1.10 instead of $2.25 per bus ride." straight from the `fares` rows.
    @ViewBuilder
    private var payoff: some View {
        let calculator = environment.fareStore.calculator
        if let quote = calculator.quote(mode: .bus, answers: answers) {
            let locale = AppLanguage.effectiveLocale
            HStack(alignment: .top, spacing: Spacing.s) {
                Image(systemName: quote.hasDiscount ? "checkmark.seal.fill" : "info.circle.fill")
                    .font(.title2)
                    .foregroundStyle(quote.hasDiscount ? .green : Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    if quote.hasDiscount {
                        Text("You could pay \(quote.priceText(locale: locale)) instead of \(quote.fullPriceText(locale: locale)) per bus ride.")
                            .font(.title3.weight(.semibold))
                        Text("The Discounts tab shows how to sign up.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("A bus ride costs \(quote.fullPriceText(locale: locale)). If that changes, update your answers in Discounts.")
                            .font(.title3.weight(.semibold))
                    }
                }
            }
            .card()
            .accessibilityElement(children: .combine)
        }
    }
}

private struct AccountPage: View {
    let finish: () -> Void

    var body: some View {
        OnboardingPage(systemImage: "person.crop.circle", title: "Keep your settings", text: "Sign in with Apple or Google to save your answers, language and theme if you change phones. This is optional.") {
            SignInButtons()
        } actions: {
            Button(action: finish) {
                BigButtonLabel(title: "Continue without an account", systemImage: "arrow.right")
            }
            .buttonStyle(.glassProminent)
        }
    }
}

#Preview {
    OnboardingView()
        .environment(AppEnvironment.preview())
        .environment(AccountModel())
}
