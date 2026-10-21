import SwiftUI
import CoreLocation
import FarecartKit

/// One page of the welcome flow. The order depends on the answer to "How will you use Farecart?".
enum OnboardingStep: Hashable {
    case welcome, account, role, location, discounts, staffCode, look

    /// Six pages on either path, so the page dots always match.
    static func steps(for role: UserRole?) -> [OnboardingStep] {
        switch role {
        case .staff: [.welcome, .account, .role, .staffCode, .location, .look]
        case .client, nil: [.welcome, .account, .role, .location, .discounts, .look]
        }
    }
}

/// First launch: language → account → role → (location → discounts) or (staff code → location)
/// → look. Skippable at any point.
struct OnboardingView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AccountModel.self) private var account
    @AppStorage(OnboardingKeys.done) private var onboardingDone = false
    @AppStorage(UserRole.storageKey) private var roleCode: String?
    @State private var page = DebugLaunch.onboardingPage

    private var role: UserRole? { roleCode.flatMap(UserRole.init(rawValue:)) }
    private var steps: [OnboardingStep] { OnboardingStep.steps(for: role) }

    var body: some View {
        ZStack(alignment: .top) {
            Color(.systemGroupedBackground).ignoresSafeArea()
            TabView(selection: $page) {
                ForEach(Array(steps.enumerated()), id: \.element) { index, step in
                    view(for: step).tag(index)
                }
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
    }

    @ViewBuilder
    private func view(for step: OnboardingStep) -> some View {
        switch step {
        case .welcome: WelcomePage(next: advance)
        case .account: AccountPage(next: advance)
        case .role: RolePage(next: advance)
        case .location: LocationPage(next: advance)
        case .discounts: DiscountsPage(next: advance)
        case .staffCode: StaffCodePage(next: advance)
        case .look: ThemePage(finish: finish)
        }
    }

    private func advance() {
        withAnimation(.snappy) { page = min(page + 1, steps.count - 1) }
    }

    private func finish() {
        withAnimation(.snappy) { onboardingDone = true }
        Task { await account.pushProfile() }
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
    @Environment(AccountModel.self) private var account
    @AppStorage(DiscountsKeys.householdSNAP) private var householdSNAP = false
    @AppStorage(DiscountsKeys.isStudent) private var isStudent = false
    @AppStorage(DiscountsKeys.hasAnswered) private var hasAnswered = false
    let next: () -> Void

    private var answers: EligibilityAnswers {
        EligibilityAnswers(householdReceivesSNAP: householdSNAP, isK12Student: isStudent)
    }

    var body: some View {
        OnboardingPage(systemImage: "ticket.fill", title: "Ride for less?",
                       text: account.isSignedIn ? "Two quick questions. Your answers are saved to your account." : "Two quick questions. Your answers stay on this phone.",
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

/// Page 2: create an account (or sign in), or carry on as a guest.
private struct AccountPage: View {
    @Environment(AccountModel.self) private var account
    let next: () -> Void

    var body: some View {
        OnboardingPage(systemImage: "person.crop.circle.fill", title: "Create your account", text: "An account keeps your pantry visits, discount answers and language on every phone you use.") {
            if account.isSignedIn {
                SignedInSummary()
                    .card()
            } else {
                AccountButtons()
            }
        } actions: {
            if account.isSignedIn {
                Button(action: next) {
                    BigButtonLabel(title: "Continue", systemImage: "arrow.right")
                }
                .buttonStyle(.glassProminent)
            } else {
                Button(action: next) {
                    Text("Continue as guest")
                        .font(.subheadline.weight(.semibold))
                        .padding(.vertical, Spacing.xs)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// Page 3: client or pantry staff. The answer picks the rest of the pages.
private struct RolePage: View {
    @AppStorage(UserRole.storageKey) private var roleCode: String?
    let next: () -> Void

    var body: some View {
        OnboardingPage(systemImage: "person.2.fill", title: "How will you use Farecart?", text: "You can change this later in Settings.") {
            RoleCard(role: .client, title: "I'm looking for food", detail: "Find pantries, grocery stores and giveaways nearby, and ride the CTA for less.",
                     systemImage: "basket.fill", selected: roleCode == UserRole.client.rawValue) { choose(.client) }
            RoleCard(role: .staff, title: "I work at a pantry", detail: "Post today's stock, open visit times and check people in.",
                     systemImage: "person.badge.key.fill", selected: roleCode == UserRole.staff.rawValue) { choose(.staff) }
        } actions: {
            Button(action: next) {
                BigButtonLabel(title: "Continue", systemImage: "arrow.right")
            }
            .buttonStyle(.glassProminent)
            .disabled(roleCode == nil)
        }
    }

    private func choose(_ role: UserRole) {
        withAnimation(.snappy) { roleCode = role.rawValue }
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            next()
        }
    }
}

private struct RoleCard: View {
    let role: UserRole
    let title: LocalizedStringResource
    let detail: LocalizedStringResource
    let systemImage: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: Spacing.m) {
                Image(systemName: systemImage)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(selected ? .white : Color.accentColor)
                    .frame(width: 60, height: 60)
                    .background(selected ? Color.accentColor : Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.5))
                    .accessibilityHidden(true)
            }
            .padding(Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2)
            }
            .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Staff path: the 6-character staff code (same check as Settings → Pantry staff).
private struct StaffCodePage: View {
    @Environment(AppEnvironment.self) private var environment
    let next: () -> Void
    @State private var code = ""
    @State private var isBusy = false
    @State private var errorMessage: String?

    private var normalized: String { StaffSession.normalize(code: code) }

    var body: some View {
        OnboardingPage(systemImage: "person.badge.key.fill", title: "Enter your pantry's staff code", text: "Ask your pantry coordinator for the 6-character code. It lets you post today's stock, open visit slots and check people in.") {
            if let session = environment.pantry.staffSession {
                HStack(spacing: Spacing.s) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.title)
                        .foregroundStyle(.green)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("You're set up for")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(verbatim: session.name)
                            .font(.title3.weight(.semibold))
                        if !session.address.isEmpty {
                            Text(verbatim: session.address)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .card()
            } else {
                TextField("Code", text: $code)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospaced()
                    .multilineTextAlignment(.center)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .submitLabel(.go)
                    .onSubmit { Task { await login() } }
                    .onChange(of: code) { _, value in
                        let cleaned = StaffSession.normalize(code: value)
                        if cleaned != value { code = String(cleaned.prefix(8)) }
                    }
                    .padding(.vertical, Spacing.s)
                    .frame(maxWidth: .infinity)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
                    .accessibilityLabel("Staff code")
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }
            }
        } actions: {
            if environment.pantry.staffSession != nil {
                Button(action: next) {
                    BigButtonLabel(title: "Continue", systemImage: "arrow.right")
                }
                .buttonStyle(.glassProminent)
            } else {
                Button {
                    Task { await login() }
                } label: {
                    if isBusy {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 32).padding(.vertical, 8)
                    } else {
                        BigButtonLabel(title: "Continue", systemImage: "arrow.right")
                    }
                }
                .buttonStyle(.glassProminent)
                .disabled(normalized.count < 6 || isBusy)
                Button(action: next) {
                    Text("Skip for now")
                        .font(.subheadline.weight(.semibold))
                        .padding(.vertical, Spacing.xs)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        #if DEBUG
        .task {
            // `-farecart-onboarding-staff-code A7GBQZ`: type the code (screenshots); add
            // `-farecart-auth-submit` to check it, `-farecart-staff-sign-out` to start from no session.
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("-farecart-staff-sign-out") { environment.pantry.staffSignOut() }
            if let index = arguments.firstIndex(of: "-farecart-onboarding-staff-code"), index + 1 < arguments.count, code.isEmpty {
                code = arguments[index + 1]
                if arguments.contains("-farecart-auth-submit") { await login() }
            }
        }
        #endif
    }

    private func login() async {
        guard normalized.count >= 6, !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await environment.pantry.staffLogin(code: normalized)
        } catch {
            errorMessage = PantryError.wrap(error).userMessage
        }
    }
}

/// Last page on both paths: System / Light / Dark as map previews, applied live.
private struct ThemePage: View {
    @AppStorage(AppTheme.storageKey) private var themeCode = AppTheme.system.rawValue
    let finish: () -> Void

    var body: some View {
        OnboardingPage(systemImage: "circle.lefthalf.filled", title: "Choose your look", text: "Pick how Farecart looks. You can change it any time in Settings.") {
            HStack(spacing: Spacing.s) {
                ForEach(AppTheme.allCases) { theme in
                    ThemeTile(theme: theme, selected: themeCode == theme.rawValue) {
                        withAnimation(.snappy) { themeCode = theme.rawValue }
                    }
                }
            }
            .padding(.top, Spacing.xs)
        } actions: {
            Button(action: finish) {
                BigButtonLabel(title: "Start using Farecart", systemImage: "checkmark")
            }
            .buttonStyle(.glassProminent)
        }
    }
}

private struct ThemeTile: View {
    let theme: AppTheme
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: Spacing.xs) {
                Group {
                    switch theme {
                    case .light: MapThumbnail(dark: false)
                    case .dark: MapThumbnail(dark: true)
                    case .system:
                        // Light on the leading half, dark on the trailing half.
                        ZStack {
                            MapThumbnail(dark: false)
                            MapThumbnail(dark: true)
                                .mask(alignment: .trailing) {
                                    GeometryReader { proxy in
                                        Rectangle().frame(width: proxy.size.width / 2).frame(maxWidth: .infinity, alignment: .trailing)
                                    }
                                }
                        }
                    }
                }
                .aspectRatio(0.56, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: selected ? 3 : 1)
                }
                Label {
                    Text(theme.title)
                } icon: {
                    Image(systemName: selected ? "checkmark.circle.fill" : theme.symbolName)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(selected ? Color.accentColor : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A tiny drawing of the Find Food map in one theme: blocks, streets, a park, pins and the
/// results card.
private struct MapThumbnail: View {
    let dark: Bool

    private var land: Color { dark ? Color(red: 0.14, green: 0.15, blue: 0.17) : Color(red: 0.96, green: 0.95, blue: 0.92) }
    private var road: Color { dark ? Color(red: 0.27, green: 0.29, blue: 0.32) : .white }
    private var park: Color { dark ? Color(red: 0.16, green: 0.27, blue: 0.18) : Color(red: 0.80, green: 0.91, blue: 0.78) }
    private var card: Color { dark ? Color(red: 0.11, green: 0.11, blue: 0.12) : .white }
    private var line: Color { dark ? Color.white.opacity(0.25) : Color.black.opacity(0.12) }

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width, h = proxy.size.height
            ZStack(alignment: .topLeading) {
                land
                park
                    .frame(width: w * 0.42, height: h * 0.2)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .offset(x: w * 0.5, y: h * 0.1)
                Path { path in
                    for y in [0.08, 0.36, 0.58] { path.addRect(CGRect(x: 0, y: h * y, width: w, height: h * 0.035)) }
                    for x in [0.18, 0.44, 0.8] { path.addRect(CGRect(x: w * x, y: 0, width: w * 0.05, height: h * 0.72)) }
                }
                .fill(road)
                pin.offset(x: w * 0.25, y: h * 0.25)
                pin.offset(x: w * 0.62, y: h * 0.44)
                // Results card at the bottom.
                VStack(alignment: .leading, spacing: h * 0.025) {
                    Capsule().fill(line).frame(width: w * 0.18, height: 3).frame(maxWidth: .infinity)
                    Capsule().fill(Color.accentColor).frame(width: w * 0.5, height: h * 0.03)
                    Capsule().fill(line).frame(width: w * 0.7, height: h * 0.022)
                    Capsule().fill(line).frame(width: w * 0.55, height: h * 0.022)
                }
                .padding(w * 0.08)
                .frame(width: w, height: h * 0.3, alignment: .top)
                .background(card, in: UnevenRoundedRectangle(topLeadingRadius: 10, topTrailingRadius: 10))
                .offset(y: h * 0.7)
            }
        }
        .accessibilityHidden(true)
    }

    private var pin: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 14, height: 14)
            .overlay { Circle().strokeBorder(.white, lineWidth: 2) }
    }
}

#Preview {
    OnboardingView()
        .environment(AppEnvironment.preview())
        .environment(AccountModel())
}
