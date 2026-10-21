import SwiftUI
import CoreImage.CIFilterBuiltins

/// Crisp QR code for a short payload (e.g. a visit confirmation code). Rendered once per payload.
struct QRCodeView: View {
    let payload: String
    var dimmed = false

    var body: some View {
        Group {
            if let image = Self.image(for: payload) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "qrcode").resizable().scaledToFit().foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.white, in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
        .opacity(dimmed ? 0.25 : 1)
        .accessibilityHidden(true)
    }

    static func image(for payload: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
