import SwiftUI

/// Animated splash shown once per cold launch on top of the root view. Its first frame is pixel-identical
/// to the static launch screen (SplashBackground + the centred 120 pt LaunchLogo), so the hand-over from
/// UIKit's launch image is invisible. The main UI loads underneath the whole time.
///
/// Timeline (seconds, ×4 with `-farecart-splash-slow`):
///   0.00  skyline rises in (0.5), logo springs up 12 pt and settles, gradient deepens
///   0.30  route line sweeps across the skyline base with its stop dot (0.7)
///   0.75  tagline fades in (0.3)
///   1.25  `onFinished` → the parent fades/scales the splash out (0.35)  ≈ 1.6 s total
/// Reduce Motion: the final frame is shown still for 0.8 s and only cross-fades out.
struct SplashView: View {
    /// Called when the splash is ready to be dismissed. Never called with `-farecart-splash-hold`.
    let onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var skylineShown = false
    @State private var logoRaised = false
    @State private var routeProgress: CGFloat = 0
    @State private var taglineShown = false

    static let logoSize: CGFloat = 120
    private static let logoLift: CGFloat = 12
    private static let skylineColor = Color(red: 0x1E / 255, green: 0x7A / 255, blue: 0x3E / 255)
    private static let routeColor = Color(red: 0x8F / 255, green: 0xE0 / 255, blue: 0x5A / 255)

    /// Duration multiplier (1 normally, 4 with `-farecart-splash-slow`).
    static var speed: Double { DebugLaunch.splashSpeedFactor }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let skylineHeight = min(170, size.height * 0.19)
            let baseY = size.height * 0.82
            let logoCenterY = size.height / 2 - (logoRaised ? Self.logoLift : 0)

            ZStack {
                Color("SplashBackground")

                // Subtle depth: a little darker towards the ground. Fades in so frame 0 stays flat.
                LinearGradient(colors: [.clear, .black.opacity(0.16)], startPoint: .top, endPoint: .bottom)
                    .opacity(skylineShown ? 1 : 0)

                ChicagoSkyline()
                    .fill(Self.skylineColor)
                    .frame(width: size.width, height: skylineHeight)
                    .position(x: size.width / 2, y: baseY - skylineHeight / 2)
                    .offset(y: skylineShown ? 0 : 56)
                    .opacity(skylineShown ? 1 : 0)

                ZStack {
                    RouteLine(progress: routeProgress)
                        .stroke(Self.routeColor, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                    RouteDot(progress: routeProgress)
                        .fill(.white)
                        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                }
                .frame(width: size.width, height: 36)
                // The line's upper level sits 4 pt under the skyline base.
                .position(x: size.width / 2, y: baseY + 4 - 0.2 * 36 + 18)
                .opacity(skylineShown ? 1 : 0)

                Image("LaunchLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: Self.logoSize, height: Self.logoSize)
                    .shadow(color: .black.opacity(logoRaised ? 0.18 : 0), radius: 14, y: 8)
                    .position(x: size.width / 2, y: logoCenterY)

                Text("Find food. Get there for less.")
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .dynamicTypeSize(...DynamicTypeSize.xLarge)
                    .foregroundStyle(.white.opacity(0.95))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .frame(maxWidth: 320)
                    .padding(.horizontal, Spacing.l)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(taglineShown ? 1 : 0)
                    .offset(y: taglineShown ? 0 : 6)
                    .position(x: size.width / 2, y: logoCenterY + Self.logoSize / 2 + 30)
            }
        }
        .ignoresSafeArea()
        // The skyline is a picture of Chicago, not UI: never mirror it for right-to-left languages.
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Farecart"))
        .task { await run() }
    }

    private func run() async {
        let speed = Self.speed
        func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds * speed)) }

        if reduceMotion {
            var noMotion = Transaction()
            noMotion.disablesAnimations = true
            withTransaction(noMotion) {
                skylineShown = true
                routeProgress = 1
                taglineShown = true
            }
            await wait(0.8)
        } else {
            withAnimation(.easeOut(duration: 0.5 * speed)) { skylineShown = true }
            withAnimation(.spring(response: 0.6 * speed, dampingFraction: 0.62)) { logoRaised = true }
            await wait(0.3)
            withAnimation(.easeInOut(duration: 0.7 * speed)) { routeProgress = 1 }
            await wait(0.45)
            withAnimation(.easeOut(duration: 0.3 * speed)) { taglineShown = true }
            await wait(0.5)
        }
        guard !DebugLaunch.splashHold, !Task.isCancelled else { return }
        onFinished()
    }
}

/// Puts `SplashView` over the root on cold launch and removes it when it finishes. The state lives
/// in the scene, so returning from the background never shows the splash again.
struct SplashOverlay: ViewModifier {
    @State private var splashVisible = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        ZStack {
            content
            if splashVisible {
                SplashView {
                    let duration = 0.35 * SplashView.speed
                    withAnimation(reduceMotion ? .easeInOut(duration: duration) : .easeIn(duration: duration)) {
                        splashVisible = false
                    }
                }
                .zIndex(1)
                .transition(.asymmetric(
                    insertion: .identity,
                    removal: reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 1.06))
                ))
            }
        }
    }
}

extension View {
    /// Shows the animated launch splash once, on top of this view.
    func launchSplash() -> some View {
        modifier(SplashOverlay())
    }
}

#Preview("Splash") {
    SplashView {}
}
