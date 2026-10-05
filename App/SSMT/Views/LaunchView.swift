import SSMTCore
import SwiftUI

/// Cold-start state: splash with the full logo while the app initializes, then a shared-element
/// transition of the mark into the window corner.
@MainActor
final class LaunchState: ObservableObject {
    enum Phase { case splash, done }

    @Published var phase: Phase = .splash
    @Published var slow = false
    @Published var progress: Double = 0

    /// The splash is shown once per process (cold start only), never on window reopen.
    private static var coldStartHandled = false

    static let minimumDuration: Double = 1.6
    static let slowThreshold: Double = 4

    func run(model: AppModel, enabled: Bool, reduceMotion: Bool) async {
        guard !Self.coldStartHandled else {
            phase = .done
            return
        }
        Self.coldStartHandled = true
        let start = Date()
        let slowTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.slowThreshold * 1e9))
            self?.slow = true
        }
        // Initialization: audio devices, settings/calibrations (loaded by the model), FFT set-ups.
        progress = 0.2
        model.refreshDevices()
        progress = 0.5
        await Task.detached(priority: .userInitiated) {
            for n in [1024, 4096, 16384, 65536] { _ = FFT.make(size: n) }
        }.value
        progress = 0.9
        let elapsed = Date().timeIntervalSince(start)
        if enabled && elapsed < Self.minimumDuration {
            try? await Task.sleep(nanoseconds: UInt64((Self.minimumDuration - elapsed) * 1e9))
        }
        slowTask.cancel()
        progress = 1
        withAnimation(reduceMotion ? .easeInOut(duration: 0.4) : .easeInOut(duration: 0.75)) {
            phase = .done
        }
    }
}

/// Root of the main window: splash on top of the (hidden) main interface.
struct RootView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var loc: Localizer
    @ObservedObject private var gate = ProfileCenter.shared.gate
    @StateObject private var launch = LaunchState()
    @Namespace private var brand
    @AppStorage("ssmt.showSplash") private var showSplash = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let done = launch.phase == .done
        ZStack {
            Color.black.ignoresSafeArea()
            if !gate.signedIn {
                // Every session starts with a profile: progress is tied to it.
                AccountGate().opacity(done ? 1 : 0)
            } else {
                MainView(brandNamespace: reduceMotion ? nil : brand, showBrand: done)
                    .opacity(done ? 1 : 0)
                    .offset(y: done || reduceMotion ? 0 : 8)
            }
            if !done && showSplash {
                SplashView(namespace: reduceMotion ? nil : brand, slow: launch.slow, progress: launch.progress)
                    .transition(.opacity)
            }
        }
        .task { await launch.run(model: model, enabled: showSplash, reduceMotion: reduceMotion) }
    }
}

struct SplashView: View {
    @EnvironmentObject var loc: Localizer
    var namespace: Namespace.ID?
    var slow: Bool
    var progress: Double

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 18) {
                Spacer()
                BrandMark(variant: .full, height: 150)
                    .modifier(MatchedBrand(namespace: namespace))
                Text("SoundSolution Multi Tool")
                    .font(Theme.label(13))
                    .foregroundStyle(Color.white.opacity(0.55))
                Spacer()
                VStack(spacing: 8) {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Color.white.opacity(0.08))
                            Rectangle().fill(Color.white.opacity(0.6)).frame(width: g.size.width * progress)
                        }
                    }
                    .frame(width: 160, height: 1)
                    if slow {
                        Text(loc.t("launch.loading")).font(Theme.label(11)).foregroundStyle(Color.white.opacity(0.5))
                    }
                    Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")")
                        .font(Theme.mono(10)).foregroundStyle(Color.white.opacity(0.35))
                }
                .padding(.bottom, 28)
            }
        }
    }
}

/// Applies matchedGeometryEffect when a namespace is given (nil under Reduce Motion → crossfade).
struct MatchedBrand: ViewModifier {
    var namespace: Namespace.ID?
    func body(content: Content) -> some View {
        if let namespace {
            content.matchedGeometryEffect(id: "brandMark", in: namespace)
        } else {
            content
        }
    }
}
