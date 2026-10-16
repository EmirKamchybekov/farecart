import SwiftUI

/// Spacing scale used everywhere: 8 / 12 / 16 / 24.
enum Spacing {
    static let xs: CGFloat = 8
    static let s: CGFloat = 12
    static let m: CGFloat = 16
    static let l: CGFloat = 24
}

/// Corner radii: cards 20, blocks inside a card 14, small tiles 10.
enum Radius {
    static let card: CGFloat = 20
    static let inner: CGFloat = 14
    static let tile: CGFloat = 10
}

/// A white (or elevated, in dark mode) rounded card on the grouped background.
struct CardBackground: ViewModifier {
    var padding: CGFloat = Spacing.m

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }
}

extension View {
    func card(padding: CGFloat = Spacing.m) -> some View {
        modifier(CardBackground(padding: padding))
    }
}

/// Small uppercase caption used as a label above a value or a card title.
struct SectionCaption: View {
    let title: LocalizedStringResource

    init(_ title: LocalizedStringResource) { self.title = title }

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
    }
}

/// Short compact pill: "Takes Link/EBT", "Save $1.15".
struct Pill: View {
    let text: Text
    var systemImage: String? = nil
    var tint: Color = .accentColor

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            text
        }
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(tint.opacity(0.16), in: Capsule())
        .foregroundStyle(tint)
    }
}
