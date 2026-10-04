import SSMTCore
import SwiftUI

/// Right column: every setting of the selected cue.
/// Inspector tabs; which ones appear depends on the cue type.
enum InspectorTab: String, CaseIterable {
    case main, multitrack, time, action, outputs, pad

    static func tabs(for cue: Cue, isPad: Bool) -> [InspectorTab] {
        var t: [InspectorTab] = [.main]
        if cue.kind == .group { t.append(.multitrack) }
        t.append(.time)
        if cue.kind != .memo { t.append(.action) }
        if cue.kind == .audio { t.append(.outputs) }
        if isPad { t.append(.pad) }
        return t
    }
}

struct CueInspector: View {
    @EnvironmentObject var show: ShowStore
    @EnvironmentObject var loc: Localizer

    var body: some View {
        Group {
            if show.selection.count == 1, let id = show.selection.first, let cue = show.doc.cue(id) {
                let isPad = show.doc.banks.contains { $0.cues.findCue(id) != nil }
                let tabs = InspectorTab.tabs(for: cue, isPad: isPad)
                let current = tabs.contains(show.inspectorTab) ? show.inspectorTab : .main
                VStack(spacing: 10) {
                    HStack(spacing: 4) {
                        ForEach(tabs, id: \.self) { t in
                            Button { show.inspectorTab = t } label: {
                                Text(loc.t("show.tab.\(t.rawValue)"))
                                    .font(.system(size: 12, weight: t == current ? .semibold : .regular))
                                    .lineLimit(1)
                                    .padding(.horizontal, 9).padding(.vertical, 5)
                                    .frame(maxWidth: .infinity)
                                    .background(Capsule().fill(t == current ? Theme.accent.opacity(0.2) : Color.white.opacity(0.05)))
                                    .foregroundStyle(t == current ? Theme.textPrimary : Theme.textSecondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            CueInspectorContent(cue: cue, tab: current)
                        }
                        .padding(.bottom, 12)
                    }
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 26)).foregroundStyle(Theme.textMuted)
                    Text(show.selection.count > 1 ? String(format: loc.t("show.inspector.many"), show.selection.count) : loc.t("show.inspector.none"))
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .glassCard(padding: 16)
            }
        }
    }
}

private struct CueInspectorContent: View {
    @EnvironmentObject var show: ShowStore
    @EnvironmentObject var loc: Localizer
    var cue: Cue
    var tab: InspectorTab

    var body: some View {
        switch tab {
        case .main: mainSection
        case .multitrack: ShowTimelineView(group: cue.id).frame(height: 230)
        case .time: timingSection
        case .action: actionSection
        case .outputs: outputsSection
        case .pad: padSection
        }
    }

    @ViewBuilder private var mainSection: some View {
        section(loc.t("cue.kind.\(cue.kind.rawValue)"), icon: cue.kind.icon) {
            HStack(spacing: 8) {
                field(loc.t("show.col.number"), text: bind(\.number)).frame(width: 70)
                field(loc.t("show.col.name"), text: bind(\.name))
            }
            VStack(alignment: .leading, spacing: 4) {
                caption(loc.t("show.notes"))
                TextEditor(text: bind(\.notes))
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .frame(height: 54)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.25)))
            }
            HStack(spacing: 6) {
                ForEach(CueColor.allCases, id: \.rawValue) { c in
                    Button { show.updateCue(cue.id) { $0.color = c.rawValue } } label: {
                        Circle().fill(c == .none ? Color.white.opacity(0.08) : c.color)
                            .frame(width: 16, height: 16)
                            .overlay(Circle().strokeBorder(Color.white.opacity(cue.color == c.rawValue ? 0.9 : 0.15), lineWidth: cue.color == c.rawValue ? 2 : 1))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Toggle(loc.t("show.armed"), isOn: bind(\.armed)).toggleStyle(.switch).controlSize(.mini)
            }
        }
    }

    @ViewBuilder private var timingSection: some View {
        section(loc.t("show.timing"), icon: "timer") {
            HStack(spacing: 8) {
                seconds(loc.t("show.preWait"), bind(\.preWait))
                seconds(loc.t("show.postWait"), bind(\.postWait)).disabled(cue.continueMode != .autoContinue)
            }
            VStack(alignment: .leading, spacing: 4) {
                caption(loc.t("show.continue"))
                Picker("", selection: bind(\.continueMode)) {
                    ForEach(ContinueMode.allCases, id: \.self) { Text(loc.t("continue.\($0.rawValue)")).tag($0) }
                }
                .labelsHidden()
            }
            HStack {
                caption(loc.t("show.hotkey"))
                Spacer()
                TextField("—", text: Binding(get: { cue.hotkey ?? "" }, set: { v in
                    let key = v.trimmingCharacters(in: .whitespaces).suffix(1)
                    show.updateCue(cue.id) { $0.hotkey = key.isEmpty ? nil : String(key) }
                }))
                .textFieldStyle(.roundedBorder).frame(width: 44).multilineTextAlignment(.center)
            }
            if cue.kind == .wait { seconds(loc.t("show.duration"), bind(\.duration)) }
        }
    }

    @ViewBuilder private var actionSection: some View {
        switch cue.kind {
        case .audio: audioSection
        case .fade: fadeSection
        case .group: groupSection
        case .network: networkSection
        case .wait:
            section(loc.t("cue.kind.wait"), icon: "hourglass") { seconds(loc.t("show.duration"), bind(\.duration)) }
        case .memo: EmptyView()
        default: controlSection
        }
    }

    // MARK: Audio

    private var path: String? { show.resolvedPath(cue) }
    private var info: (duration: Double, channels: Int)? { path.flatMap { show.clipInfo[$0] } }

    @ViewBuilder private var audioSection: some View {
        section(loc.t("show.file"), icon: "music.note") {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(cue.audio.map { ($0.file as NSString).lastPathComponent } ?? "—")
                        .font(.system(size: 12, weight: .medium)).lineLimit(2)
                    if let info {
                        Text("\(showTime(info.duration)) · \(info.channels) ch").font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
                    } else if let p = path, show.missingFiles.contains(p) {
                        Text(loc.t("show.fileMissing")).font(.system(size: 11)).foregroundStyle(Theme.statusWarning)
                        Text(p).font(.system(size: 10)).foregroundStyle(Theme.textMuted).lineLimit(3).textSelection(.enabled)
                    } else if let p = path, let why = show.unreadableFiles[p] {
                        Text(loc.t("show.fileUnreadable") + ": " + why).font(.system(size: 11)).foregroundStyle(Theme.statusWarning)
                            .lineLimit(4).textSelection(.enabled)
                    } else if show.loadingFiles > 0 {
                        Text(loc.t("error.show.notReady")).font(.system(size: 11)).foregroundStyle(Theme.dataBlue)
                    }
                }
                Spacer()
                Button(loc.t("show.chooseFile")) { show.chooseFile(for: cue.id) }.buttonStyle(SSMTButtonStyle())
            }
            VStack(alignment: .leading, spacing: 4) {
                caption(loc.t("show.rate"))
                TextField("", value: audio(\.rate, 1), format: .number.precision(.fractionLength(0...3)))
                    .textFieldStyle(.roundedBorder).frame(width: 70)
            }
        }
        section(loc.t("show.wave.title"), icon: "waveform") {
            WaveformEditor(cue: cue, compact: true)
        }
    }

    @ViewBuilder private var outputsSection: some View {
        section(loc.t("show.level"), icon: "speaker.wave.2") {
            level(loc.t("show.level"), audio(\.level, 0))
        }
        section(loc.t("show.routing"), icon: "point.3.connected.trianglepath.dotted") { routingGrid }
    }

    /// One-shot pad: press behaviour and F-key.
    @ViewBuilder private var padSection: some View {
        section(loc.t("show.tab.pad"), icon: "square.grid.3x3") {
            VStack(alignment: .leading, spacing: 4) {
                caption(loc.t("show.pad.mode"))
                Picker("", selection: bind(\.padMode)) {
                    ForEach(PadMode.allCases, id: \.self) { Text(loc.t("padmode.\($0.rawValue)")).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
            HStack {
                caption(loc.t("show.pad.key"))
                Spacer()
                Picker("", selection: Binding(get: { cue.hotkey ?? "" }, set: { v in
                    show.updateCue(cue.id) { $0.hotkey = v.isEmpty ? nil : v }
                })) {
                    Text("—").tag("")
                    ForEach(ShowDocument.functionKeys, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 90)
            }
        }
    }

    /// Crosspoints: file channels (rows) × show outputs (columns); click to connect.
    private var routingGrid: some View {
        let channels = max(1, info?.channels ?? 2)
        let outs = show.doc.outputs
        return ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text("").frame(width: 28)
                    ForEach(Array(outs.enumerated()), id: \.offset) { _, o in
                        Text(o.name).font(.system(size: 9)).foregroundStyle(Theme.textSecondary).frame(width: 24).lineLimit(1)
                    }
                }
                ForEach(0..<channels, id: \.self) { c in
                    HStack(spacing: 4) {
                        Text(channels == 2 ? (c == 0 ? "L" : "R") : "\(c + 1)")
                            .font(Theme.mono(11)).foregroundStyle(Theme.textSecondary).frame(width: 28)
                        ForEach(0..<outs.count, id: \.self) { o in
                            let on = (cue.audio?.crosspoint(channel: c, output: o, fileChannels: channels) ?? showSilenceDB) > showSilenceDB
                            Button { toggle(channel: c, output: o, channels: channels, outputs: outs.count) } label: {
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(on ? Theme.accent : Color.white.opacity(0.07))
                                    .frame(width: 24, height: 22)
                                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.white.opacity(0.1)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func toggle(channel c: Int, output o: Int, channels: Int, outputs: Int) {
        show.updateCue(cue.id) { cue in
            guard var a = cue.audio else { return }
            if a.routing.count < channels {
                // Materialise the default routing before the first manual change.
                a.routing = (0..<channels).map { ch in (0..<outputs).map { a.crosspoint(channel: ch, output: $0, fileChannels: channels) } }
            }
            while a.routing[c].count < outputs { a.routing[c].append(showSilenceDB) }
            a.routing[c][o] = a.routing[c][o] > showSilenceDB ? showSilenceDB : 0
            cue.audio = a
        }
    }

    // MARK: Fade

    @ViewBuilder private var fadeSection: some View {
        section(loc.t("cue.kind.fade"), icon: cue.kind.icon) {
            targetPicker(loc.t("show.target"), \.target)
            HStack(spacing: 8) {
                seconds(loc.t("show.duration"), fade(\.duration, 3))
                VStack(alignment: .leading, spacing: 4) {
                    caption(loc.t("show.curve"))
                    Picker("", selection: fade(\.curve, .sCurve)) {
                        ForEach(FadeCurve.allCases, id: \.self) { Text(loc.t("curve.\($0.rawValue)")).tag($0) }
                    }
                    .labelsHidden()
                }
            }
            Toggle(loc.t("show.fade.changeLevel"), isOn: Binding(get: { cue.fade?.level != nil }, set: { v in
                show.updateCue(cue.id) { $0.fade?.level = v ? showSilenceDB : nil }
            }))
            if cue.fade?.level != nil {
                // Absolute: "to −∞ / to −10 dB"; relative (QLab): "by −6 dB" from where the target is.
                Picker("", selection: Binding(get: { cue.fade?.relative ?? false }, set: { v in
                    show.updateCue(cue.id) { $0.fade?.relative = v; $0.fade?.level = v ? -6 : showSilenceDB }
                })) {
                    Text(loc.t("show.fade.absolute")).tag(false)
                    Text(loc.t("show.fade.relative")).tag(true)
                }
                .pickerStyle(.segmented).labelsHidden()
                level(loc.t(cue.fade?.relative == true ? "show.fade.by" : "show.fade.to"),
                      Binding(get: { cue.fade?.level ?? showSilenceDB },
                              set: { v in show.updateCue(cue.id) { $0.fade?.level = v } }))
            }
            Toggle(loc.t("show.fade.stop"), isOn: fade(\.stopWhenDone, true))
        }
    }

    // MARK: Network (OSC)

    @ViewBuilder private var networkSection: some View {
        let p = cue.osc ?? OSCCueParams()
        let device = show.doc.devices.first { $0.id == p.device }
        section(loc.t("cue.kind.network"), icon: cue.kind.icon) {
            if show.doc.devices.isEmpty {
                Text(loc.t("osc.cue.noDevices")).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button { show.showOSC = true } label: { Label(loc.t("osc.add"), systemImage: "plus") }
                    .buttonStyle(SSMTButtonStyle(kind: .primary))
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    caption(loc.t("osc.cue.device"))
                    Picker("", selection: Binding(get: { p.device ?? UUID() }, set: { v in
                        show.updateCue(cue.id) { $0.osc?.device = v; $0.osc?.preset = nil }
                    })) {
                        ForEach(show.doc.devices) { d in Text("\(d.name) · \(d.host)").tag(d.id) }
                    }
                    .labelsHidden()
                }
                if let device {
                    let presets = OSCPreset.presets(for: device.kind)
                    VStack(alignment: .leading, spacing: 4) {
                        caption(loc.t("osc.cue.action"))
                        Picker("", selection: Binding(get: { p.preset ?? "" }, set: { v in apply(preset: v, device: device) })) {
                            ForEach(presets, id: \.id) { Text(loc.t("osc.preset.\($0.id)")).tag($0.id) }
                            Text(loc.t("osc.cue.custom")).tag("")
                        }
                        .labelsHidden()
                    }
                    if let preset = presets.first(where: { $0.id == p.preset }) {
                        ForEach(preset.fields, id: \.key) { f in
                            presetField(f, preset: preset, device: device, value: p.values[f.key] ?? f.defaultValue)
                        }
                    } else {
                        rawFields(p)
                    }
                }
                Text("→ " + p.message.display + (device.map { "   ·   \($0.host):\($0.port)" } ?? ""))
                    .font(Theme.mono(11)).foregroundStyle(Theme.dataBlue).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button { show.sendNow(cue) } label: { Label(loc.t("osc.cue.sendNow"), systemImage: "paperplane") }
                        .buttonStyle(SSMTButtonStyle())
                        .disabled(device == nil)
                    Spacer()
                    Button(loc.t("osc.cue.devices")) { show.showOSC = true }.buttonStyle(.borderless).font(.system(size: 11))
                }
                if let device {
                    Text(loc.t("osc.find.\(device.kind.rawValue)")).font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func apply(preset id: String, device: OSCDevice) {
        show.updateCue(cue.id) { c in
            guard var o = c.osc else { return }
            o.preset = id.isEmpty ? nil : id
            if let preset = OSCPreset.presets(for: device.kind).first(where: { $0.id == id }) {
                let m = preset.message(o.values, device: device)
                o.address = m.address
                o.arguments = m.arguments
                if c.name.isEmpty || c.name.hasPrefix("/") { c.name = "" }
            }
            c.osc = o
        }
    }

    private func presetField(_ f: OSCPresetField, preset: OSCPreset, device: OSCDevice, value: String) -> some View {
        let set = { (v: String) in
            show.updateCue(cue.id) { c in
                guard var o = c.osc else { return }
                o.values[f.key] = v
                let m = preset.message(o.values, device: device)
                o.address = m.address
                o.arguments = m.arguments
                c.osc = o
            }
        }
        return VStack(alignment: .leading, spacing: 4) {
            caption(loc.t("osc.field.\(f.key)"))
            switch f.kind {
            case .level:
                HStack {
                    Slider(value: Binding(get: { Double(value) ?? 0 }, set: { set(String(format: "%.2f", $0)) }), in: 0...1)
                    Text("\(Int(((Double(value) ?? 0) * 100).rounded())) %").font(Theme.mono(11)).frame(width: 44)
                }
            case .text:
                TextField("", text: Binding(get: { value }, set: { set($0) })).textFieldStyle(.roundedBorder)
            case .number, .twoDigits:
                TextField("", value: Binding(get: { Int(value) ?? 1 }, set: { set(String(max(0, $0))) }), format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder).frame(width: 90)
            }
        }
    }

    /// Free address and arguments ("1", "0.5", "text") for anything the templates do not cover.
    private func rawFields(_ p: OSCCueParams) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            caption(loc.t("osc.cue.address"))
            TextField("/composition/columns/1/connect", text: Binding(get: { p.address }, set: { v in
                show.updateCue(cue.id) { $0.osc?.address = v.hasPrefix("/") ? v : "/" + v }
            }))
            .textFieldStyle(.roundedBorder)
            .font(Theme.mono(12))
            caption(loc.t("osc.cue.args"))
            TextField("1", text: Binding(get: { p.arguments.map(\.display).joined(separator: " ") }, set: { v in
                show.updateCue(cue.id) { $0.osc?.arguments = Self.parseArguments(v) }
            }))
            .textFieldStyle(.roundedBorder)
            .font(Theme.mono(12))
            Text(loc.t("osc.cue.args.hint")).font(.system(size: 11)).foregroundStyle(Theme.textMuted)
        }
    }

    /// "1 0.5 \"Go+ Sequence 1\" true" → int, float, string, bool.
    static func parseArguments(_ text: String) -> [OSCArgument] {
        var out: [OSCArgument] = []
        var rest = Substring(text)
        while true {
            rest = rest.drop { $0 == " " }
            guard let c = rest.first else { break }
            var token: String
            if c == "\"" {
                let body = rest.dropFirst()
                let end = body.firstIndex(of: "\"") ?? body.endIndex
                out.append(.string(String(body[..<end])))
                rest = end < body.endIndex ? body[body.index(after: end)...] : ""
                continue
            }
            let end = rest.firstIndex(of: " ") ?? rest.endIndex
            token = String(rest[..<end])
            rest = rest[end...]
            if token == "true" || token == "false" { out.append(.bool(token == "true")) }
            else if let i = Int32(token) { out.append(.int(i)) }
            else if let f = Float(token) { out.append(.float(f)) }
            else { out.append(.string(token)) }
        }
        return out
    }

    // MARK: Group

    @ViewBuilder private var groupSection: some View {
        section(loc.t("cue.kind.group"), icon: cue.kind.icon) {
            Picker("", selection: bind(\.groupMode)) {
                ForEach(GroupMode.allCases, id: \.self) { Text(loc.t("group.mode.\($0.rawValue)")).tag($0) }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            if cue.groupMode == .playlist {
                Toggle(loc.t("show.playlist.loop"), isOn: bind(\.loopPlaylist))
                Toggle(loc.t("show.playlist.shuffle"), isOn: bind(\.shuffle))
                seconds(loc.t("show.playlist.crossfade"), bind(\.crossfade))
            }
            Text(String(format: loc.t("show.group.count"), cue.children.count))
                .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
        }
    }

    // MARK: Control cues

    @ViewBuilder private var controlSection: some View {
        section(loc.t("cue.kind.\(cue.kind.rawValue)"), icon: cue.kind.icon) {
            targetPicker(loc.t("show.target"), \.target, allowsAll: cue.kind == .stop)
            switch cue.kind {
            case .stop: seconds(loc.t("show.stopFade"), bind(\.stopFade))
            case .target: targetPicker(loc.t("show.newTarget"), \.newTarget)
            case .devamp: Toggle(loc.t("show.devamp.next"), isOn: bind(\.devampStartsNext))
            default: EmptyView()
            }
            Text(loc.t("cue.help.\(cue.kind.rawValue)")).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func targetPicker(_ title: String, _ key: WritableKeyPath<Cue, UUID?>, allowsAll: Bool = false) -> some View {
        let candidates = key == \Cue.newTarget ? show.doc.allCues.filter { $0.id != cue.id }
            : show.doc.targetCandidates(for: cue.kind, excluding: cue.id)
        let current = show.doc.cue(cue[keyPath: key])
        return VStack(alignment: .leading, spacing: 4) {
            caption(title)
            Menu {
                if allowsAll { Button(loc.t("show.target.all")) { show.updateCue(cue.id) { $0[keyPath: key] = nil } } }
                ForEach(candidates) { c in
                    Button(label(c)) { show.updateCue(cue.id) { $0[keyPath: key] = c.id } }
                }
            } label: {
                Text(current.map(label) ?? (allowsAll ? loc.t("show.target.all") : loc.t("show.noTarget")))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func label(_ c: Cue) -> String {
        [c.number, c.name.isEmpty ? loc.t("cue.kind.\(c.kind.rawValue)") : c.name].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    // MARK: Building blocks

    private func section<C: View>(_ title: String, icon: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 12)).foregroundStyle(Theme.accent)
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            content()
        }
        .font(.system(size: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(padding: 14)
    }

    private func caption(_ t: String) -> some View {
        Text(t).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            caption(title)
            TextField("", text: text).textFieldStyle(.roundedBorder)
        }
    }

    private func seconds(_ title: String, _ value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            caption(title + ", " + loc.t("show.sec"))
            TextField("", value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = max(0, $0) }),
                      format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.roundedBorder)
        }
    }

    private func level(_ title: String, _ value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                caption(title)
                Spacer()
                Text(value.wrappedValue <= showSilenceDB ? "−∞ dB" : String(format: "%+.1f dB", value.wrappedValue))
                    .font(Theme.mono(11))
            }
            Slider(value: Binding(get: { max(-60, value.wrappedValue) },
                                  set: { v in value.wrappedValue = v <= -60 ? showSilenceDB : (v * 2).rounded() / 2 }),
                   in: -60...12)
        }
    }

    private func bind<T>(_ key: WritableKeyPath<Cue, T>) -> Binding<T> {
        let id = cue.id
        let fallback = cue[keyPath: key]
        return Binding(get: { show.doc.cue(id)?[keyPath: key] ?? fallback },
                       set: { v in show.updateCue(id) { $0[keyPath: key] = v } })
    }

    private func audio<T>(_ key: WritableKeyPath<AudioCueParams, T>, _ fallback: T) -> Binding<T> {
        let id = cue.id
        return Binding(get: { show.doc.cue(id)?.audio?[keyPath: key] ?? fallback },
                       set: { v in show.updateCue(id) { $0.audio?[keyPath: key] = v } })
    }

    private func fade<T>(_ key: WritableKeyPath<FadeCueParams, T>, _ fallback: T) -> Binding<T> {
        let id = cue.id
        return Binding(get: { show.doc.cue(id)?.fade?[keyPath: key] ?? fallback },
                       set: { v in show.updateCue(id) { $0.fade?[keyPath: key] = v } })
    }
}
