import SwiftUI
import FarecartKit

/// Small colored capsule: icon + "Grocery" / "Pantry" / "Giveaway".
struct TypeBadge: View {
    let type: LocationType
    var prominent = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: type.symbolName)
            Text(type.title)
        }
        .font(.subheadline.weight(.semibold))
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(prominent ? type.color : type.color.opacity(0.18), in: Capsule())
        .foregroundStyle(prominent ? .white : type.color)
        .accessibilityLabel(Text(type.title))
    }
}

/// Map pin: a colored circle with the type's symbol.
struct PlacePin: View {
    let type: LocationType
    var selected = false

    var body: some View {
        ZStack {
            Circle()
                .fill(type.color)
                .frame(width: selected ? 40 : 32, height: selected ? 40 : 32)
                .shadow(radius: 2, y: 1)
            Image(systemName: type.symbolName)
                .font(.system(size: selected ? 18 : 14, weight: .bold))
                .foregroundStyle(.white)
        }
        .overlay(Circle().stroke(.white, lineWidth: 2))
        .animation(.snappy, value: selected)
    }
}

/// Open / closed hint next to hours. `compact` is just "Open now" / "Closed" for list rows.
struct OpenStatusLabel: View {
    let status: OpenStatus
    var compact = false

    var body: some View {
        switch status {
        case .open(let closesAt):
            if let closesAt, !compact {
                Text("Open now · closes \(closesAt.formatted(date: .omitted, time: .shortened))")
                    .foregroundStyle(.green)
            } else {
                Text("Open now").foregroundStyle(.green)
            }
        case .closed(let opensAt):
            if let opensAt, !compact {
                Text("Closed · opens \(opensAt.formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
                    .foregroundStyle(.red)
            } else if compact {
                Text("Closed").foregroundStyle(.red)
            } else {
                Text("Closed now").foregroundStyle(.red)
            }
        case .unknown:
            if compact {
                Text("Hours vary").foregroundStyle(.secondary)
            } else {
                EmptyView()
            }
        }
    }
}

/// Glass pill shown over the map for errors or offline notes.
struct MessageBanner: View {
    let text: String
    var systemImage = "exclamationmark.triangle.fill"
    var actionTitle: LocalizedStringResource = "Retry"
    var retry: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage).foregroundStyle(.orange)
            Text(text).font(.subheadline)
            if let retry {
                Button(action: retry) { Text(actionTitle) }
                    .font(.subheadline.weight(.semibold))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Large, friendly primary action used throughout.
struct BigButtonLabel: View {
    let title: LocalizedStringResource
    let systemImage: String

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
        }
            .font(.title3.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 32)
            .padding(.vertical, 8)
    }
}
