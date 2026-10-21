import Foundation
import SwiftUI

/// Languages the user can pick in Settings or onboarding. `system` follows the phone.
/// Raw values are the `.lproj` names in the string catalog.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case en
    case es
    case pl
    case zhHans = "zh-Hans"
    case ar
    case fil
    case ur
    case uk
    case ko

    static let storageKey = "appLanguage"

    var id: String { rawValue }

    /// `nil` for "Use phone language".
    var locale: Locale? {
        self == .system ? nil : Locale(identifier: rawValue)
    }

    /// Native name, shown as-is so a reader always recognises their own language.
    var nativeName: String {
        switch self {
        case .system: String(localized: "Use phone language", bundle: LanguageBundle.current)
        case .en: "English"
        case .es: "Español"
        case .pl: "Polski"
        case .zhHans: "中文（简体）"
        case .ar: "العربية"
        case .fil: "Tagalog"
        case .ur: "اردو"
        case .uk: "Українська"
        case .ko: "한국어"
        }
    }

    var isRightToLeft: Bool { self == .ar || self == .ur }

    /// Only RTL languages override the direction; `nil` keeps the system's.
    var layoutDirection: LayoutDirection? {
        switch self {
        case .system: nil
        case .ar, .ur: .rightToLeft
        default: .leftToRight
        }
    }

    /// What is stored in `UserDefaults` under `appLanguage` (unknown values fall back to `system`).
    static var selected: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .system
    }

    /// The locale strings and prices should be formatted in.
    static var effectiveLocale: Locale { selected.locale ?? .current }
}

/// Where non-SwiftUI string lookups (`String(localized:)`) read from, so a language picked in the
/// app applies at once without relaunching. SwiftUI `Text` follows `.environment(\.locale)` set at
/// the root instead.
enum LanguageBundle {
    static var current: Bundle {
        guard let code = AppLanguage.selected.locale?.identifier,
              let path = Bundle.main.path(forResource: code, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return .main }
        return bundle
    }
}

/// Appearance picked in Settings, applied with `.preferredColorScheme` at the root.
enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "appTheme"

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var symbolName: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        }
    }
}

enum OnboardingKeys {
    static let done = "onboardingDone"
}

/// "How will you use Farecart?" from onboarding (`@AppStorage("userRole")`). Staff land on their
/// pantry's staff screen; clients get the discount questions. Changeable in Settings.
enum UserRole: String, CaseIterable, Identifiable {
    case client
    case staff

    static let storageKey = "userRole"

    var id: String { rawValue }
}
