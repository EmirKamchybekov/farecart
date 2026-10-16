import SwiftUI

/// Chicago skyline silhouette, seen from the lake: Willis Tower (stepped tubes, two antennas) on the
/// left, Trump Tower's spire left of centre, the flat-topped Aon Center right of centre, Two Prudential's
/// point, and John Hancock (tapered, two antennas) on the right, with mid-rise blocks between.
/// Coordinates are in a 0...1 unit space (x across, y down, 1 = ground) scaled to the rect.
struct ChicagoSkyline: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height

        func building(_ points: [(CGFloat, CGFloat)]) {
            // Top edge from left to right; the ground closes it.
            guard let first = points.first, let last = points.last else { return }
            path.move(to: CGPoint(x: rect.minX + first.0 * w, y: rect.maxY))
            for (x, y) in points {
                path.addLine(to: CGPoint(x: rect.minX + x * w, y: rect.minY + y * h))
            }
            path.addLine(to: CGPoint(x: rect.minX + last.0 * w, y: rect.maxY))
            path.closeSubpath()
        }
        func block(_ x0: CGFloat, _ x1: CGFloat, _ top: CGFloat) {
            building([(x0, top), (x1, top)])
        }
        func antenna(_ x: CGFloat, _ top: CGFloat, width: CGFloat = 0.008) {
            building([(x - width / 2, top), (x + width / 2, top)])
        }

        // Far left low-rises
        block(0.00, 0.045, 0.80)
        block(0.045, 0.085, 0.72)

        // Willis Tower: nine bundled tubes, stepping in as it rises
        block(0.095, 0.225, 0.62)
        block(0.105, 0.215, 0.46)
        block(0.118, 0.205, 0.33)
        block(0.133, 0.191, 0.16)
        antenna(0.146, 0.00)
        antenna(0.178, 0.03)

        // Blocks between Willis and the river
        block(0.235, 0.29, 0.70)
        building([(0.30, 0.74), (0.30, 0.56), (0.325, 0.52), (0.35, 0.56), (0.35, 0.74)])   // 311 S. Wacker's crown
        block(0.36, 0.40, 0.66)

        // Trump Tower: three setbacks and a needle spire
        block(0.415, 0.495, 0.56)
        block(0.425, 0.49, 0.42)
        block(0.44, 0.48, 0.30)
        antenna(0.46, 0.06, width: 0.006)

        block(0.505, 0.545, 0.74)

        // Aon Center: a plain tall box
        block(0.56, 0.64, 0.24)

        block(0.65, 0.695, 0.63)
        // Two Prudential Plaza: chevron top
        building([(0.705, 0.76), (0.705, 0.50), (0.735, 0.40), (0.765, 0.50), (0.765, 0.76)])
        block(0.775, 0.815, 0.69)

        // John Hancock Center: tapered sides and two antennas
        building([(0.835, 1), (0.858, 0.20), (0.942, 0.20), (0.965, 1)])
        antenna(0.882, 0.02)
        antenna(0.918, 0.00)

        // Far right low-rises
        block(0.97, 1.00, 0.78)

        return path
    }
}

/// The transit line that runs under the skyline: a straight track that dips and comes back up, like the
/// band in the logo. `progress` trims it from the left; `RouteDot` sits at its moving end.
struct RouteLine: Shape {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    static func fullPath(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * w, y: rect.minY + y * h) }
        path.move(to: point(-0.03, 0.2))
        path.addLine(to: point(0.17, 0.2))
        path.addCurve(to: point(0.33, 0.85), control1: point(0.235, 0.2), control2: point(0.265, 0.85))
        path.addLine(to: point(0.58, 0.85))
        path.addCurve(to: point(0.74, 0.2), control1: point(0.645, 0.85), control2: point(0.675, 0.2))
        path.addLine(to: point(0.865, 0.2))
        return path
    }

    func path(in rect: CGRect) -> Path {
        Self.fullPath(in: rect).trimmedPath(from: 0, to: progress)
    }
}

/// The "stop" marker travelling at the end of `RouteLine`.
struct RouteDot: Shape {
    var progress: CGFloat
    var radius: CGFloat = 5

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        guard progress > 0,
              let end = RouteLine.fullPath(in: rect).trimmedPath(from: 0, to: progress).currentPoint else { return Path() }
        return Path(ellipseIn: CGRect(x: end.x - radius, y: end.y - radius, width: radius * 2, height: radius * 2))
    }
}

#Preview {
    ZStack {
        Color(red: 0.196, green: 0.667, blue: 0.349).ignoresSafeArea()
        VStack {
            Spacer()
            ChicagoSkyline().fill(Color(red: 0.118, green: 0.478, blue: 0.243)).frame(height: 170)
        }
        .overlay(alignment: .bottom) {
            ZStack {
                RouteLine(progress: 1).stroke(Color(red: 0.561, green: 0.878, blue: 0.353), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                RouteDot(progress: 1).fill(.white)
            }
            .frame(height: 36)
            .offset(y: 36)
        }
    }
}
