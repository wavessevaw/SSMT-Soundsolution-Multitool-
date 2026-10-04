import SSMTCore
import SwiftUI

extension CueKind {
    var icon: String {
        switch self {
        case .audio: return "waveform"
        case .fade: return "chart.line.downtrend.xyaxis"
        case .group: return "square.stack.3d.up"
        case .wait: return "hourglass"
        case .memo: return "note.text"
        case .start: return "play"
        case .stop: return "stop"
        case .pause: return "pause"
        case .load: return "tray.and.arrow.down"
        case .reset: return "arrow.counterclockwise"
        case .goTo: return "arrow.turn.down.right"
        case .target: return "scope"
        case .arm: return "checkmark.shield"
        case .disarm: return "xmark.shield"
        case .devamp: return "repeat.1"
        case .network: return "antenna.radiowaves.left.and.right"
        }
    }

    /// Kinds offered in the "add" menu, grouped.
    static let mediaKinds: [CueKind] = [.audio, .fade, .group, .wait, .memo, .network]
    static let controlKinds: [CueKind] = [.start, .stop, .pause, .load, .reset, .goTo, .target, .arm, .disarm, .devamp]
}

/// Colour tags of cues.
enum CueColor: String, CaseIterable {
    case none = "", red, orange, yellow, green, blue, purple
    var color: Color {
        switch self {
        case .none: return .clear
        case .red: return Color(hex: 0xFF5F57)
        case .orange: return Color(hex: 0xFF9F0A)
        case .yellow: return Color(hex: 0xFFD60A)
        case .green: return Color(hex: 0x30D158)
        case .blue: return Color(hex: 0x64D2FF)
        case .purple: return Color(hex: 0xBF5AF2)
        }
    }
}

/// "1:05.3" style time.
func showTime(_ s: Double?) -> String {
    guard let s, s.isFinite else { return "∞" }
    let v = max(0, s)
    let m = Int(v) / 60
    let rest = v - Double(m * 60)
    return m > 0 ? String(format: "%d:%04.1f", m, rest) : String(format: "%.1f", rest)
}

/// Function #3: Qtrl, the show control center, laid out as in QLab:
/// GO and "standing by" on top, the cue toolbar (editing), the cue list with a sidebar (lists, one-shot, active),
/// the inspector (and optionally the timeline) at the bottom, and a status bar with Edit / Show.
struct ShowWorkspace: View {
    @EnvironmentObject var show: ShowStore
    @EnvironmentObject var loc: Localizer
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        VStack(spacing: 8) {
            QtrlGoBar()
            if let e = show.lastError {
                ErrorBanner(text: e.hasPrefix("error.") ? loc.t(e) : e) { show.lastError = nil }
            }
            if !show.showMode { QtrlToolbar() }
            HStack(alignment: .top, spacing: 8) {
                VStack(spacing: 8) {
                    CueListView()
                        .frame(maxHeight: .infinity)
                    if show.showTimeline {
                        ShowTimelineView().frame(height: 220)
                    }
                    if !show.showMode && show.showInspector {
                        CueInspector().frame(height: 300)
                    }
                }
                .frame(maxWidth: .infinity)
                if show.showSidebar {
                    QtrlSidebar().frame(width: 300)
                }
            }
            .frame(maxHeight: .infinity)
            QtrlStatusBar()
        }
        .onAppear {
            show.undo = undoManager
            show.localizer = loc
            show.isActive = true
            show.installKeyMonitor()
        }
        .onDisappear { show.isActive = false }
        .sheet(isPresented: $show.showQLabImport) {
            QLabImportView()
                .environmentObject(show)
                .environmentObject(loc)
                .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $show.showOSC) {
            OSCDevicesView()
                .environmentObject(show)
                .environmentObject(loc)
                .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $show.showSettings) {
            ShowSettingsView()
                .environmentObject(show)
                .environmentObject(loc)
                .preferredColorScheme(.dark)
        }
    }
}

// MARK: - GO and standing by

/// The big GO, the cue standing by with its notes, Pause all and Stop all — the same in Edit and Show.
struct QtrlGoBar: View {
    @EnvironmentObject var show: ShowStore
    @EnvironmentObject var loc: Localizer

    private var playhead: UUID? {
        show.snapshot == .empty ? show.currentList?.cues.first?.id : show.snapshot.playhead
    }

    var body: some View {
        let cue = show.doc.cue(playhead)
        HStack(spacing: 14) {
            goButton(ready: cue != nil)
            VStack(alignment: .leading, spacing: 2) {
                Text(loc.t("show.next").uppercased()).font(Theme.label(10)).tracking(1.2).foregroundStyle(Theme.textSecondary)
                if let cue {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(cue.number).font(Theme.numeral(30)).foregroundStyle(Theme.accent)
                        Text(cue.name.isEmpty ? loc.t("cue.kind.\(cue.kind.rawValue)") : cue.name)
                            .font(.system(size: 22, weight: .semibold)).lineLimit(1)
                    }
                } else {
                    Text(loc.t("show.endOfList")).font(.system(size: 18, weight: .medium)).foregroundStyle(Theme.textMuted)
                }
            }
            .frame(minWidth: 240, alignment: .leading)
            Rectangle().fill(Theme.hairline).frame(width: 1, height: 56)
            Text(cue?.notes ?? "")
                .font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.signalYellow)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 6) {
                Button { show.anyPaused ? show.resumeAll() : show.pauseAll() } label: {
                    Label(loc.t(show.anyPaused ? "show.resumeAll" : "show.pauseAll"),
                          systemImage: show.anyPaused ? "play.fill" : "pause.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(SSMTButtonStyle(active: show.anyPaused))
                .disabled(show.snapshot.running.isEmpty)
                Button { show.panic() } label: {
                    Label(loc.t("show.panic"), systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(SSMTButtonStyle(kind: .danger))
                .help(loc.t("show.panic.help"))
            }
            .frame(width: 170)
        }
        .glassCard(padding: 12)
    }

    private func goButton(ready: Bool) -> some View {
        Button { show.go() } label: {
            VStack(spacing: 0) {
                Text("GO").font(.system(size: 34, weight: .heavy, design: .rounded)).tracking(4)
                Text(loc.t("show.go.hint")).font(.system(size: 10, weight: .medium)).opacity(0.65)
            }
            .foregroundStyle(ready ? Color.black : Theme.textSecondary)
            .frame(width: 170, height: 76)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(ready ? AnyShapeStyle(LinearGradient(colors: [Theme.accent, Theme.accentHot], startPoint: .top, endPoint: .bottom))
                                : AnyShapeStyle(Color.white.opacity(0.08)))
            )
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.25)))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!ready)
        .help(loc.t("show.go.help"))
    }
}

// MARK: - Toolbar (Edit)

/// Every cue type as an icon (as QLab's toolbar), then the selection tools.
struct QtrlToolbar: View {
    @EnvironmentObject var show: ShowStore
    @EnvironmentObject var loc: Localizer

    var body: some View {
        HStack(spacing: 6) {
            Button { show.chooseAudioFiles() } label: { Label(loc.t("cue.kind.audio"), systemImage: "plus").fixedSize() }
                .buttonStyle(SSMTButtonStyle(kind: .primary))
                .help(loc.t("show.addAudio.help"))
            ForEach(CueKind.mediaKinds.filter { $0 != .audio } + CueKind.controlKinds, id: \.self) { k in
                tool(k.icon, k == .group ? loc.t("show.group.help") : loc.t("cue.kind.\(k.rawValue)")) { show.add(k) }
            }
            Spacer(minLength: 8)
            let none = show.selection.isEmpty
            tool("plus.square.on.square", loc.t("action.duplicate")) { show.duplicateSelection() }.disabled(none)
            tool("arrow.up", loc.t("show.up")) { show.moveSelection(by: -1) }.disabled(none)
            tool("arrow.down", loc.t("show.down")) { show.moveSelection(by: 1) }.disabled(none)
            tool("square.stack.3d.up.slash", loc.t("show.ungroup")) { show.ungroupSelection() }
                .disabled(!show.selection.contains { show.doc.cue($0)?.kind == .group })
            tool("list.number", loc.t("show.renumber")) { show.renumberSelection() }
            tool("trash", loc.t("action.delete")) { show.deleteSelection() }.disabled(none)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(GlassBackground(radius: 12))
    }

    private func tool(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).frame(width: 18) }
            .buttonStyle(ToolButtonStyle())
            .help(help)
    }
}

// MARK: - Sidebar

enum QtrlSidebarTab: String, CaseIterable { case lists, pads, active }

/// Cue lists, one-shot pads and what is playing, as tabs (QLab's "Lists, Carts & Active Cues").
struct QtrlSidebar: View {
    @EnvironmentObject var show: ShowStore
    @EnvironmentObject var loc: Localizer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $show.sidebarTab) {
                Text(loc.t("show.lists")).tag(QtrlSidebarTab.lists)
                Text(loc.t("show.oneShot")).tag(QtrlSidebarTab.pads)
                Text(String(format: loc.t("show.sidebar.active"), show.snapshot.running.count)).tag(QtrlSidebarTab.active)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            switch show.sidebarTab {
            case .lists: lists
            case .pads: PadGridView(columns: 2, embedded: true)
            case .active:
                RunningCuesPanel(embedded: true).frame(maxHeight: .infinity, alignment: .top)
                OutputMeters(embedded: true)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .glassCard(padding: 12)
    }

    private var lists: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(show.doc.cueLists) { l in
                let on = l.id == show.listID
                Button { show.selectList(l.id) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "list.bullet").font(.system(size: 11)).foregroundStyle(on ? Theme.accent : Theme.textMuted)
                        Text(l.name).font(.system(size: 13, weight: on ? .semibold : .regular)).lineLimit(1)
                        Spacer()
                        Text("\(l.cues.count)").font(Theme.mono(11)).foregroundStyle(Theme.textMuted)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(on ? Theme.accent.opacity(0.16) : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if !show.showMode {
                        Button(loc.t("show.list.rename")) { rename(l.id) }
                        if show.doc.cueLists.count > 1 {
                            Button(loc.t("action.delete"), role: .destructive) { show.edit { $0.lists.removeAll { $0.id == l.id } } }
                        }
                    }
                }
            }
            if !show.showMode {
                Button { show.addList() } label: { Label(loc.t("show.list.add"), systemImage: "plus").font(.system(size: 12)) }
                    .buttonStyle(.borderless)
                    .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
    }

    private func rename(_ id: UUID) {
        let alert = NSAlert()
        alert.messageText = loc.t("show.list.rename")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = show.doc.lists.first { $0.id == id }?.name ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: loc.t("action.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue
        show.edit { d in if let i = d.lists.firstIndex(where: { $0.id == id }) { d.lists[i].name = name } }
    }
}

// MARK: - Status bar

/// Edit / Show, show name, output and file status, pre-show check, panel toggles, OSC and settings.
struct QtrlStatusBar: View {
    @EnvironmentObject var show: ShowStore
    @EnvironmentObject var loc: Localizer
    @State private var showIssues = false
    @State private var showKeys = false

    var body: some View {
        HStack(spacing: 10) {
            Picker("", selection: $show.showMode) {
                Label(loc.t("show.mode.edit"), systemImage: "pencil").tag(false)
                Label(loc.t("show.mode.show"), systemImage: "lock.fill").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 190)
            .help(loc.t("show.mode.help"))
            TextField(loc.t("show.name.placeholder"), text: Binding(get: { show.doc.name }, set: { v in show.edit { $0.name = v } }))
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .frame(minWidth: 100, maxWidth: 220)
                .disabled(show.showMode)
            Spacer(minLength: 8)
            statusChips
            Button { showIssues = true } label: { Image(systemName: "checklist") }
                .buttonStyle(ToolButtonStyle())
                .help(loc.t("show.check"))
                .popover(isPresented: $showIssues, arrowEdge: .top) { ShowIssuesView().environmentObject(show).environmentObject(loc) }
            Rectangle().fill(Theme.hairline).frame(width: 1, height: 20)
            toggle("timeline.selection", loc.t("show.timeline"), on: show.showTimeline) { show.showTimeline.toggle() }
            if !show.showMode {
                toggle("rectangle.bottomthird.inset.filled", loc.t("show.view.inspector"), on: show.showInspector) { show.showInspector.toggle() }
            }
            toggle("sidebar.right", loc.t("show.view.sidebar"), on: show.showSidebar) { show.showSidebar.toggle() }
            Rectangle().fill(Theme.hairline).frame(width: 1, height: 20)
            Button { showKeys = true } label: { Image(systemName: "keyboard") }
                .buttonStyle(ToolButtonStyle())
                .help(loc.t("show.keys.title"))
                .popover(isPresented: $showKeys, arrowEdge: .top) { QtrlShortcutsView().environmentObject(loc) }
            Button { show.showOSC = true } label: { Image(systemName: "antenna.radiowaves.left.and.right") }
                .buttonStyle(ToolButtonStyle())
                .help(loc.t("osc.title"))
            Button { show.showSettings = true } label: { Image(systemName: "gearshape") }
                .buttonStyle(ToolButtonStyle())
                .help(loc.t("show.settings"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(GlassBackground(radius: 12))
    }

    private func toggle(_ icon: String, _ help: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).foregroundStyle(on ? Theme.accent : Theme.textSecondary) }
            .buttonStyle(ToolButtonStyle())
            .help(help)
    }

    private var statusChips: some View {
        HStack(spacing: 8) {
            chip(icon: show.outputError == nil ? "hifispeaker" : "exclamationmark.triangle.fill",
                 text: show.outputError == nil ? "\(show.outputName) · \(Int(show.sampleRate / 1000)) kHz" : loc.t("show.output.error"),
                 tint: show.outputError == nil ? Theme.textSecondary : Theme.statusError)
                .help(show.outputError ?? "")
            if show.memoryBytes > 0 {
                chip(icon: "memorychip", text: "\(show.memoryBytes / 1_048_576) MB", tint: Theme.textSecondary)
                    .help(loc.t("show.memory.help"))
            }
            if !show.missingFiles.isEmpty {
                Button { show.relinkMissing() } label: {
                    chip(icon: "questionmark.folder", text: String(format: loc.t("show.missing"), show.missingFiles.count), tint: Theme.statusWarning)
                }
                .buttonStyle(.plain)
                .help(loc.t("show.relink.help"))
            }
        }
    }

    private func chip(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10))
            Text(text).font(.system(size: 11)).lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(Capsule().fill(Color.white.opacity(0.06)))
    }
}

/// Cues waiting or playing, with progress and per-cue pause / stop.
struct RunningCuesPanel: View {
    @EnvironmentObject var show: ShowStore
    @EnvironmentObject var loc: Localizer
    var embedded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !embedded {
                HStack {
                    Text(loc.t("show.running").uppercased()).font(Theme.label(11)).tracking(1.2).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text("\(show.snapshot.running.count)").font(Theme.mono(11)).foregroundStyle(Theme.textMuted)
                }
            }
            if show.snapshot.running.isEmpty {
                Text(loc.t("show.running.none")).font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
            }
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(show.snapshot.running) { r in tile(r) }
                }
            }
            .frame(maxHeight: embedded ? .infinity : 320)
        }
        .glassCard(padding: embedded ? 0 : 14, plain: embedded)
    }

    private func tile(_ r: RunningCue) -> some View {
        let cue = show.doc.cue(r.id)
        let tint: Color = r.paused ? Theme.signalYellow : (r.phase == .preWait ? Theme.dataBlue : (r.phase == .stopping ? Theme.statusError : Theme.accent))
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: cue?.kind.icon ?? "questionmark").font(.system(size: 11)).foregroundStyle(tint).frame(width: 14)
                Text([cue?.number ?? "", cue?.name ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Spacer(minLength: 4)
                if let it = r.iteration {
                    Text("×\(it)").font(Theme.mono(10)).foregroundStyle(Theme.textSecondary)
                }
                Text(r.phase == .preWait ? "▸ " + showTime(r.remaining) : "−" + showTime(r.remaining))
                    .font(Theme.mono(11)).foregroundStyle(tint)
                Button { show.togglePause(r.id) } label: { Image(systemName: r.paused ? "play.fill" : "pause.fill") }
                    .buttonStyle(.borderless).font(.system(size: 10))
                Button { show.stop(r.id) } label: { Image(systemName: "stop.fill") }
                    .buttonStyle(.borderless).font(.system(size: 10))
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(tint).frame(width: g.size.width * (r.progress ?? 1))
                        .opacity(r.progress == nil ? 0.35 : 1)
                }
            }
            .frame(height: 4)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.05)))
    }
}

/// Peak meters of the show outputs.
struct OutputMeters: View {
    @EnvironmentObject var show: ShowStore
    @EnvironmentObject var loc: Localizer
    var embedded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(loc.t("show.outputs").uppercased()).font(Theme.label(11)).tracking(1.2).foregroundStyle(Theme.textSecondary)
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(Array(show.doc.outputs.prefix(16).enumerated()), id: \.offset) { i, o in
                    let peak = i < show.meters.count ? Double(show.meters[i]) : 0
                    let db = peak > 0 ? 20 * log10(peak) : -100
                    let fill = max(0, min(1, (db + 60) / 60))
                    VStack(spacing: 3) {
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.07))
                            RoundedRectangle(cornerRadius: 2)
                                .fill(db > -3 ? Theme.statusError : (db > -12 ? Theme.signalYellow : Theme.accent))
                                .frame(height: 54 * fill)
                        }
                        .frame(height: 54)
                        Text(o.name).font(.system(size: 8)).foregroundStyle(Theme.textMuted).lineLimit(1)
                    }
                    .frame(maxWidth: 22)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(padding: embedded ? 0 : 14, plain: embedded)
    }
}

/// The keyboard shortcuts (QLab's), for the status bar popover.
struct QtrlShortcutsView: View {
    @EnvironmentObject var loc: Localizer

    private let rows: [(String, String)] = [
        ("Space", "show.keys.go"), ("Esc", "show.keys.panic"), ("[  /  ]", "show.keys.pauseResumeAll"),
        ("P", "show.keys.pauseSelected"), ("S", "show.keys.stopSelected"), ("L", "show.keys.load"), ("V", "show.keys.preview"),
        ("↑  /  ↓", "show.keys.cursor"), ("⇧⌘↑  /  ⇧⌘↓", "show.keys.playhead"), ("⌘J", "show.keys.jump"),
        ("⌘]  /  ⌘[", "show.keys.mode"), ("⌘I  /  ⌘L", "show.keys.panels"),
        ("⌘1 · ⌘0 · ⌘7 · ⌘8", "show.keys.newCue"), ("N · Q · E · D · W", "show.keys.fields"), ("C", "show.keys.continue"),
        ("T", "show.keys.target"), ("⌘R", "show.keys.renumber"), ("⌘D", "show.keys.duplicate"),
        ("⌘C · ⌘X · ⌘V · ⌘A", "show.keys.clipboard"), ("⌫", "show.keys.delete"), ("F1…F12", "show.keys.pads"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(loc.t("show.keys.title")).font(Theme.heading(15))
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                ForEach(rows, id: \.1) { k, key in
                    GridRow {
                        Text(k).font(Theme.mono(12, weight: .semibold)).foregroundStyle(Theme.accent)
                        Text(loc.t(key)).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            Text(loc.t("show.keys.note")).font(.system(size: 11)).foregroundStyle(Theme.textMuted).frame(maxWidth: 420, alignment: .leading)
        }
        .padding(16)
    }
}

/// Compact square button for the cue toolbar.
struct ToolButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return configuration.label
            .font(.system(size: 13))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(shape.fill(Color.white.opacity(configuration.isPressed ? 0.14 : 0.07)))
            .overlay(shape.strokeBorder(Color.white.opacity(0.1)))
            .contentShape(shape)
    }
}

/// Pre-show check.
struct ShowIssuesView: View {
    @EnvironmentObject var show: ShowStore
    @EnvironmentObject var loc: Localizer

    var body: some View {
        let issues = show.checkShow()
        VStack(alignment: .leading, spacing: 10) {
            Text(loc.t("show.check")).font(Theme.heading(15))
            if issues.isEmpty && show.loadingFiles == 0 && show.unreadableFiles.isEmpty && show.outputError == nil {
                Label(loc.t("show.check.ok"), systemImage: "checkmark.circle.fill").foregroundStyle(Theme.statusGood)
            }
            ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.statusWarning)
                    Text(text(issue)).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                }
                .onTapGesture { if let id = cueID(issue) { show.selection = [id] } }
            }
            if show.outputError != nil {
                Label(loc.t("show.output.error"), systemImage: "hifispeaker.slash").foregroundStyle(Theme.statusError)
            }
            if show.loadingFiles > 0 {
                Label(String(format: loc.t("show.check.loading"), show.loadingFiles), systemImage: "hourglass")
                    .font(.system(size: 12)).foregroundStyle(Theme.statusWarning)
            }
            ForEach(show.unreadableFiles.keys.sorted(), id: \.self) { p in
                Label(String(format: loc.t("show.check.unreadable"), (p as NSString).lastPathComponent), systemImage: "xmark.octagon.fill")
                    .font(.system(size: 12)).foregroundStyle(Theme.statusError)
                    .help(show.unreadableFiles[p] ?? "")
            }
            if show.interruptions > 0 {
                Label(String(format: loc.t("show.check.interruptions"), show.interruptions), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(Theme.statusWarning)
            }
        }
        .padding(16)
        .frame(width: 380, alignment: .leading)
    }

    private func label(_ id: UUID) -> String {
        guard let c = show.doc.cue(id) else { return "?" }
        return [c.number, c.name.isEmpty ? loc.t("cue.kind.\(c.kind.rawValue)") : c.name].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func cueID(_ i: ShowIssue) -> UUID? {
        switch i {
        case let .missingTarget(id), let .missingFile(id), let .emptyGroup(id), let .invalidRegion(id), let .missingDevice(id): return id
        default: return nil
        }
    }

    private func text(_ i: ShowIssue) -> String {
        switch i {
        case let .missingTarget(id): return String(format: loc.t("show.issue.target"), label(id))
        case let .missingFile(id): return String(format: loc.t("show.issue.file"), label(id))
        case let .duplicateNumber(n): return String(format: loc.t("show.issue.number"), n)
        case let .duplicateHotkey(k): return String(format: loc.t("show.issue.hotkey"), k.uppercased())
        case let .emptyGroup(id): return String(format: loc.t("show.issue.emptyGroup"), label(id))
        case let .invalidRegion(id): return String(format: loc.t("show.issue.region"), label(id))
        case let .missingDevice(id): return String(format: loc.t("show.issue.device"), label(id))
        }
    }
}
