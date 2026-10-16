import SwiftUI
import FarecartKit

/// "What's available": one chip per stock category the pantry has posted, coloured by level
/// (plenty green, low amber, out grey), with when it was reported. Never a promise: stock is
/// what staff posted, and it changes.
struct PantryInventoryCard: View {
    let place: Place
    let availability: PantryAvailability?
    let isLoading: Bool
    @Environment(\.locale) private var locale

    private var items: [PantryInventoryItem] { availability?.currentInventory() ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack {
                SectionCaption("What's available")
                Spacer()
                if isLoading && availability == nil {
                    ProgressView().controlSize(.small)
                }
            }
            if !items.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: Spacing.xs)], alignment: .leading, spacing: Spacing.xs) {
                    ForEach(items) { item in
                        InventoryChip(item: item)
                    }
                }
                footer
            } else if !isLoading || availability != nil {
                emptyState
            }
        }
        .card()
        .animation(.snappy, value: items)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let reported = availability?.latestReportedAt() {
                Label {
                    Text("Reported \(VisitFormat.relative(reported, locale: locale))")
                } icon: {
                    Image(systemName: "clock.arrow.circlepath")
                }
            }
            Text("Posted by pantry staff. Stock changes quickly, so call ahead for anything you can't do without.")
            if items.contains(where: { $0.source == "feedam" }) {
                Text("Includes data from Feed America (feedam.org, CC BY 4.0).")
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Label("This pantry hasn't posted today's stock. Call ahead.", systemImage: "tray")
                .foregroundStyle(.secondary)
            if let phone = place.phone, let url = place.phoneURL {
                Link(destination: url) {
                    Label(phone, systemImage: "phone.fill")
                }
                .font(.body.weight(.semibold))
            }
        }
    }
}

/// One category chip: icon + name, then the level in its colour, and the staff note if any.
struct InventoryChip: View {
    let item: PantryInventoryItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: item.category.symbolName)
                    .font(.subheadline.weight(.semibold))
                Text(item.category.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            HStack(spacing: 4) {
                Image(systemName: item.level.symbolName)
                Text(item.level.title)
            }
            .font(.caption.weight(.bold))
            .foregroundStyle(item.level.color)
            if let note = item.note, !note.isEmpty {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(10)
        .background(item.level.color.opacity(item.level == .out ? 0.10 : 0.14), in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                .strokeBorder(item.level.color.opacity(0.35), lineWidth: 1)
        }
        .foregroundStyle(item.level == .out ? .secondary : .primary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(Text(item.category.title)): \(Text(item.level.title))"))
    }
}

#Preview("Stock") {
    ScrollView {
        VStack(spacing: Spacing.m) {
            PantryInventoryCard(place: MockData.samplePantry, availability: PantryAvailability(inventory: MockPantryService.demoInventory(now: Date())), isLoading: false)
            PantryInventoryCard(place: MockData.samplePantry, availability: .empty, isLoading: false)
            PantryInventoryCard(place: MockData.samplePantry, availability: nil, isLoading: true)
        }
        .padding()
    }
    .background(Color(.systemGroupedBackground))
}
