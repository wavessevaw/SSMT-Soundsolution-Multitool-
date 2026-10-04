import SSMTAudio
import SSMTCore
import SwiftUI

/// Function #4: FOH Assist. One header for all modes (mode switch, console / mic / profile chips, settings in a
/// sheet); soundcheck as channel list + selected channel; show with the guard's state first; console test.
struct AssistWorkspace: View {
    @EnvironmentObject var store: AssistStore
    @EnvironmentObject var loc: Localizer

    var body: some View {
        // Nothing but the console choice until a console (or the simulator) is connected.
        if store.isConnected { workspace } else { AssistConnectScreen() }
    }

    private var workspace: some View {
        VStack(alignment: .leading, spacing: 12) {
            AssistHeader()
            if let m = store.message {
                ErrorBanner(text: m == "nothing found" ? loc.t("assist.nothingFound") : m) { store.message = nil }
            }
            switch store.mode {
            case .soundcheck: SoundcheckScreen()
            case .show: ShowScreen()
            case .test: ConsoleTestScreen()
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(isPresented: $store.showSettings) {
            AssistSettingsSheet().environmentObject(store).environmentObject(loc)
        }
    }
}

// MARK: - Header

private struct AssistHeader: View {
    @EnvironmentObject var store: AssistStore
    @EnvironmentObject var loc: Localizer

    var body: some View {
        HStack(spacing: 14) {
            Text("FOH Assist").font(.system(size: 26, weight: .bold)).fixedSize()
            Picker("", selection: $store.mode) {
                Text(loc.t("assist.mode.soundcheck")).tag(AssistStore.Mode.soundcheck)
                Text(loc.t("assist.mode.show")).tag(AssistStore.Mode.show)
                Text(loc.t("assist.mode.test")).tag(AssistStore.Mode.test)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 340)
            Spacer(minLength: 8)
            ViewThatFits(in: .horizontal) {
                chips(full: true)
                chips(full: false)
            }
        }
    }

    private func chips(full: Bool) -> some View {
        HStack(spacing: 8) {
            Button { store.showSettings = true } label: {
                HeaderChip {
                    LinkLamp(on: store.linkAlive)
                    Text(consoleName).fontWeight(.semibold).foregroundStyle(Theme.textPrimary)
                    if full && store.family != .simulator { Text(store.host).monospacedDigit() }
                    Text(loc.t(store.linkAlive ? "assist.link.ok" : "assist.link.lost"))
                        .foregroundStyle(store.linkAlive ? Theme.statusGood : Theme.statusError)
                }
            }
            .buttonStyle(.plain)
            .help(connectionText)
            if full, let l = store.micLevel {
                HeaderChip {
                    Text(loc.t("assist.chip.hall"))
                    Text(String(format: store.micCalibrated ? "%.0f dB(A)" : "%.0f dBFS(A)", l))
                        .monospacedDigit().fontWeight(.semibold).foregroundStyle(Theme.textPrimary)
                }
            }
            if full {
                HeaderChip {
                    Text(loc.t("assist.chip.profile"))
                    Text(loc.t("assist.char.\(store.character.rawValue)")).fontWeight(.semibold).foregroundStyle(Theme.textPrimary)
                }
            }
            Button { store.showSettings = true } label: {
                HeaderChip { Image(systemName: "gearshape") }
            }
            .buttonStyle(.plain)
            .help(loc.t("assist.settings"))
        }
    }

    private var consoleName: String {
        switch store.family {
        case .x32: return "X32 / M32"
        case .xAir: return "X Air / MR"
        case .simulator: return loc.t("assist.chip.sim")
        default: return loc.t("assist.family.\(store.family.rawValue)")
        }
    }

    private var connectionText: String {
        switch store.connection {
        case .disconnected: return loc.t("assist.offline")
        case .connecting: return loc.t("assist.connecting")
        case let .connected(t): return t
        case let .failed(t): return t == "not supported yet" ? loc.t("assist.soon") : t
        }
    }
}

private struct HeaderChip<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 6) { content }
            .font(.system(size: 12))
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .overlay(Capsule().strokeBorder(Theme.hairlineStrong))
            .contentShape(Capsule())
    }
}

/// Console, audio interface, measurement mic, profile and tap point: changed rarely, so not on the main screen.
private struct AssistSettingsSheet: View {
    @EnvironmentObject var store: AssistStore
    @EnvironmentObject var loc: Localizer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(loc.t("assist.settings")).font(Theme.heading(17))
                Spacer()
                Button(loc.t("settings.done")) { store.showSettings = false }.buttonStyle(SSMTButtonStyle(kind: .primary))
            }
            .padding(16)
            Divider().overlay(Theme.hairline)
            ScrollView { ConnectionPanel().padding(18) }
        }
        .frame(width: 860, height: 520)
        .background(Backdrop())
        .preferredColorScheme(.dark)
    }
}

// MARK: - Connect screen

/// Link lamp: green while the console answers, red when there is no link.
private struct LinkLamp: View {
    var on: Bool
    var size: CGFloat = 9

    var body: some View {
        Circle()
            .fill(on ? Theme.statusGood : Theme.statusError)
            .frame(width: size, height: size)
            .shadow(color: (on ? Theme.statusGood : Theme.statusError).opacity(0.8), radius: size / 2)
    }
}

/// Shown until a console is connected: choose the console, find it on the Wi-Fi network, connect.
private struct AssistConnectScreen: View {
    @EnvironmentObject var store: AssistStore
    @EnvironmentObject var loc: Localizer
    @State private var manualIP = ""

    private let families: [MixerFamily] = [.x32, .xAir, .simulator, .wing, .yamaha, .allenHeath]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("FOH Assist").font(.system(size: 30, weight: .bold))
                    Spacer()
                    HStack(spacing: 8) {
                        LinkLamp(on: false)
                        Text(statusText).font(.system(size: 13, weight: .medium)).foregroundStyle(statusColor)
                    }
                }
                Text(loc.t("assist.nc.text")).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)

                step(1, loc.t("assist.connect.console"))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    ForEach(families, id: \.self) { f in familyCard(f) }
                }

                if store.family == .simulator {
                    step(2, loc.t("assist.connect.sim"))
                    Button { store.connect() } label: { Label(loc.t("assist.connect.simGo"), systemImage: "play.fill") }
                        .buttonStyle(SSMTButtonStyle(kind: .primary))
                } else if store.family.implemented {
                    HStack {
                        step(2, loc.t("assist.connect.found"))
                        Spacer()
                        if store.scanning { ProgressView().controlSize(.small) }
                        Button { store.scan() } label: { Label(loc.t("assist.connect.rescan"), systemImage: "arrow.clockwise") }
                            .buttonStyle(SSMTButtonStyle())
                            .disabled(store.scanning)
                    }
                    found
                    HStack(spacing: 10) {
                        Text(loc.t("assist.connect.manual")).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        TextField("192.168.1.64", text: $manualIP).textFieldStyle(.roundedBorder).frame(width: 160)
                        Button(loc.t("assist.connect")) {
                            store.host = manualIP.trimmingCharacters(in: .whitespaces)
                            store.connect()
                        }
                        .buttonStyle(SSMTButtonStyle())
                        .disabled(manualIP.trimmingCharacters(in: .whitespaces).isEmpty || store.connection == .connecting)
                    }
                }
                Text(loc.t("assist.connect.after")).font(.system(size: 11)).foregroundStyle(Theme.textMuted)
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
            .background(GlassBackground())
            .frame(maxWidth: .infinity)
            .padding(.top, 20)
        }
        .onAppear {
            if manualIP.isEmpty { manualIP = store.host }
            if store.autoScan && (store.family == .x32 || store.family == .xAir) { store.scan() }
        }
    }

    private var statusText: String {
        switch store.connection {
        case .connecting: return String(format: loc.t("assist.connect.connecting"), store.host)
        case let .failed(t): return t == "not supported yet" ? loc.t("assist.soon") : loc.t("assist.connect.failed") + ": " + t
        default: return loc.t("assist.link.none")
        }
    }

    private var statusColor: Color { store.connection == .connecting ? Theme.statusWarning : Theme.statusError }

    private func step(_ n: Int, _ title: String) -> some View {
        HStack(spacing: 8) {
            Text("\(n)").font(.system(size: 12, weight: .bold)).foregroundStyle(.black)
                .frame(width: 20, height: 20).background(Circle().fill(Theme.accent))
            Text(title).font(Theme.heading(15))
        }
    }

    private func familyCard(_ f: MixerFamily) -> some View {
        let on = store.family == f
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return Button {
            store.family = f
            if f == .x32 || f == .xAir { store.scan() }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: f == .simulator ? "desktopcomputer" : "slider.vertical.3")
                    .font(.system(size: 18)).foregroundStyle(on ? Theme.accent : Theme.textSecondary)
                Text(loc.t("assist.family.\(f.rawValue)")).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(f.implemented ? (f == .simulator ? loc.t("assist.connect.simHint") : loc.t("assist.connect.wifi")) : loc.t("assist.soon"))
                    .font(.system(size: 11)).foregroundStyle(Theme.textMuted)
            }
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
            .padding(12)
            .background(shape.fill(on ? Theme.accent.opacity(0.12) : Color.white.opacity(0.04)))
            .overlay(shape.strokeBorder(on ? Theme.accent : Theme.hairline, lineWidth: on ? 1.5 : 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(!f.implemented)
        .opacity(f.implemented ? 1 : 0.45)
    }

    @ViewBuilder private var found: some View {
        let list = store.discovered.filter { $0.family == store.family }
        if list.isEmpty {
            Text(loc.t(store.scanning ? "assist.connect.searching" : "assist.connect.none"))
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                .padding(.vertical, 6)
        }
        ForEach(list) { c in
            HStack(spacing: 12) {
                Image(systemName: "slider.vertical.3").font(.system(size: 16)).foregroundStyle(Theme.accent)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.accent.opacity(0.14)))
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(c.model) · \(c.name)").font(.system(size: 13, weight: .semibold))
                    Text(c.ip + (c.firmware.isEmpty ? "" : " · " + String(format: loc.t("assist.connect.fw"), c.firmware)))
                        .font(Theme.mono(12)).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                if store.connection == .connecting && store.host == c.ip {
                    ProgressView().controlSize(.small)
                }
                Button(loc.t("assist.connect")) { store.connect(to: c) }
                    .buttonStyle(SSMTButtonStyle(kind: .primary))
                    .disabled(store.connection == .connecting)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.05)))
        }
    }
}

// MARK: - Shared pieces

/// Glass card with a title row and edge-to-edge content.
private struct Card<Content: View, Accessory: View>: View {
    var title: String
    var tint: Color = Theme.accent
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(tint).frame(width: 3, height: 15)
                Text(title).font(Theme.heading(14)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Spacer(minLength: 8)
                accessory
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GlassBackground())
    }
}

/// Horizontal level bar, −60…0 dBFS. Observes only the meters so the rest of the screen does not redraw.
private struct LevelBar: View {
    @ObservedObject var meters: AssistMeters
    let id: Int
    var bus = false

    var body: some View {
        let db = (bus ? meters.buses[id] : meters.channels[id]) ?? -120
        let x = CGFloat(max(0, min(1, (db + 60) / 60)))
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(db > -3 ? Theme.statusError : db > -10 ? Theme.signalYellow : Theme.accent)
                    .frame(width: g.size.width * x)
            }
        }
        .animation(.linear(duration: 0.1), value: x)
    }
}

private struct ValueTile: View {
    var title: String
    var value: String
    var sub: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.textMuted).lineLimit(1)
            Text(value).font(Theme.mono(16, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1).minimumScaleFactor(0.7)
            Text(sub.isEmpty ? " " : sub).font(.system(size: 10)).foregroundStyle(Theme.textSecondary).lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.05)))
    }
}

/// Words for the assistant's notes and the guard's actions.
@MainActor
private struct Wording {
    let store: AssistStore
    let loc: Localizer

    func name(_ ch: Int) -> String {
        let n = store.strips.first { $0.id == ch }?.name ?? ""
        return n.isEmpty ? "Ch \(ch)" : n
    }

    func bus(_ id: Int) -> String {
        let n = store.buses.first { $0.id == id }?.name ?? ""
        return n.isEmpty ? "Bus \(id)" : n
    }

    func note(_ n: AssistNote) -> String {
        switch n {
        case .waitingForSignal: return loc.t("assist.note.waiting")
        case let .recognised(k, c): return String(format: loc.t("assist.note.recognised"), loc.t("assist.kind.\(k.rawValue)"), Int(c * 100))
        case let .gain(a, b): return String(format: loc.t("assist.note.gain"), a, b)
        case let .clipRisk(p): return String(format: loc.t("assist.note.clip"), p)
        case let .highPass(hz): return String(format: loc.t("assist.note.hpf"), hz)
        case let .eqBand(i, t, f, g, q):
            let type = t == .peaking ? String(format: "Q %.1f", q) : loc.t(t == .lowShelf ? "assist.lowShelf" : "assist.highShelf")
            return String(format: loc.t("assist.note.eq"), i + 1, PEQFilter.label(f), g, type)
        case let .compressor(thr, r, a, rel, gr): return String(format: loc.t("assist.note.comp"), thr, r, a, rel, gr)
        case .compressorOff: return loc.t("assist.note.compOff")
        case let .fader(db): return String(format: loc.t("assist.note.fader"), db)
        case let .feedback(f, d): return String(format: loc.t("assist.note.feedback"), PEQFilter.label(f), d)
        case let .polarityChecking(ref): return String(format: loc.t("assist.note.polChecking"), name(ref))
        case let .polarity(inv, d): return String(format: loc.t(inv ? "assist.note.polInverted" : "assist.note.polKept"), d)
        case let .polarityUnclear(d): return String(format: loc.t("assist.note.polUnclear"), d)
        case let .done(dev): return String(format: loc.t("assist.note.done"), dev)
        case let .gaveUp(r): return loc.t(r == "no signal" ? "assist.note.noSignal" : "assist.note.unsettled")
        }
    }

    func color(_ n: AssistNote) -> Color {
        switch n {
        case .done, .polarity: return Theme.statusGood
        case .feedback, .clipRisk, .gaveUp, .polarityUnclear: return Theme.statusWarning
        default: return Theme.textPrimary
        }
    }

    func action(_ a: GuardAction) -> String {
        switch a {
        case let .notch(ch, f, d): return String(format: loc.t("assist.g.notch"), name(ch), PEQFilter.label(f), d)
        case let .notchReleased(ch): return String(format: loc.t("assist.g.notchReleased"), name(ch))
        case let .monitorDip(b, d): return String(format: loc.t("assist.g.dip"), bus(b), d)
        case let .monitorRestored(b): return String(format: loc.t("assist.g.restored"), bus(b))
        case let .monitorHeld(b, d): return String(format: loc.t("assist.g.held"), bus(b), d)
        case let .unmask(ch, f, d): return String(format: loc.t("assist.g.unmask"), name(ch), PEQFilter.label(f), d)
        case let .unmaskReleased(ch): return String(format: loc.t("assist.g.unmaskReleased"), name(ch))
        case let .tonalHold(ch, f, d): return String(format: loc.t("assist.g.tonal"), name(ch), PEQFilter.label(f), d)
        case let .tonalReleased(ch): return String(format: loc.t("assist.g.tonalReleased"), name(ch))
        case let .yielded(ch, b): return String(format: loc.t("assist.g.yielded"), ch.map(name) ?? b.map(bus) ?? "")
        }
    }

    func stateBadge(_ s: TuningState?) -> StatusBadge {
        switch s {
        case .done?: return StatusBadge(level: .good, text: loc.t("assist.state.done"))
        case .listening?: return StatusBadge(level: .warning, text: loc.t("assist.state.listening"))
        case .tuning?: return StatusBadge(level: .warning, text: loc.t("assist.state.tuning"))
        default: return StatusBadge(level: .idle, text: loc.t("assist.state.idle"))
        }
    }
}

private func clock(_ t: Double, hours: Bool = false) -> String {
    let s = max(0, Int(t))
    return hours ? String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
}

// MARK: - Soundcheck

private struct SoundcheckScreen: View {
    @EnvironmentObject var store: AssistStore

    var body: some View {
        VStack(spacing: 12) {
            SoundcheckActions()
            if store.strips.isEmpty {
                NotConnectedCard()
            } else {
                HStack(alignment: .top, spacing: 12) {
                    ChannelList().frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                    ChannelDetail().frame(width: 470).frame(maxHeight: .infinity)
                }
                .frame(maxHeight: .infinity)
            }
        }
    }
}

private struct SoundcheckActions: View {
    @EnvironmentObject var store: AssistStore
    @EnvironmentObject var loc: Localizer

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { tools; Spacer(minLength: 10); job }
            VStack(alignment: .leading, spacing: 10) { tools; HStack { Spacer(); job } }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(GlassBackground())
    }

    private var tools: some View {
        HStack(spacing: 8) {
            Button { store.tune(.orchestra) } label: { Label(loc.t("assist.orchestra"), systemImage: "music.quarternote.3") }
                .buttonStyle(SSMTButtonStyle(kind: .primary))
            Button { store.tune(.choir) } label: { Label(loc.t("assist.choir"), systemImage: "person.3.fill") }
                .buttonStyle(SSMTButtonStyle(kind: .primary))
            Rectangle().fill(Theme.hairlineStrong).frame(width: 1, height: 22)
            Text(loc.t("assist.range")).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            Stepper("\(store.rangeFrom)", value: $store.rangeFrom, in: 1...max(1, store.strips.count)).monospacedDigit()
            Text("—").foregroundStyle(Theme.textMuted)
            Stepper("\(store.rangeTo)", value: $store.rangeTo, in: 1...max(1, store.strips.count)).monospacedDigit()
            Button(loc.t("assist.rangeGo")) { store.tune(.range(store.rangeFrom, store.rangeTo)) }
                .buttonStyle(SSMTButtonStyle())
            Rectangle().fill(Theme.hairlineStrong).frame(width: 1, height: 22)
            Button { store.checkPolarity() } label: { Label(loc.t("assist.polarity"), systemImage: "plusminus.circle") }
                .buttonStyle(SSMTButtonStyle())
        }
        .font(.system(size: 12))
        .fixedSize()
        .disabled(!store.isConnected || store.running)
    }

    private var job: some View {
        HStack(spacing: 10) {
            if store.running {
                ProgressView().controlSize(.small)
                Text(jobText).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.signalYellow).lineLimit(1)
                Button(loc.t("assist.stop")) { store.stopJob() }.buttonStyle(SSMTButtonStyle(kind: .danger))
            } else if store.groupPhase == .done {
                StatusBadge(level: .good, text: loc.t("assist.phase.done"))
            }
            Button(loc.t("assist.undoAll")) { store.undoAll() }
                .buttonStyle(SSMTButtonStyle())
                .disabled(!store.isConnected)
        }
        .fixedSize()
    }

    private var jobText: String {
        if let p = store.groupPhase { return loc.t("assist.phase.\(p.rawValue)") }
        switch store.job {
        case let .channel(ch): return Wording(store: store, loc: loc).name(ch) + " · " + loc.t("assist.state.tuning")
        case .polarity: return loc.t("assist.polarity")
        default: return loc.t("assist.state.tuning")
        }
    }
}

private struct NotConnectedCard: View {
    @EnvironmentObject var store: AssistStore
    @EnvironmentObject var loc: Localizer

    var body: some View {
        VStack(spacing: 14) {
            IconTile(systemName: "wifi", tint: Theme.accent, size: 56)
            Text(loc.t("assist.nc.title")).font(Theme.heading(20))
            Text(loc.t("assist.nc.text")).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 520)
            HStack(spacing: 10) {
                Button(loc.t("assist.connect")) { store.connect() }
                    .buttonStyle(SSMTButtonStyle(kind: .primary))
                    .disabled(!store.family.implemented || store.isConnected)
                Button(loc.t("assist.settings")) { store.showSettings = true }.buttonStyle(SSMTButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GlassBackground())
    }
}

private struct ChannelList: View {
    @EnvironmentObject var store: AssistStore
    @EnvironmentObject var loc: Localizer

    var body: some View {
        let shown = visible
        let groups = grouped(shown)
        let done = shown.filter { store.state(of: $0.id) == .done }.count
        Card(title: loc.t("assist.channels"), accessory: {
            Text(String(format: loc.t("assist.list.count"), done, shown.count))
                .font(Theme.mono(12)).foregroundStyle(Theme.textSecondary)
        }) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(groups, id: \.0) { group in
                        Text(loc.t("assist.group.\(group.0.rawValue)").uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .kerning(0.6)
                            .foregroundStyle(Theme.textMuted)
                            .padding(.horizontal, 14)
                            .padding(.top, 12)
                            .padding(.bottom, 4)
                        ForEach(group.1) { s in
                            ChannelRow(strip: s, kind: store.kind(of: s.id), state: store.state(of: s.id),
                                       selected: selectedID == s.id)
                                .onTapGesture { store.selectedChannel = s.id }
                        }
                    }
                    if store.strips.count > shown.count {
                        Text(String(format: loc.t("assist.list.hidden"), store.strips.count - shown.count))
                            .font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                            .padding(14)
                    }
                }
            }
        }
    }

    /// Channels with a name, a signal or a job; empty unused channels are hidden.
    private var visible: [ChannelStrip] {
        store.strips.filter { !$0.name.isEmpty || store.state(of: $0.id) != nil || store.features[$0.id]?.hasSignal == true }
    }

    private func grouped(_ strips: [ChannelStrip]) -> [(SourceFamily, [ChannelStrip])] {
        var by: [SourceFamily: [ChannelStrip]] = [:]
        for s in strips { by[store.kind(of: s.id)?.family ?? .other, default: []].append(s) }
        return SourceFamily.allCases.compactMap { f in by[f].map { (f, $0) } }
    }

    private var selectedID: Int? { ChannelDetail.selected(store) }
}

private struct ChannelRow: View {
    @EnvironmentObject var store: AssistStore
    @EnvironmentObject var loc: Localizer
    let strip: ChannelStrip
    let kind: SourceKind?
    let state: TuningState?
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text("\(strip.id)").font(Theme.mono(12)).foregroundStyle(Theme.textMuted).frame(width: 24, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(strip.name.isEmpty ? "Ch \(strip.id)" : strip.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if strip.polarityInverted {
                        Text("Ø").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.dataBlue)
                    }
                }
                Text(summary).font(.system(size: 11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            LevelBar(meters: store.liveMeters, id: strip.id).frame(width: 64, height: 5)
            Wording(store: store, loc: loc).stateBadge(state).fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(selected ? Theme.accent.opacity(0.10) : Color.clear)
        .overlay(alignment: .leading) {
            if selected { Rectangle().fill(Theme.accent).frame(width: 3) }
        }
        .contentShape(Rectangle())
    }

    private var summary: String {
        var parts = [kind.map { loc.t("assist.kind.\($0.rawValue)") } ?? "—"]
        parts.append(String(format: "%.0f dB", strip.gainDB))
        if strip.highPassOn { parts.append(String(format: "HPF %.0f", strip.highPassHz)) }
        if strip.compressor.enabled { parts.append(String(format: "%.1f:1", strip.compressor.ratio)) }
        return parts.joined(separator: " · ")
    }
}

private struct ChannelDetail: View {
    @EnvironmentObject var store: AssistStore
    @EnvironmentObject var loc: Localizer

    /// The chosen channel, else the one being tuned, else the first one with a name.
    static func selected(_ store: AssistStore) -> Int? {
        if let c = store.selectedChannel, store.strips.contains(where: { $0.id == c }) { return c }
        if case let .channel(ch) = store.job { return ch }
        return store.strips.first { store.state(of: $0.id) != nil }?.id ?? store.strips.first { !$0.name.isEmpty }?.id
    }

    var body: some View {
        if let id = Self.selected(store), let s = store.strips.first(where: { $0.id == id }) {
            detail(s)
        } else {
            Text(loc.t("assist.detail.empty")).font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(GlassBackground())
        }
    }

    private func detail(_ s: ChannelStrip) -> some View {
        let words = Wording(store: store, loc: loc)
        let entries = store.log(of: s.id)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(s.id) · \(words.name(s.id))").font(Theme.heading(18)).lineLimit(1)
                    Text(store.kind(of: s.id).map { loc.t("assist.kind.\($0.rawValue)") } ?? "—")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                words.stateBadge(store.state(of: s.id))
            }
            HStack(spacing: 8) {
                ValueTile(title: loc.t("assist.tile.gain"), value: String(format: "%.1f dB", s.gainDB),
                          sub: s.polarityInverted ? loc.t("assist.tile.inverted") : "")
                ValueTile(title: loc.t("assist.tile.hpf"), value: s.highPassOn ? String(format: "%.0f Hz", s.highPassHz) : loc.t("assist.off"))
                ValueTile(title: loc.t("assist.tile.comp"),
                          value: s.compressor.enabled ? String(format: "%.1f:1", s.compressor.ratio) : loc.t("assist.off"),
                          sub: s.compressor.enabled ? String(format: "%.0f dB", s.compressor.thresholdDB) : "")
                ValueTile(title: loc.t("assist.tile.deviation"), value: deviation(entries).map { String(format: "±%.1f dB", $0) } ?? "—")
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Text(loc.t("assist.detail.eq")).font(Theme.label(12)).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    legend(Theme.accent, loc.t("assist.detail.curve"))
                    legend(Theme.dataBlue.opacity(0.7), loc.t("assist.detail.spectrum"))
                }
                EQCurveView(strip: s, spectrum: store.features[s.id]?.bandsDB)
                    .frame(height: 170)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.25)))
                HStack(spacing: 6) {
                    ForEach(Array(s.eq.enumerated()), id: \.offset) { i, b in band(i, b, on: s.eqOn) }
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(loc.t("assist.detail.log")).font(Theme.label(12)).foregroundStyle(Theme.textSecondary)
                if entries.isEmpty {
                    Text(loc.t("assist.detail.nolog")).font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                }
                ForEach(Array(entries.suffix(7).reversed().enumerated()), id: \.offset) { _, e in
                    Text(words.note(e.note)).font(.system(size: 12)).foregroundStyle(words.color(e.note)).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            Button { store.tune(channel: s.id) } label: { Label(loc.t("assist.tuneOne"), systemImage: "wand.and.stars") }
                .buttonStyle(SSMTButtonStyle(kind: .primary))
                .disabled(!store.isConnected || store.running)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(GlassBackground())
    }

    private func deviation(_ entries: [AssistSession.LogEntry]) -> Double? {
        for e in entries.reversed() { if case let .done(d) = e.note { return d } }
        return nil
    }

    private func legend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1).fill(c).frame(width: 12, height: 3)
            Text(t).font(.system(size: 10)).foregroundStyle(Theme.textMuted)
        }
    }

    private func band(_ i: Int, _ b: StripEQBand, on: Bool) -> some View {
        let type = b.type == .peaking ? String(format: "Q %.1f", b.q) : loc.t(b.type == .lowShelf ? "assist.lowShelf" : "assist.highShelf")
        return VStack(alignment: .leading, spacing: 2) {
            Text(String(format: loc.t("assist.band"), i + 1) + " · " + type).font(.system(size: 10)).foregroundStyle(Theme.textMuted).lineLimit(1)
            Text(PEQFilter.label(b.frequency)).font(Theme.mono(12, weight: .semibold)).lineLimit(1)
            Text(String(format: "%+.1f dB", b.gainDB)).font(Theme.mono(12))
                .foregroundStyle(!on || abs(b.gainDB) < 0.5 ? Theme.textMuted : b.gainDB > 0 ? Theme.accent : Theme.signalYellow)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.05)))
    }
}

/// EQ + high-pass response of the strip on a log grid (20 Hz…20 kHz, ±15 dB), with the channel's measured
/// spectrum (relative to its mid-band average) behind it.
private struct EQCurveView: View {
    let strip: ChannelStrip
    let spectrum: [Double]?
    private let fMin = 20.0, fMax = 20000.0, range = 15.0

    var body: some View {
        Canvas { ctx, size in
            func x(_ f: Double) -> CGFloat { CGFloat(log10(f / fMin) / log10(fMax / fMin)) * size.width }
            func y(_ db: Double) -> CGFloat { CGFloat((range - max(-range, min(range, db))) / (2 * range)) * size.height }
            for f in [50.0, 100, 200, 500, 1000, 2000, 5000, 10000] {
                var p = Path(); p.move(to: CGPoint(x: x(f), y: 0)); p.addLine(to: CGPoint(x: x(f), y: size.height))
                ctx.stroke(p, with: .color(.white.opacity(0.06)), lineWidth: 1)
                ctx.draw(Text(PEQFilter.label(f)).font(.system(size: 9)).foregroundColor(Theme.textMuted),
                         at: CGPoint(x: x(f) + 3, y: size.height - 3), anchor: .bottomLeading)
            }
            for db in [-12.0, -6, 0, 6, 12] {
                var p = Path(); p.move(to: CGPoint(x: 0, y: y(db))); p.addLine(to: CGPoint(x: size.width, y: y(db)))
                ctx.stroke(p, with: .color(.white.opacity(db == 0 ? 0.16 : 0.06)), lineWidth: 1)
                if db != 0 {
                    ctx.draw(Text(String(format: "%+.0f", db)).font(.system(size: 9)).foregroundColor(Theme.textMuted),
                             at: CGPoint(x: 4, y: y(db) - 1), anchor: .bottomLeading)
                }
            }
            if let spectrum, spectrum.count == ThirdOctave.centers.count {
                let mid = ThirdOctave.centers.indices.filter { ThirdOctave.centers[$0] >= 100 && ThirdOctave.centers[$0] <= 8000 }
                let ref = mid.map { spectrum[$0] }.reduce(0, +) / Double(max(1, mid.count))
                var p = Path()
                for (i, f) in ThirdOctave.centers.enumerated() where spectrum[i] > -110 {
                    let pt = CGPoint(x: x(f), y: y((spectrum[i] - ref) * 0.5))
                    if p.isEmpty { p.move(to: pt) } else { p.addLine(to: pt) }
                }
                ctx.stroke(p, with: .color(Theme.dataBlue.opacity(0.55)), style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
            }
            var curve = Path()
            let n = 240
            for i in 0...n {
                let f = fMin * pow(fMax / fMin, Double(i) / Double(n))
                let pt = CGPoint(x: x(f), y: y(strip.filterResponseDB(at: f)))
                if i == 0 { curve.move(to: pt) } else { curve.addLine(to: pt) }
            }
            var area = curve
            area.addLine(to: CGPoint(x: size.width, y: y(0)))
            area.addLine(to: CGPoint(x: 0, y: y(0)))
            area.closeSubpath()
            ctx.fill(area, with: .color(Theme.accent.opacity(0.12)))
            ctx.stroke(curve, with: .color(Theme.accent), lineWidth: 2)
            if strip.eqOn {
                for b in strip.eq where abs(b.gainDB) >= 0.5 {
                    let c = CGPoint(x: x(b.frequency), y: y(strip.filterResponseDB(at: b.frequency)))
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)), with: .color(Theme.accent))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Show

private struct ShowScreen: View {
    var body: some View {
        VStack(spacing: 12) {
            GuardBanner()
            MonitorStrip()
            HStack(alignment: .top, spacing: 12) {
                CorrectionsCard().frame(maxWidth: .infinity, maxHeight: .infinity)
                ShowLogCard().frame(width: 420).frame(maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
        }
    }
}

private struct GuardBanner: View {
    @EnvironmentObject var store: AssistStore
    @EnvironmentObject var loc: Localizer
    @State private var simulation = false

    var body: some View {
        let on = store.guarding || store.rehearsing
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        HStack(spacing: 16) {
            Image(systemName: on ? "shield.lefthalf.filled" : "shield.slash")
                .font(.system(size: 20))
                .foregroundStyle(on ? Theme.accent : Theme.textMuted)
                .frame(width: 42, height: 42)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill((on ? Theme.accent : Color.white).opacity(on ? 0.2 : 0.06)))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(loc.t(on ? "assist.banner.on" : "assist.banner.off")).font(.system(size: 17, weight: .semibold))
                    if let sc = store.rehearsalScene, store.rehearsing {
                        StatusBadge(level: .warning, text: loc.t("assist.sim.scene.\(sc.rawValue)"))
                    }
                }
                Text(loc.t(on ? "assist.banner.text" : "assist.banner.textoff")).font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary).lineLimit(2)
            }
            Spacer(minLength: 10)
            if on {
                HStack(spacing: 20) {
                    stat("\(store.corrections.count)", loc.t("assist.stat.active"))
                    stat("\(total)", loc.t("assist.stat.total"))
                    stat(clock(store.guardElapsed, hours: true), loc.t("assist.stat.time"))
                }
                .fixedSize()
            }
            buttons.fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(shape.fill(LinearGradient(colors: [Theme.accent.opacity(on ? 0.16 : 0.04), Theme.accent.opacity(0.02)],
                                               startPoint: .leading, endPoint: .trailing)))
        .background(GlassBackground())
        .overlay(shape.strokeBorder(on ? Theme.accent.opacity(0.35) : Color.clear))
    }

    @ViewBuilder private var buttons: some View {
        HStack(spacing: 8) {
            if store.rehearsing {
                Button { store.stopRehearsal() } label: { Label(loc.t("assist.sim.stop"), systemImage: "stop.fill") }
                    .buttonStyle(SSMTButtonStyle(kind: .danger))
            } else {
                Button { simulation = true } label: { Label(loc.t("assist.sim.title"), systemImage: "play.fill") }
                    .buttonStyle(SSMTButtonStyle())
                    .disabled(!store.isConnected || store.guarding)
                    .popover(isPresented: $simulation, arrowEdge: .bottom) {
                        RehearsalControls().padding(16).frame(width: 400)
                            .environmentObject(store).environmentObject(loc)
                    }
                if store.guarding {
                    Button { store.stopGuard() } label: { Label(loc.t("assist.guard.off"), systemImage: "shield.slash") }
                        .buttonStyle(SSMTButtonStyle(kind: .danger))
                } else {
                    Button { store.startGuard() } label: { Label(loc.t("assist.guard.on"), systemImage: "shield.lefthalf.filled") }
                        .buttonStyle(SSMTButtonStyle(kind: .primary))
                        .disabled(!store.isConnected)
                }
            }
        }
    }

    /// Corrections started during this show.
    private var total: Int {
        store.guardLog.filter {
            switch $0.action {
            case .notch, .monitorDip, .unmask, .tonalHold: return true
            default: return false
            }
        }.count
    }

    private func stat(_ v: String, _ t: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(v).font(Theme.mono(20, weight: .semibold))
            Text(t).font(.system(size: 11)).foregroundStyle(Theme.textMuted)
        }
    }
}

private struct MonitorStrip: View {
    @EnvironmentObject var store: AssistStore
    @EnvironmentObject var loc: Localizer

    var body: some View {
        let mons = monitors
        let others = store.buses.filter { b in !mons.contains { $0.id == b.id } }
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(mons) { b in card(b) }
                if store.guardian != nil && !others.isEmpty {
                    Menu {
                        ForEach(others) { b in Button(b.name.isEmpty ? "Bus \(b.id)" : b.name) { store.setMonitor(b.id, true) } }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(loc.t("assist.mon.add")).font(.system(size: 12, weight: .semibold))
                            Text(loc.t("assist.mon.addhint")).font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                        }
                        .frame(width: 150, height: 66, alignment: .topLeading)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairlineStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                if mons.isEmpty {
                    Text(loc.t("assist.mon.none")).font(.system(size: 12)).foregroundStyle(Theme.textMuted).frame(maxWidth: 420, alignment: .leading)
                }
            }
        }
    }

    private var monitors: [BusStrip] {
        if let g = store.guardian { return store.buses.filter { g.monitorBuses.contains($0.id) } }
        return store.buses.filter(\.looksLikeMonitor)
    }

    private func card(_ b: BusStrip) -> some View {
        let dip = store.corrections.first { $0.kind == .monitorDip && $0.target == b.id }
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(b.name.isEmpty ? "Bus \(b.id)" : b.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                if store.guardian != nil {
                    Button { store.setMonitor(b.id, false) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                        .buttonStyle(.plain).foregroundStyle(Theme.textMuted)
                }
            }
            LevelBar(meters: store.liveMeters, id: b.id, bus: true).frame(height: 8)
            HStack {
                Text(b.faderDB <= -90 ? "−∞" : String(format: "%+.1f dB", b.faderDB)).font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 4)
                if let dip {
                    Text(dip.restoreInSeconds.map { String(format: loc.t("assist.mon.restore"), Int($0.rounded(.up))) } ?? loc.t("assist.mon.holding"))
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.signalYellow).lineLimit(1)
                } else {
                    Text(loc.t("assist.mon.ok")).font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                }
            }
        }
        .padding(12)
        .frame(width: 174)
        .background(shape.fill(dip != nil ? Theme.signalYellow.opacity(0.08) : Color.clear))
        .background(GlassBackground(radius: 12))
        .overlay(shape.strokeBorder(dip != nil ? Theme.signalYellow.opacity(0.55) : Color.clear))
    }
}

private struct CorrectionsCard: View {
    @EnvironmentObject var store: AssistStore
    @EnvironmentObject var loc: Localizer

    var body: some View {
        Card(title: loc.t("assist.corr.title"), tint: Theme.signalYellow, accessory: {
            Text(loc.t("assist.corr.hint")).font(.system(size: 11)).foregroundStyle(Theme.textMuted).lineLimit(1)
        }) {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if store.corrections.isEmpty {
                            Label(loc.t("assist.corr.empty"), systemImage: "checkmark.circle")
                                .font(.system(size: 13)).foregroundStyle(Theme.textSecondary).padding(16)
                        }
                        ForEach(store.corrections) { c in row(c) }
                    }
                }
                .frame(maxHeight: .infinity)
                Rectangle().fill(Theme.hairline).frame(height: 1)
                LeadsRow().padding(14)
            }
        }
    }

    private func row(_ c: ShowGuard.Correction) -> some View {
        let w = Wording(store: store, loc: loc)
        let (icon, tint) = style(c.kind)
        let f = c.frequency.map { PEQFilter.label($0) } ?? ""
        let title: String
        let text: String
        let when: String
        switch c.kind {
        case .monitorDip:
            title = String(format: loc.t("assist.corr.dip.title"), w.bus(c.target))
            text = loc.t("assist.corr.dip.text")
            when = c.restoreInSeconds.map { String(format: loc.t("assist.mon.restore"), Int($0.rounded(.up))) } ?? loc.t("assist.corr.untilquiet")
        case .notch:
            title = String(format: loc.t("assist.corr.notch.title"), w.name(c.target), f)
            text = loc.t("assist.corr.notch.text")
            when = loc.t("assist.corr.untilquiet")
        case .unmask:
            title = String(format: loc.t("assist.corr.unmask.title"), w.name(c.target))
            text = String(format: loc.t("assist.corr.unmask.text"), f)
            when = loc.t("assist.corr.untilscene")
        case .tonal:
            title = String(format: loc.t("assist.corr.tonal.title"), w.name(c.target))
            text = String(format: loc.t("assist.corr.tonal.text"), f)
            when = loc.t("assist.corr.untilquiet")
        }
        return HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 14)).foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(text).font(.system(size: 11)).foregroundStyle(Theme.textSecondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(String(format: "%+.0f dB", c.amountDB)).font(Theme.mono(14, weight: .semibold))
                Text(when).font(.system(size: 10)).foregroundStyle(Theme.textMuted).lineLimit(1)
            }
            .fixedSize()
            Button(loc.t("assist.corr.cancel")) { store.cancelCorrection(c.id) }
                .buttonStyle(SSMTButtonStyle())
                .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private func style(_ k: ShowGuard.Correction.Kind) -> (String, Color) {
        switch k {
        case .monitorDip: return ("speaker.wave.3.fill", Theme.signalYellow)
        case .notch: return ("waveform.path.badge.minus", Theme.statusError)
        case .unmask: return ("person.wave.2.fill", Theme.dataBlue)
        case .tonal: return ("dial.low", Theme.accent)
        }
    }
}

private struct LeadsRow: View {
    @EnvironmentObject var store: AssistStore
    @EnvironmentObject var loc: Localizer

    var body: some View {
        let leads = store.guardian?.leads ?? []
        let named = store.strips.filter { !$0.name.isEmpty }
        VStack(alignment: .leading, spacing: 6) {
            Text(loc.t("assist.guard.leads")).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(named.filter { leads.contains($0.id) }) { s in
                        Button { store.setLead(s.id, false) } label: {
                            HStack(spacing: 5) {
                                Text(s.name)
                                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                            }
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Theme.accent.opacity(0.14)))
                        }
                        .buttonStyle(.plain)
                    }
                    if store.guardian != nil {
                        Menu {
                            ForEach(named.filter { !leads.contains($0.id) }) { s in Button(s.name) { store.setLead(s.id, true) } }
                        } label: {
                            Text(loc.t("assist.leads.add")).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                    } else {
                        Text(loc.t("assist.leads.off")).font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                    }
                }
            }
        }
    }
}

/// The guard's actions and the engineer's own moves (simulation) in one timeline; the engineer in blue.
private struct ShowLogCard: View {
    @EnvironmentObject var store: AssistStore
    @EnvironmentObject var loc: Localizer

    private struct Line { var time: Double; var text: String; var color: Color }

    var body: some View {
        Card(title: loc.t("assist.journal"), tint: Theme.dataSecondary, accessory: {
            HStack(spacing: 4) {
                Text(loc.t("assist.journal.assistant")).foregroundStyle(Theme.textMuted)
                Text("·").foregroundStyle(Theme.textMuted)
                Text(loc.t("assist.journal.you")).foregroundStyle(Theme.dataBlue)
            }
            .font(.system(size: 11))
        }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    let ls = lines
                    if ls.isEmpty {
                        Text(loc.t("assist.guard.empty")).font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                    }
                    ForEach(Array(ls.enumerated()), id: \.offset) { _, l in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(clock(l.time)).font(Theme.mono(11)).foregroundStyle(Theme.textMuted).frame(width: 40, alignment: .leading)
                            Text(l.text).font(.system(size: 12)).foregroundStyle(l.color).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var lines: [Line] {
        let w = Wording(store: store, loc: loc)
        var out: [Line] = store.guardLog.suffix(60).map { e in
            if case .yielded = e.action { return Line(time: e.time, text: w.action(e.action), color: Theme.dataBlue) }
            return Line(time: e.time, text: w.action(e.action), color: Theme.textPrimary)
        }
        for e in store.rehearsalLog.suffix(40) {
            switch e.event {
            case let .scene(sc): out.append(Line(time: e.time, text: "▶ " + loc.t("assist.sim.scene.\(sc.rawValue)"), color: Theme.textSecondary))
            case let .engineerFader(ch, db): out.append(Line(time: e.time, text: String(format: loc.t("assist.sim.fader"), w.name(ch), db), color: Theme.dataBlue))
            case let .engineerBus(b, db): out.append(Line(time: e.time, text: String(format: loc.t("assist.sim.bus"), w.bus(b), db), color: Theme.dataBlue))
            }
        }
        return out.enumerated().sorted { ($0.element.time, $0.offset) > ($1.element.time, $1.offset) }.map(\.element)
    }
}

// MARK: - Console test

private struct ConsoleTestScreen: View {
    @EnvironmentObject var store: AssistStore
    @EnvironmentObject var loc: Localizer

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Panel(title: loc.t("assist.test"), tint: Theme.signalYellow) { ConsoleTestPanel() }
                .frame(width: 440)
            Card(title: loc.t("assist.test.report"), tint: Theme.dataSecondary, accessory: { EmptyView() }) {
                ScrollView { TestStepper().padding(16) }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// The test report as a vertical stepper: status mark, step, what was checked.
private struct TestStepper: View {
    @EnvironmentObject var store: AssistStore
    @EnvironmentObject var loc: Localizer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.testChecks.isEmpty {
                Text(loc.t("assist.test.empty")).font(.system(size: 12)).foregroundStyle(Theme.textMuted)
            }
            ForEach(Array(store.testChecks.enumerated()), id: \.element.id) { i, c in
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 0) {
                        mark(c.status)
                        if i < store.testChecks.count - 1 {
                            Rectangle().fill(Theme.hairlineStrong).frame(width: 2).frame(minHeight: 18, maxHeight: .infinity)
                        }
                    }
                    .frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(loc.t("assist.test.step.\(c.id)")).font(.system(size: 13, weight: .semibold))
                            Text(loc.t("assist.test.status.\(c.status.rawValue)")).font(.system(size: 11)).foregroundStyle(color(c.status))
                        }
                        Text(c.detail).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.bottom, 14)
                }
            }
        }
    }

    @ViewBuilder private func mark(_ s: ConsoleTestCheck.Status) -> some View {
        switch s {
        case .ok: CheckDot(done: true)
        case .failed: CheckDot(done: false, failed: true)
        case .warning:
            Image(systemName: "exclamationmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.black)
                .frame(width: 22, height: 22).background(Circle().fill(Theme.statusWarning))
        case .running: ProgressView().controlSize(.small).frame(width: 22, height: 22)
        }
    }

    private func color(_ s: ConsoleTestCheck.Status) -> Color {
        switch s {
        case .ok: return Theme.statusGood
        case .warning, .running: return Theme.statusWarning
        case .failed: return Theme.statusError
        }
    }
}

// MARK: - Settings and controls

private struct ConnectionPanel: View {
    @EnvironmentObject var store: AssistStore
    @EnvironmentObject var loc: Localizer

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Picker(loc.t("assist.mixer"), selection: $store.family) {
                    ForEach(MixerFamily.allCases, id: \.self) { f in
                        Text(loc.t("assist.family.\(f.rawValue)") + (f.implemented ? "" : " — " + loc.t("assist.soon"))).tag(f)
                    }
                }
                .frame(width: 330)
                if store.family != .simulator {
                    TextField("192.168.1.64", text: $store.host).textFieldStyle(.roundedBorder).frame(width: 140)
                }
                Button(store.isConnected ? loc.t("assist.disconnect") : loc.t("assist.connect")) {
                    store.isConnected ? store.disconnect() : store.connect()
                }
                .buttonStyle(SSMTButtonStyle(kind: store.isConnected ? .secondary : .primary))
                .disabled(!store.family.implemented)
                status
            }
            if store.family != .simulator {
                Picker(loc.t("assist.source"), selection: $store.signalSource) {
                    Text(loc.t("assist.source.network")).tag(AssistStore.SignalSource.network)
                    Text(loc.t("assist.source.interface")).tag(AssistStore.SignalSource.interface)
                }
                .pickerStyle(.segmented)
                .frame(width: 520)
                .onChange(of: store.signalSource) { _ in store.restartCapture() }
                HStack(spacing: 10) {
                    Picker(loc.t("assist.audioIn"), selection: $store.inputDeviceUID) {
                        Text(loc.t("assist.systemInput")).tag(String?.none)
                        ForEach(store.inputDevices, id: \.uid) { d in Text("\(d.name) · \(d.inputChannels) in").tag(String?.some(d.uid)) }
                    }
                    .frame(width: 330)
                    .onChange(of: store.inputDeviceUID) { _ in store.restartCapture() }
                    if store.signalSource == .interface {
                        Stepper(String(format: loc.t("assist.firstInput"), store.firstInput), value: $store.firstInput, in: 1...64)
                    }
                    Stepper(store.micInput == 0 ? loc.t("assist.noMic") : String(format: loc.t("assist.micInput"), store.micInput),
                            value: $store.micInput, in: 0...64)
                        .onChange(of: store.micInput) { _ in store.restartCapture() }
                    Stepper(store.stageMicInput == 0 ? loc.t("assist.noStageMic") : String(format: loc.t("assist.stageMicInput"), store.stageMicInput),
                            value: $store.stageMicInput, in: 0...64)
                        .onChange(of: store.stageMicInput) { _ in store.restartCapture() }
                }
                .font(.system(size: 12))
                Text(loc.t(store.signalSource == .network ? "assist.networkHint" : "assist.audioHint"))
                    .font(.system(size: 11)).foregroundStyle(Theme.textMuted)
            }
            HStack(spacing: 10) {
                Picker(loc.t("assist.measMic"), selection: $store.micID) {
                    Text(loc.t("assist.measMic.fromSetup")).tag(UUID?.none)
                    ForEach(store.micChoices) { m in Text(m.typical ? m.name + " · " + loc.t("assist.typical") : m.name).tag(UUID?.some(m.id)) }
                }
                .frame(width: 420)
                if let l = store.micLevel {
                    Text(String(format: store.micCalibrated ? "%.0f dB(A)" : "%.0f dBFS(A)", l)).monospacedDigit()
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
            }
            HStack(spacing: 10) {
                Picker(loc.t("assist.character"), selection: $store.character) {
                    ForEach(MixCharacter.allCases, id: \.self) { c in Text(loc.t("assist.char.\(c.rawValue)")).tag(c) }
                }
                .pickerStyle(.segmented)
                .frame(width: 420)
                Picker(loc.t("assist.tap"), selection: $store.tap) {
                    Text(loc.t("assist.tap.preEQ")).tag(TapPoint.preEQ)
                    Text(loc.t("assist.tap.postEQ")).tag(TapPoint.postEQ)
                }
                .frame(width: 260)
            }
            Text(loc.t("assist.char.\(store.character.rawValue).hint")).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
        }
    }

    @ViewBuilder private var status: some View {
        switch store.connection {
        case .disconnected: StatusBadge(level: .idle, text: loc.t("assist.offline"))
        case .connecting: StatusBadge(level: .warning, text: loc.t("assist.connecting"))
        case let .connected(t): StatusBadge(level: .good, text: t)
        case let .failed(t): StatusBadge(level: .error, text: t == "not supported yet" ? loc.t("assist.soon") : t)
        }
    }
}


private struct ConsoleTestPanel: View {
    @EnvironmentObject var store: AssistStore
    @EnvironmentObject var loc: Localizer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(loc.t("assist.test.hint")).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            Picker(loc.t("assist.test.scenario"), selection: $store.testScenario) {
                ForEach(AssistScenario.all) { s in Text(loc.t("assist.scenario.\(s.id)") + " · \(s.channels.count) ch").tag(s.id) }
            }
            .frame(width: 400)
            Stepper(String(format: loc.t("assist.test.first"), store.testFirst), value: $store.testFirst, in: 1...32)
                .font(.system(size: 12))
            Toggle(loc.t("assist.test.muteMain"), isOn: $store.testMuteMain).font(.system(size: 12))
            Label(loc.t("assist.test.warning"), systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11)).foregroundStyle(Theme.statusWarning)
            HStack {
                Button { store.runConsoleTest() } label: {
                    Label(store.testing ? loc.t("assist.test.running") : loc.t("assist.test.run"), systemImage: "checklist")
                }
                .buttonStyle(SSMTButtonStyle(kind: .primary))
                .disabled(store.testing || (store.family != .simulator && !store.isConnected))
                if store.testing { ProgressView().controlSize(.small) }
            }
        }
    }
}


private struct RehearsalControls: View {
    @EnvironmentObject var store: AssistStore
    @EnvironmentObject var loc: Localizer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(loc.t("assist.sim.title")).font(Theme.label(12)).foregroundStyle(Theme.textSecondary)
            Text(loc.t("assist.sim.hint")).font(.system(size: 11)).foregroundStyle(Theme.textMuted)
            HStack(spacing: 8) {
                Picker("", selection: $store.testScenario) {
                    ForEach(AssistScenario.all) { s in Text(loc.t("assist.scenario.\(s.id)")).tag(s.id) }
                }
                .labelsHidden()
                .frame(width: 170)
                .disabled(store.rehearsing)
                Stepper(String(format: loc.t("assist.sim.scene"), Int(store.rehearsalSceneSeconds)), value: $store.rehearsalSceneSeconds, in: 10...60, step: 5)
                    .font(.system(size: 12))
                    .disabled(store.rehearsing)
            }
            HStack(spacing: 8) {
                if store.rehearsing {
                    Button { store.stopRehearsal() } label: { Label(loc.t("assist.sim.stop"), systemImage: "stop.fill") }
                        .buttonStyle(SSMTButtonStyle(kind: .danger))
                    if let sc = store.rehearsalScene {
                        StatusBadge(level: .warning, text: loc.t("assist.sim.scene.\(sc.rawValue)"))
                    }
                } else {
                    Button { store.startRehearsal() } label: { Label(loc.t("assist.sim.start"), systemImage: "play.fill") }
                        .buttonStyle(SSMTButtonStyle(kind: .primary))
                        .disabled(!store.isConnected || store.guarding)
                }
            }
            if store.family == .x32 || store.family == .xAir {
                Label(loc.t("assist.sim.warning"), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(Theme.statusWarning)
            }
        }
    }
}

