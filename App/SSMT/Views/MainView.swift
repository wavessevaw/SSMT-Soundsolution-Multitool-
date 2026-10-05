import SSMTCore
import SwiftUI

private struct WorkspaceVisibleKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// False while a function's screen is kept built but hidden behind another one.
    var workspaceVisible: Bool {
        get { self[WorkspaceVisibleKey.self] }
        set { self[WorkspaceVisibleKey.self] = newValue }
    }
}

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var loc: Localizer
    var brandNamespace: Namespace.ID? = nil
    var showBrand = true
    /// Functions whose screens are built. A screen is built once and then only hidden and shown: switching
    /// functions does not rebuild the whole view tree (slow on Intel Macs).
    @State private var mounted: Set<AppSection> = []

    var body: some View {
        ZStack {
            Backdrop()
            HStack(spacing: 16) {
                if !model.stageMode {
                    AppSidebar(brandNamespace: brandNamespace, showBrand: showBrand)
                }
                VStack(spacing: 8) {
                    if model.section != .show && model.section != .assist && model.section != .handbook { TopBar() }
                    if let e = model.lastError { ErrorBanner(text: e.hasPrefix("error.") ? loc.t(e) : e) { model.lastError = nil } }
                    ZStack {
                        ForEach(AppSection.allCases) { s in
                            if mounted.contains(s) || s == model.section {
                                let on = s == model.section
                                workspace(s)
                                    .opacity(on ? 1 : 0)
                                    .allowsHitTesting(on)
                                    .accessibilityHidden(!on)
                                    // Hidden screens keep their state but take no clicks or keyboard shortcuts.
                                    .disabled(!on)
                                    .environment(\.workspaceVisible, on)
                                    .zIndex(on ? 1 : 0)
                            }
                        }
                    }
                }
            }
            .padding(14)
        }
        // Profile toasts, level-up and the profile sheet watch the profile themselves: progress updates never
        // redraw the whole window.
        .overlay { ProfileOverlays() }
        .onChange(of: model.section) { s in
            mounted.insert(s)
            model.show.isActive = s == .show
            ProfileCenter.shared.sectionOpened(s.rawValue)
        }
        .onAppear {
            mounted.insert(model.section)
            model.show.isActive = model.section == .show
            ProfileCenter.shared.sectionOpened(model.section.rawValue)
        }
        .task { await warmUp() }
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .environment(\.reducedEffects, model.reducedEffects)
        .frame(minWidth: 1100, minHeight: 720)
        .sheet(isPresented: $model.showSettings) {
            VStack(spacing: 0) {
                HStack {
                    Text(loc.t("settings.title")).font(Theme.heading(17))
                    Spacer()
                    Button(loc.t("settings.done")) { model.showSettings = false }.buttonStyle(SSMTButtonStyle(kind: .primary))
                }
                .padding(16)
                SetupSidebar(expert: false)
            }
            .frame(width: 360, height: 660)
            .background(Backdrop())
            .ssmtEnvironment(model, loc)
            .preferredColorScheme(.dark)
        }
    }
}

/// Expert graphs: the only part of the expert screen redrawn on each live snapshot.
/// The response is smoothed once and shared by all plots.
struct ExpertGraphs: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var live: LiveData
    @EnvironmentObject var loc: Localizer

    var body: some View {
        let tf = model.displayTransfer.map { Smoothing.smooth($0, resolution: model.smoothing) }
        let kinds = GraphKind.allCases.filter { model.visibleGraphs.contains($0) }
        return Panel(title: loc.t("graphs.title"), marking: model.smoothing == .none ? loc.t("graphs.raw") : String(format: loc.t("graphs.octave"), model.smoothing.rawValue)) {
            if tf == nil {
                VStack(spacing: 8) {
                    Image(systemName: "waveform.path.ecg").font(.system(size: 30)).foregroundStyle(Theme.textMuted)
                    Text(loc.t("graphs.empty")).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 6) {
                    ForEach(kinds) { k in
                        TransferPlotView(kind: k, transfer: tf, smoothing: .none,
                                         coherenceThreshold: model.coherenceThreshold,
                                         title: loc.t("graph.\(k.rawValue)"))
                            .frame(maxHeight: k == .magnitude ? .infinity : 200)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Visible error message on every screen (device problems, permissions, file imports).
extension MainView {
    @ViewBuilder func workspace(_ s: AppSection) -> some View {
        switch s {
        case .show:
            // Playing in the background: the hidden Qtrl screen does not redraw meters and cursors.
            ShowWorkspace().environmentObject(model.section == .show ? model.show.live : Self.idleShowLive)
        case .assist: AssistWorkspace()
        case .inputList: InputListWorkspace()
        case .handbook: HandbookWorkspace()
        case .setup:
            let on = model.section == .setup
            Group {
                if model.appMode == .wizard {
                    WizardView()
                } else {
                    VStack(spacing: 14) {
                        MeterPanel()
                        ExpertGraphs()
                    }
                    .padding(.bottom, 4)
                }
            }
            // Hidden behind another function, the setup screen reads still copies: live measurements (10–20 a
            // second) do not redraw graphs nobody sees.
            .environmentObject(on ? model.live : Self.idleLive)
            .environmentObject(on ? model.tuning : Self.idleTuning)
        }
    }

    static let idleLive = LiveData()
    static let idleShowLive = ShowLive()
    static let idleTuning = TuningData()

    /// Shortly after launch the other functions are built in the background, one at a time, so even the first
    /// switch to them is instant.
    func warmUp() async {
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        for s in AppSection.allCases where !mounted.contains(s) {
            mounted.insert(s)
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
    }
}

struct ErrorBanner: View {
    @EnvironmentObject var loc: Localizer
    var text: String
    var dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(Theme.statusError)
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help(loc.t("action.close"))
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous).fill(Theme.statusError.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous).strokeBorder(Theme.statusError.opacity(0.35)))
    }
}
