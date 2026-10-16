import SwiftUI
import FarecartKit

/// A place's logo (chain or website favicon from `logo_url`) as a rounded square on white with a
/// hairline border. While loading, on failure, or when there is no logo it shows the category tile:
/// the type's symbol on the type's color, the same size, so rows and the hero never jump.
struct PlaceIcon: View {
    let place: Place
    var size: CGFloat = 44
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            if let url = place.logoURL {
                AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
                    if case .success(let image) = phase {
                        logo(image)
                    } else {
                        tile
                    }
                }
            } else {
                tile
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
    }

    private func logo(_ image: Image) -> some View {
        image
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .padding(size * 0.12)
            .frame(width: size, height: size)
            .background(.white, in: shape)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color(.separator), lineWidth: 1 / displayScale))
    }

    /// The category tile, also used on its own by views that never show a logo.
    private var tile: some View {
        Image(systemName: place.type.symbolName)
            .font(.system(size: size * 0.42, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(place.type.color, in: shape)
    }
}

#Preview {
    VStack(spacing: 16) {
        PlaceIcon(place: MockData.samplePlace, size: 52)
        PlaceIcon(place: MockData.samplePantry, size: 52)
        PlaceIcon(place: MockData.samplePlace, size: 44)
    }
    .padding()
}
