import SSMTCore
import SwiftUI

extension ChannelGroup {
    /// Colour stripe of the group in the list and in exports.
    var color: Color {
        switch self {
        case .drums: return Color(hex: 0xFF6B5A)
        case .percussion: return Color(hex: 0xFF9F5A)
        case .bass: return Color(hex: 0xC792EA)
        case .guitar: return Color(hex: 0x5AC8FA)
        case .keys: return Color(hex: 0x7EE0B5)
        case .vocals: return Color(hex: 0xFFD60A)
        case .playback: return Color(hex: 0x8E9CFF)
        case .fx: return Color(hex: 0x9AA0A6)
        case .other: return Color(hex: 0x6E7681)
        }
    }
}

/// Function #2: input list builder (channels, monitor mixes, pull list) with the stage plan below.
struct InputListWorkspace: View {
    @EnvironmentObject var store: InputListStore
    @EnvironmentObject var loc: Localizer
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(loc.t("il.title")).font(.system(size: 30, weight: .bold))
                        Text(store.fileURL?.lastPathComponent ?? loc.t("il.unsaved")).font(.system(size: 13))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    InputListExportMenu()
                }
                if let e = store.lastError {
                    ErrorBanner(text: e) { store.lastError = nil }
                }
                ShowInfoCard()
                Panel(title: loc.t("il.channels"), marking: String(format: loc.t("il.count"), store.doc.channels.count)) {
                    ChannelToolbar()
                    ChannelTable()
                    IssuesView()
                }
                HStack(alignment: .top, spacing: 16) {
                    Panel(title: loc.t("il.mixes"), marking: String(format: loc.t("il.count"), store.doc.mixes.count), tint: Theme.dataSecondary) {
                        MixTable()
                    }
                    Panel(title: loc.t("il.summary"), tint: Theme.signalYellow) {
                        SummaryView()
                    }
                    .frame(width: 340)
                }
                Panel(title: loc.t("il.stage"), tint: Theme.dataBlue) {
                    StagePlanEditor()
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.never)
        .onAppear { store.undo = undoManager }
        .onChange(of: undoManager) { store.undo = $0 }
    }
}

// MARK: - Show info

struct ShowInfoCard: View {
    @EnvironmentObject var store: InputListStore
    @EnvironmentObject var loc: Localizer

    var body: some View {
        Panel(title: loc.t("il.show")) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    field("il.artist", \.artist)
                    field("il.event", \.event)
                    field("il.venue", \.venue)
                }
                GridRow {
                    field("il.engineer", \.engineer)
                    field("il.contact", \.contact)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(loc.t("il.date")).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        HStack {
                            Toggle("", isOn: Binding(get: { store.doc.date != nil },
                                                     set: { on in store.edit { $0.date = on ? ($0.date ?? Date()) : nil } }))
                                .labelsHidden()
                            if let d = store.doc.date {
                                DatePicker("", selection: Binding(get: { d }, set: { v in store.edit { $0.date = v } }),
                                           displayedComponents: .date)
                                    .labelsHidden()
                            }
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(loc.t("il.notes")).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                TextField("", text: Binding(get: { store.doc.notes }, set: { v in store.edit { $0.notes = v } }), axis: .vertical)
                    .lineLimit(2...5)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private func field(_ key: String, _ path: WritableKeyPath<InputListDocument, String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(loc.t(key)).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            TextField("", text: Binding(get: { store.doc[keyPath: path] }, set: { v in store.edit { $0[keyPath: path] = v } }))
                .textFieldStyle(.roundedBorder)
        }
    }
}

// MARK: - Channel toolbar

struct ChannelToolbar: View {
    @EnvironmentObject var store: InputListStore
    @EnvironmentObject var loc: Localizer
    @State private var stageboxPrefix = "SB1-"
    @State private var stageboxStart = 1
    @State private var stageboxOnlyEmpty = true
    @State private var editingStagebox = false

    private var sel: Set<InputChannel.ID> { store.selectedChannels }
    /// Insertion point: after the last selected row.
    private var anchor: InputChannel.ID? { store.doc.channels.last { sel.contains($0.id) }?.id }

    var body: some View {
        HStack(spacing: 8) {
            Button { add() } label: { Label(loc.t("il.addChannel"), systemImage: "plus") }
                .buttonStyle(SSMTButtonStyle(kind: .primary))
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Menu {
                ForEach(ChannelTemplate.all) { t in
                    Button(loc.t("template.\(t.id)") + "  ·  \(t.channels.count)") {
                        var ids: [InputChannel.ID] = []
                        store.edit(loc.t("il.template")) { ids = $0.insert(t, after: anchor) }
                        store.selectedChannels = Set(ids)
                    }
                }
            } label: { Label(loc.t("il.template"), systemImage: "square.stack.3d.up") }
                .menuStyle(.borderlessButton).fixedSize()
            Divider().frame(height: 20)
            tool("arrow.left.and.right", "il.stereo", enabled: sel.count == 1) {
                guard let id = sel.first else { return }
                store.edit(loc.t("il.stereo")) { _ = $0.makeStereo(id) }
            }
            tool("plus.square.on.square", "action.duplicate", enabled: !sel.isEmpty) {
                store.edit(loc.t("action.duplicate")) { $0.duplicate(sel) }
            }
            tool("arrow.up", "il.moveUp", enabled: !sel.isEmpty) { store.edit(loc.t("il.moveUp")) { $0.move(sel, by: -1) } }
            tool("arrow.down", "il.moveDown", enabled: !sel.isEmpty) { store.edit(loc.t("il.moveDown")) { $0.move(sel, by: 1) } }
            tool("trash", "action.delete", enabled: !sel.isEmpty) {
                let ids = sel
                afterEndingEdit {
                    store.selectedChannels = []
                    store.edit(loc.t("action.delete")) { $0.delete(ids) }
                }
            }
            Divider().frame(height: 20)
            tool("list.number", "il.renumber", enabled: !store.doc.channels.isEmpty) {
                store.edit(loc.t("il.renumber")) { $0.renumber() }
            }
            Button { editingStagebox = true } label: { Label(loc.t("il.stagebox.fill"), systemImage: "rectangle.connected.to.line.below") }
                .buttonStyle(SSMTButtonStyle())
                .disabled(store.doc.channels.isEmpty)
                .popover(isPresented: $editingStagebox) { stageboxPopover }
            Spacer()
        }
    }

    private func add() {
        var id: InputChannel.ID?
        store.edit(loc.t("il.addChannel")) { id = $0.addChannel(after: anchor) }
        store.selectedChannels = id.map { [$0] } ?? []
    }

    private func tool(_ icon: String, _ key: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon) }
            .buttonStyle(SSMTButtonStyle())
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.4)
            .help(loc.t(key))
    }

    private var stageboxPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(loc.t("il.stagebox.fill")).font(.system(size: 14, weight: .semibold))
            HStack {
                Text(loc.t("il.stagebox.prefix"))
                TextField("SB1-", text: $stageboxPrefix).textFieldStyle(.roundedBorder).frame(width: 90)
                Stepper(String(format: loc.t("il.stagebox.start"), stageboxStart), value: $stageboxStart, in: 1...256)
            }
            Toggle(loc.t("il.stagebox.onlyEmpty"), isOn: $stageboxOnlyEmpty)
            Button(loc.t("il.stagebox.apply")) {
                store.edit(loc.t("il.stagebox.fill")) { $0.assignStagebox(prefix: stageboxPrefix, start: stageboxStart, onlyEmpty: stageboxOnlyEmpty) }
                editingStagebox = false
            }
            .buttonStyle(SSMTButtonStyle(kind: .primary))
        }
        .font(.system(size: 13))
        .padding(16)
        .frame(width: 360)
    }
}

// MARK: - Channel table

struct ChannelTable: View {
    @EnvironmentObject var store: InputListStore
    @EnvironmentObject var loc: Localizer

    var body: some View {
        let c = columns
        EditableRows(columns: c, rows: store.doc.channels, selection: $store.selectedChannels, visibleRows: 4...24,
                     onDelete: deleteSelected) { ch in
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1.5).fill(ch.group.color).frame(width: 3, height: 16)
                TextField("", value: binding(ch.id, \.number), format: .number)
                    .multilineTextAlignment(.trailing)
                    .font(Theme.mono(13))
            }
            .rowCell(c[0])
            TextField(loc.t("il.col.source"), text: binding(ch.id, \.source)).rowCell(c[1])
            MicField(id: ch.id).rowCell(c[2])
            Picker("", selection: binding(ch.id, \.stand)) {
                ForEach(StandType.allCases, id: \.self) { Text(loc.t("stand.\($0.rawValue)")).tag($0) }
            }
            .labelsHidden()
            .rowCell(c[3])
            Toggle("", isOn: binding(ch.id, \.phantom)).labelsHidden().rowCell(c[4])
            TextField("SB1-01", text: binding(ch.id, \.stagebox)).font(Theme.mono(12)).rowCell(c[5])
            TextField("", text: binding(ch.id, \.insert)).rowCell(c[6])
            Picker("", selection: binding(ch.id, \.group)) {
                ForEach(ChannelGroup.allCases, id: \.self) { g in
                    Text(loc.t("chgroup.\(g.rawValue)")).tag(g)
                }
            }
            .labelsHidden()
            .rowCell(c[7])
            TextField("", text: binding(ch.id, \.notes)).rowCell(c[8])
        }
        .overlay {
            if store.doc.channels.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "list.bullet.rectangle").font(.system(size: 26)).foregroundStyle(Theme.textMuted)
                    Text(loc.t("il.empty")).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private var columns: [RowColumn] {
        [RowColumn(title: "№", width: 54), RowColumn(title: loc.t("il.col.source"), width: nil, minWidth: 120),
         RowColumn(title: loc.t("il.col.mic"), width: 150), RowColumn(title: loc.t("il.col.stand"), width: 150),
         RowColumn(title: "+48V", width: 40), RowColumn(title: loc.t("il.col.stagebox"), width: 84),
         RowColumn(title: loc.t("il.col.insert"), width: 90), RowColumn(title: loc.t("il.col.group"), width: 116),
         RowColumn(title: loc.t("il.col.notes"), width: nil, minWidth: 90)]
    }

    private func deleteSelected() {
        let sel = store.selectedChannels
        afterEndingEdit {
            store.selectedChannels = []
            store.edit(loc.t("action.delete")) { $0.delete(sel) }
        }
    }

    private func binding<T>(_ id: InputChannel.ID, _ key: WritableKeyPath<InputChannel, T>) -> Binding<T> {
        Binding(get: { store.doc.channels.first { $0.id == id }?[keyPath: key] ?? InputChannel(number: 0)[keyPath: key] },
                set: { v in store.edit { d in if let i = d.channels.firstIndex(where: { $0.id == id }) { d.channels[i][keyPath: key] = v } } })
    }
}

/// Mic / DI model with suggestions from the library; picking a condenser or DI turns on +48 V.
struct MicField: View {
    @EnvironmentObject var store: InputListStore
    var id: InputChannel.ID

    private var text: String { store.doc.channels.first { $0.id == id }?.mic ?? "" }

    var body: some View {
        HStack(spacing: 2) {
            TextField("", text: Binding(get: { text }, set: { set($0, fromLibrary: false) }))
            Menu {
                let s = MicLibrary.suggestions(for: text, limit: 12)
                ForEach(s.isEmpty ? MicLibrary.models : s, id: \.self) { m in
                    Button(m) { set(m, fromLibrary: true) }
                }
            } label: { Image(systemName: "chevron.down") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
        }
    }

    private func set(_ model: String, fromLibrary: Bool) {
        store.edit { d in
            guard let i = d.channels.firstIndex(where: { $0.id == id }) else { return }
            d.channels[i].mic = model
            if fromLibrary { d.channels[i].phantom = MicLibrary.needsPhantom(model) }
        }
    }
}

// MARK: - Issues

struct IssuesView: View {
    @EnvironmentObject var store: InputListStore
    @EnvironmentObject var loc: Localizer

    var body: some View {
        let issues = store.doc.issues
        if !issues.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(issues.prefix(6).enumerated()), id: \.offset) { _, issue in
                    Label(text(issue), systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.signalYellow)
                }
                if issues.count > 6 {
                    Text(String(format: loc.t("il.issues.more"), issues.count - 6)).font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                }
            }
        }
    }

    private func text(_ i: InputListIssue) -> String {
        switch i {
        case .duplicateNumber(let n): return String(format: loc.t("il.issue.dupNumber"), n)
        case .duplicateStagebox(let s): return String(format: loc.t("il.issue.dupStagebox"), s)
        case .emptySource(let n): return String(format: loc.t("il.issue.emptySource"), n)
        }
    }
}

// MARK: - Monitor mixes

struct MixTable: View {
    @EnvironmentObject var store: InputListStore
    @EnvironmentObject var loc: Localizer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button { store.edit(loc.t("il.addMix")) { _ = $0.addMix() } } label: { Label(loc.t("il.addMix"), systemImage: "plus") }
                    .buttonStyle(SSMTButtonStyle())
                Button { deleteSelected() } label: { Image(systemName: "trash") }
                    .buttonStyle(SSMTButtonStyle())
                    .disabled(store.selectedMixes.isEmpty)
                    .help(loc.t("action.delete"))
                Button { store.edit(loc.t("il.renumber")) { $0.renumberMixes() } } label: { Image(systemName: "list.number") }
                    .buttonStyle(SSMTButtonStyle())
                    .help(loc.t("il.renumber"))
                Spacer()
            }
            let c = columns
            EditableRows(columns: c, rows: store.doc.mixes, selection: $store.selectedMixes, visibleRows: 3...16,
                         onDelete: deleteSelected) { m in
                TextField("", value: binding(m.id, \.number), format: .number).font(Theme.mono(13)).rowCell(c[0])
                TextField(loc.t("il.mix.name"), text: binding(m.id, \.name)).rowCell(c[1])
                Picker("", selection: binding(m.id, \.type)) {
                    ForEach(MixType.allCases, id: \.self) { Text(loc.t("mixtype.\($0.rawValue)")).tag($0) }
                }
                .labelsHidden()
                .rowCell(c[2])
                Toggle("", isOn: binding(m.id, \.stereo)).labelsHidden().rowCell(c[3])
                TextField("", text: binding(m.id, \.notes)).rowCell(c[4])
            }
        }
    }

    private var columns: [RowColumn] {
        [RowColumn(title: "№", width: 40), RowColumn(title: loc.t("il.mix.name"), width: nil, minWidth: 100),
         RowColumn(title: loc.t("il.mix.type"), width: 110), RowColumn(title: loc.t("il.mix.stereo"), width: 56),
         RowColumn(title: loc.t("il.col.notes"), width: nil, minWidth: 60)]
    }

    private func deleteSelected() {
        let sel = store.selectedMixes
        afterEndingEdit {
            store.selectedMixes = []
            store.edit(loc.t("action.delete")) { $0.deleteMixes(sel) }
        }
    }

    private func binding<T>(_ id: MonitorMix.ID, _ key: WritableKeyPath<MonitorMix, T>) -> Binding<T> {
        Binding(get: { store.doc.mixes.first { $0.id == id }?[keyPath: key] ?? MonitorMix(number: 0)[keyPath: key] },
                set: { v in store.edit { d in if let i = d.mixes.firstIndex(where: { $0.id == id }) { d.mixes[i][keyPath: key] = v } } })
    }
}

// MARK: - Summary

struct SummaryView: View {
    @EnvironmentObject var store: InputListStore
    @EnvironmentObject var loc: Localizer

    var body: some View {
        let s = store.doc.summary
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 18) {
                stat("\(s.channelCount)", loc.t("il.sum.channels"))
                stat("\(s.phantomCount)", "+48V")
                stat("\(s.mixCount)", loc.t("il.sum.mixes"))
            }
            if !s.models.isEmpty {
                Text(loc.t("il.sum.mics")).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                FlowChips(items: s.models.map { "\($0.count)× \($0.name)" })
            }
            if !s.stands.isEmpty {
                Text(loc.t("il.sum.stands")).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                FlowChips(items: s.stands.map { "\($0.count)× " + loc.t("stand.\($0.type.rawValue)") })
            }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(Theme.numeral(26))
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
        }
    }
}

/// Small wrapping chips.
struct FlowChips: View {
    var items: [String]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.self) { t in
                Text(t).font(.system(size: 12)).padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.07)))
            }
        }
    }
}

/// Simple left-to-right wrapping layout.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > maxW { x = 0; y += row + spacing; row = 0 }
            x += s.width + spacing
            row = max(row, s.height)
            widest = max(widest, x)
        }
        return CGSize(width: min(maxW, widest), height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            row = max(row, s.height)
        }
    }
}

/// Text is being typed in a field: the Delete key belongs to the text, not to the rows.
@MainActor func isTypingText() -> Bool { NSApp.keyWindow?.firstResponder is NSText }

/// Removing rows: the field being edited is closed first and the change runs a moment later, so no text field is
/// left editing a row that no longer exists.
@MainActor func afterEndingEdit(_ action: @escaping @MainActor () -> Void) {
    NSApp.keyWindow?.makeFirstResponder(nil)
    DispatchQueue.main.async { action() }
}
