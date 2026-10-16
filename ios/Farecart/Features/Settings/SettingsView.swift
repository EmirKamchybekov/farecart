import SwiftUI
import UIKit
import FarecartKit

/// Tab 3: account (optional), language, appearance, welcome screens, then what used to be About.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AccountModel.self) private var account
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.system.rawValue
    @AppStorage(AppTheme.storageKey) private var themeCode = AppTheme.system.rawValue
    @AppStorage(OnboardingKeys.done) private var onboardingDone = false
    @AppStorage(DiscountsKeys.householdSNAP) private var householdSNAP = false
    @AppStorage(DiscountsKeys.isStudent) private var isStudent = false
    @AppStorage(DiscountsKeys.hasAnswered) private var hasAnswered = false
    @State private var confirmSignOut = false

    private var language: AppLanguage { AppLanguage(rawValue: languageCode) ?? .system }

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            List {
                accountSection

                Section {
                    NavigationLink {
                        LanguagePickerView()
                    } label: {
                        LabeledContent {
                            Text(language.nativeName)
                        } label: {
                            Label("Language", systemImage: "globe")
                        }
                    }
                    Picker(selection: $themeCode) {
                        ForEach(AppTheme.allCases) { theme in
                            Label(theme.title, systemImage: theme.symbolName).tag(theme.rawValue)
                        }
                    } label: {
                        Label("Appearance", systemImage: "circle.lefthalf.filled")
                    }
                    .pickerStyle(.menu)
                    Button {
                        withAnimation(.snappy) { onboardingDone = false }
                    } label: {
                        Label("Show welcome again", systemImage: "hand.wave")
                    }
                } header: {
                    Text("App")
                } footer: {
                    Text("Translations other than English and Spanish are machine-assisted and under review.")
                }

                Section("Data sources") {
                    credit(title: "Food locations", detail: "West Side listings were hand-researched by the Farecart team. Citywide grocery stores come from the USDA SNAP Retailer Locator (public domain); pantries from OpenStreetMap, the Greater Chicago Food Depository and Plentiful. Each place links to its source. Listings marked \"not yet verified\" have not been confirmed by phone or visit.")
                    credit(title: "OpenStreetMap", detail: "Some listings © OpenStreetMap contributors, licensed under ODbL.", url: "https://www.openstreetmap.org/copyright")
                    credit(title: "USDA SNAP Retailer Locator", detail: "U.S. Department of Agriculture, Food and Nutrition Service.", url: "https://www.fns.usda.gov/snap/retailer-locator")
                    credit(title: "CTA fares", detail: "Chicago Transit Authority, transitchicago.com/fares", url: "https://www.transitchicago.com/fares/")
                    credit(title: "Access reduced fare", detail: "Northern Illinois Transit Authority, getaccess.org", url: "https://getaccess.org")
                    credit(title: "Student reduced fare", detail: "CTA Ventra Student Card", url: "https://www.transitchicago.com/fares/reduced-fare/")
                    credit(title: "Maps", detail: "Apple Maps. Directions open in Apple Maps or Google Maps.")
                }

                Section("Privacy") {
                    Text("Your location is used only to search for nearby places. It is sent to our database for that search and never stored. Your Discounts answers stay on this phone unless you sign in, in which case they are saved to your account.")
                        .font(.subheadline)
                }

                Section("Help") {
                    if let url = DirectionsLinks.reportProblemEmail(to: environment.reportProblemEmail, placeName: nil, placeID: nil) {
                        Link(destination: url) {
                            Label("Report a problem with a listing", systemImage: "flag")
                        }
                    }
                    Text("Email \(environment.reportProblemEmail) if a place has closed, moved or changed its hours.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) {
                            Image("Logo")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 32, height: 32)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .accessibilityHidden(true)
                            Text("Farecart")
                                .font(.headline)
                        }
                        Text("Find food. Get there for less.")
                            .font(.subheadline)
                        Text("Farecart helps people on Chicago's West Side find grocery stores, food pantries and giveaways nearby, and shows the cheapest CTA fare they qualify for.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    LabeledContent("Version", value: version)
                    if environment.config == nil {
                        Label("Running on sample data (no Supabase settings found).", systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("About")
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog("Sign out of Farecart?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) { Task { await account.signOut() } }
            } message: {
                Text("Your answers, language and theme stay on this phone.")
            }
            // Keep the profile row in step while signed in.
            .onChange(of: themeCode) { Task { await account.pushProfile() } }
            .onChange(of: languageCode) { Task { await account.pushProfile() } }
            .onChange(of: householdSNAP) { Task { await account.pushProfile() } }
            .onChange(of: isStudent) { Task { await account.pushProfile() } }
            .onChange(of: hasAnswered) { Task { await account.pushProfile() } }
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        Section {
            if account.isSignedIn {
                HStack(spacing: Spacing.s) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.displayName ?? String(localized: "Signed in", bundle: LanguageBundle.current))
                            .font(.headline)
                        if let email = account.session?.user.email, email != account.displayName {
                            Text(email)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Text(signedInNote)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                Button(role: .destructive) {
                    confirmSignOut = true
                } label: {
                    Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Label("Delete account", systemImage: "trash")
                    Text("To delete your account and its data, email \(environment.reportProblemEmail) from the address you signed in with. In-app deletion is coming soon.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            } else {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text("Sign in to keep your discount answers, language and theme if you change phones. Everything works without an account.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    SignInButtons()
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("Account")
        }
    }

    private var signedInNote: LocalizedStringResource {
        switch account.provider {
        case .google: "Signed in with Google. Your discount answers, language and theme are saved to your account."
        case .apple, nil: "Signed in with Apple. Your discount answers, language and theme are saved to your account."
        }
    }

    private func credit(title: LocalizedStringResource, detail: LocalizedStringResource, url: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.headline)
            Text(detail).font(.subheadline).foregroundStyle(.secondary)
            if let url, let link = URL(string: url) {
                Link(link.host() ?? url, destination: link).font(.subheadline)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Full list of languages with the current one checked. Also embedded in onboarding.
struct LanguagePickerView: View {
    var body: some View {
        List {
            Section {
                LanguageRows()
            } footer: {
                Text("Translations other than English and Spanish are machine-assisted and under review.")
            }
        }
        .navigationTitle("Language")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One tappable row per language; big enough for a thumb, native names only.
struct LanguageRows: View {
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.system.rawValue
    var large = false

    var body: some View {
        ForEach(AppLanguage.allCases) { language in
            let selected = languageCode == language.rawValue
            Button {
                withAnimation(.snappy) { languageCode = language.rawValue }
            } label: {
                HStack {
                    if language == .system {
                        Label {
                            Text(language.nativeName)
                        } icon: {
                            Image(systemName: "iphone")
                        }
                    } else {
                        Text(verbatim: language.nativeName)
                    }
                    Spacer()
                    if selected {
                        Image(systemName: "checkmark")
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .font(large ? .title3.weight(.medium) : .body)
                .padding(.vertical, large ? 6 : 0)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }
}

#Preview {
    SettingsView()
        .environment(AppEnvironment.preview())
        .environment(AccountModel())
}
