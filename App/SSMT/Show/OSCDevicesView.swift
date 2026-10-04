import SSMTCore
import SwiftUI

extension OSCDeviceKind {
    /// Product name (the same in every language).
    var brand: String {
        switch self {
        case .resolume: return "Resolume"
        case .eos: return "ETC Eos"
        case .grandMA3: return "grandMA3"
        case .magicQ: return "MagicQ"
        case .x32: return "X32"
        case .qlab: return "QLab"
        case .generic: return "OSC"
        }
    }

    var icon: String {
        switch self {
        case .resolume: return "play.rectangle.on.rectangle"
        case .eos, .grandMA3, .magicQ: return "lightbulb.2"
        case .x32: return "slider.vertical.3"
        case .qlab: return "list.bullet.rectangle"
        case .generic: return "antenna.radiowaves.left.and.right"
        }
    }
}

/// OSC devices of the show: a guided setup for each kind, connection test, network hints, monitor.
struct OSCDevicesView: View {
    @EnvironmentObject var show: ShowStore
    @EnvironmentObject var loc: Localizer
    @State private var page: Page = .list
    @State private var draft = OSCDevice(name: "", kind: .resolume)
    @State private var isNew = true
    @State private var testState: OSCHub.TestResult?
    @State private var testing = false
    @State private var monitorPort = "53535"

    enum Page { case list, choose, setup, monitor }

    init(startWith kind: OSCDeviceKind? = nil) {
        if let kind {
            _page = State(initialValue: .setup)
            _draft = State(initialValue: Self.newDevice(kind, name: kind.brand))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                if page != .list {
                    Button { page = .list } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                }
                Text(title).font(Theme.heading(17))
                Spacer()
                Button(loc.t("settings.done")) { show.showOSC = false }.buttonStyle(SSMTButtonStyle(kind: .primary))
            }
            switch page {
            case .list: list
            case .choose: choose
            case .setup: setup
            case .monitor: monitor
            }
        }
        .padding(20)
        .frame(width: 640, height: 600, alignment: .topLeading)
        .background(Backdrop())
        .onAppear { if let k = show.oscWizardKind { start(k); show.oscWizardKind = nil } }
    }

    private var title: String {
        switch page {
        case .list: return loc.t("osc.title")
        case .choose: return loc.t("osc.choose")
        case .setup: return loc.t("osc.kind.\(draft.kind.rawValue)")
        case .monitor: return loc.t("osc.monitor")
        }
    }

    // MARK: List

    private var list: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(loc.t("osc.intro")).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if show.doc.devices.isEmpty {
                Text(loc.t("osc.none")).font(.system(size: 13)).foregroundStyle(Theme.textMuted).padding(.vertical, 20)
            }
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(show.doc.devices) { d in
                        HStack(spacing: 10) {
                            Image(systemName: d.kind.icon).frame(width: 22).foregroundStyle(Theme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(d.name).font(.system(size: 13, weight: .semibold))
                                Text("\(loc.t("osc.kind.\(d.kind.rawValue)")) · \(d.host):\(String(d.port))")
                                    .font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
                            }
                            Spacer()
                            if subnetOK(d.host) == false {
                                Label(loc.t("osc.subnet.short"), systemImage: "exclamationmark.triangle.fill")
                                    .font(.system(size: 11)).foregroundStyle(Theme.statusWarning)
                            }
                            Button(loc.t("osc.edit")) { draft = d; isNew = false; testState = nil; page = .setup }
                                .buttonStyle(ToolButtonStyle())
                            Button { show.edit { $0.devices.removeAll { $0.id == d.id } } } label: { Image(systemName: "trash") }
                                .buttonStyle(ToolButtonStyle())
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.05)))
                    }
                }
            }
            HStack {
                Button { page = .choose } label: { Label(loc.t("osc.add"), systemImage: "plus") }
                    .buttonStyle(SSMTButtonStyle(kind: .primary))
                Button { page = .monitor } label: { Label(loc.t("osc.monitor"), systemImage: "waveform.path.ecg.rectangle") }
                    .buttonStyle(SSMTButtonStyle())
                Spacer()
            }
            myAddresses
        }
    }

    private var myAddresses: some View {
        let ifs = OSCHub.interfaces()
        return VStack(alignment: .leading, spacing: 4) {
            Text(loc.t("osc.myip")).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
            if ifs.isEmpty { Text(loc.t("osc.noNetwork")).font(.system(size: 12)).foregroundStyle(Theme.statusWarning) }
            ForEach(ifs, id: \.self) { i in
                Text("\(i.address)  ·  \(i.name)").font(Theme.mono(12)).textSelection(.enabled)
            }
        }
    }

    private func subnetOK(_ host: String) -> Bool? {
        IPv4.reachableDirectly(host, interfaces: OSCHub.interfaces().map { ($0.address, $0.mask) })
    }

    // MARK: Choose

    private var choose: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            ForEach(OSCDeviceKind.allCases, id: \.self) { k in
                Button { start(k) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: k.icon).font(.system(size: 20)).foregroundStyle(Theme.accent).frame(width: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(loc.t("osc.kind.\(k.rawValue)")).font(.system(size: 14, weight: .semibold))
                            Text(loc.t("osc.kind.\(k.rawValue).hint")).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                                .lineLimit(2).multilineTextAlignment(.leading)
                        }
                        Spacer()
                    }
                    .foregroundStyle(Theme.textPrimary)
                    .padding(12)
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Media servers and QLab usually run on this Mac; consoles never do, so their address starts empty
    /// (a forgotten 127.0.0.1 would silently send the show's commands back to this Mac).
    private static func newDevice(_ kind: OSCDeviceKind, name: String) -> OSCDevice {
        var d = OSCDevice(name: name, kind: kind)
        if kind != .resolume && kind != .qlab { d.host = "" }
        return d
    }

    private func start(_ k: OSCDeviceKind) {
        draft = Self.newDevice(k, name: loc.t("osc.kind.\(k.rawValue)"))
        isNew = true
        testState = nil
        page = .setup
    }

    // MARK: Setup

    private var setup: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Step 1: what to switch on in the device.
                step(1, loc.t("osc.step.device")) {
                    Text(loc.t("osc.howto.\(draft.kind.rawValue)"))
                        .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if draft.kind == .eos || draft.kind == .grandMA3 {
                        Text(String(format: loc.t("osc.yourip"), OSCHub.interfaces().first?.address ?? "—"))
                            .font(Theme.mono(12)).foregroundStyle(Theme.signalYellow).textSelection(.enabled)
                    }
                }
                // Step 2: where it is.
                step(2, loc.t("osc.step.address")) {
                    HStack(spacing: 10) {
                        labeled(loc.t("osc.name")) { TextField("", text: $draft.name).textFieldStyle(.roundedBorder) }
                    }
                    HStack(alignment: .bottom, spacing: 10) {
                        labeled(loc.t("osc.host")) {
                            HStack {
                                TextField("192.168.1.30", text: $draft.host).textFieldStyle(.roundedBorder)
                                Button(loc.t("osc.thisMac")) { draft.host = "127.0.0.1" }.buttonStyle(ToolButtonStyle())
                                    .help(loc.t("osc.thisMac.help"))
                            }
                        }
                        labeled(loc.t("osc.port")) {
                            TextField("", value: Binding(get: { Int(draft.port) }, set: { draft.port = UInt16(clamping: $0) }),
                                      format: .number.grouping(.never)).textFieldStyle(.roundedBorder).frame(width: 80)
                        }
                        if draft.kind == .grandMA3 {
                            labeled(loc.t("osc.prefix")) { TextField("gma3", text: $draft.prefix).textFieldStyle(.roundedBorder).frame(width: 90) }
                        }
                    }
                    if let ok = subnetOK(draft.host), !ok {
                        Label(loc.t("osc.subnet.warning"), systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12)).foregroundStyle(Theme.statusWarning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                // Step 3: check.
                step(3, loc.t("osc.step.test")) {
                    if draft.kind.probe != nil {
                        HStack(spacing: 10) {
                            Button {
                                testing = true
                                let d = draft
                                Task { testState = await show.osc.test(d); testing = false }
                            } label: { Label(loc.t("osc.test"), systemImage: "bolt.horizontal") }
                                .buttonStyle(SSMTButtonStyle())
                                .disabled(testing || draft.host.isEmpty)
                            if testing { ProgressView().controlSize(.small) }
                            if let r = testState {
                                Label(loc.t(r == .answered ? "osc.test.ok" : "osc.test.fail"),
                                      systemImage: r == .answered ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(r == .answered ? Theme.statusGood : Theme.statusError)
                                    .font(.system(size: 12, weight: .semibold))
                            }
                        }
                        if testState == .noAnswer {
                            Text(loc.t("osc.test.fail.hint")).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Text(loc.t("osc.test.udp")).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let first = OSCPreset.presets(for: draft.kind).first {
                            Button {
                                show.osc.send(first.message([:], device: draft), to: draft)
                            } label: { Label(String(format: loc.t("osc.test.send"), loc.t("osc.preset.\(first.id)")), systemImage: "paperplane") }
                                .buttonStyle(SSMTButtonStyle())
                        }
                    }
                }
                Text(loc.t("osc.find.\(draft.kind.rawValue)")).font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button(loc.t(isNew ? "osc.save.new" : "osc.save")) {
                        let d = draft
                        show.edit { doc in
                            if let i = doc.devices.firstIndex(where: { $0.id == d.id }) { doc.devices[i] = d } else { doc.devices.append(d) }
                        }
                        page = .list
                    }
                    .buttonStyle(SSMTButtonStyle(kind: .primary))
                    .disabled(draft.host.isEmpty || draft.name.isEmpty)
                }
            }
        }
    }

    private func step<C: View>(_ n: Int, _ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)").font(.system(size: 13, weight: .bold)).foregroundStyle(.black)
                .frame(width: 24, height: 24).background(Circle().fill(Theme.accent))
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 14, weight: .semibold))
                content()
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.04)))
    }

    private func labeled<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            content()
        }
    }

    // MARK: Monitor

    private var monitor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(loc.t("osc.monitor.hint")).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Text(loc.t("osc.port")).font(.system(size: 12))
                TextField("", text: $monitorPort).textFieldStyle(.roundedBorder).frame(width: 80)
                if show.osc.listening == nil {
                    Button(loc.t("osc.monitor.start")) { show.osc.listen(on: UInt16(monitorPort) ?? 53535) }
                        .buttonStyle(SSMTButtonStyle(kind: .primary))
                } else {
                    Button(loc.t("osc.monitor.stop")) { show.osc.stopListening() }.buttonStyle(SSMTButtonStyle())
                    Label(String(format: loc.t("osc.monitor.on"), Int(show.osc.listening ?? 0)), systemImage: "dot.radiowaves.left.and.right")
                        .font(.system(size: 12)).foregroundStyle(Theme.statusGood)
                }
                Spacer()
                Button(loc.t("osc.monitor.clear")) { show.osc.clearLog() }.buttonStyle(.borderless)
            }
            if let e = show.osc.listenError {
                Text(e).font(.system(size: 11)).foregroundStyle(Theme.statusError)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(show.osc.log.reversed()) { e in
                        HStack(spacing: 8) {
                            Text(e.time.formatted(date: .omitted, time: .standard)).font(Theme.mono(10)).foregroundStyle(Theme.textMuted)
                            Text(e.from).font(Theme.mono(10)).foregroundStyle(Theme.textSecondary).frame(width: 110, alignment: .leading)
                            Text(e.message.display).font(Theme.mono(11)).textSelection(.enabled).lineLimit(1)
                            Spacer()
                            Button(loc.t("osc.monitor.makeCue")) { show.addNetworkCue(from: e) }
                                .buttonStyle(.borderless).font(.system(size: 11))
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.3)))
        }
    }
}
