import AppKit
import SSMTCore
import SwiftUI
import UniformTypeIdentifiers

/// The cue list: nested rows with playhead, live progress, drag-to-reorder and file drop.
struct CueListView: View {
    @EnvironmentObject var show: ShowStore
    @EnvironmentObject var loc: Localizer
    @State private var anchor: UUID?

    var body: some View {
        let rows = show.currentList?.cues.flattened(collapsed: show.collapsed) ?? []
        let running = Dictionary(uniqueKeysWithValues: show.snapshot.running.map { ($0.id, $0) })
        let playhead = show.snapshot == .empty ? show.currentList?.cues.first?.id : show.snapshot.playhead
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(rows, id: \.cue.id) { row in
                            CueRow(cue: row.cue, depth: row.depth,
                                   isPlayhead: row.cue.id == playhead,
                                   isSelected: show.selection.contains(row.cue.id),
                                   running: running[row.cue.id],
                                   problem: isMissing(row.cue) ? "show.fileMissing"
                                       : isUnreadable(row.cue) ? "show.fileUnreadable" : show.snapshot.problems[row.cue.id])
                                .id(row.cue.id)
                                .onTapGesture(count: 2) { show.setPlayhead(row.cue.id) }
                                .simultaneousGesture(TapGesture().onEnded { select(row.cue.id, rows: rows) })
                                .contextMenu { menu(row.cue) }
                                .onDrag { NSItemProvider(object: row.cue.id.uuidString as NSString) }
                                // As in QLab: dropped on the lower part of a group row, files and cues go into the group.
                                .onDrop(of: [.text, .fileURL], isTargeted: nil) { providers, at in
                                    drop(providers, before: row.cue, into: row.cue.kind == .group && at.y > 14 ? row.cue.id : nil)
                                }
                        }
                        // Drop zone at the end of the list.
                        Color.clear.frame(height: 80)
                            .contentShape(Rectangle())
                            .onTapGesture { show.selection = [] }
                            .onDrop(of: [.text, .fileURL], isTargeted: nil) { providers in drop(providers, before: nil) }
                        if rows.isEmpty { emptyHint }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: playhead) { id in
                    if show.showMode, let id { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) } }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassCard(padding: 10)
    }

    private var header: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 44)
            col(loc.t("show.col.number"), 54)
            Color.clear.frame(width: 26)
            Text(loc.t("show.col.name")).frame(maxWidth: .infinity, alignment: .leading)
            col(loc.t("show.col.pre"), 64, .trailing)
            col(loc.t("show.col.action"), 76, .trailing)
            col(loc.t("show.col.post"), 64, .trailing)
            Color.clear.frame(width: 34)
        }
        .font(Theme.label(11))
        .foregroundStyle(Theme.textSecondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
        .fixedSize(horizontal: false, vertical: true)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private func col(_ t: String, _ w: CGFloat, _ a: Alignment = .leading) -> some View {
        Text(t).frame(width: w, alignment: a)
    }

    private var emptyHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform.badge.plus").font(.system(size: 34)).foregroundStyle(Theme.textMuted)
            Text(loc.t("show.empty")).font(.system(size: 13)).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func isUnreadable(_ cue: Cue) -> Bool {
        guard cue.kind == .audio, let p = show.resolvedPath(cue) else { return false }
        return show.unreadableFiles[p] != nil
    }

    private func isMissing(_ cue: Cue) -> Bool {
        guard cue.kind == .audio else { return false }
        guard let p = show.resolvedPath(cue) else { return true }
        return show.missingFiles.contains(p)
    }

    private func select(_ id: UUID, rows: [(cue: Cue, depth: Int)]) {
        // Leave any text field of the inspector, so Space is GO again and not a typed space.
        NSApp.keyWindow?.makeFirstResponder(nil)
        let mods = NSEvent.modifierFlags
        if mods.contains(.command) {
            if show.selection.contains(id) { show.selection.remove(id) } else { show.selection.insert(id) }
            anchor = id
        } else if mods.contains(.shift), let a = anchor,
                  let i = rows.firstIndex(where: { $0.cue.id == a }), let j = rows.firstIndex(where: { $0.cue.id == id }) {
            show.selection = Set(rows[min(i, j)...max(i, j)].map(\.cue.id))
        } else {
            show.selection = [id]
            anchor = id
            // As in QLab: the clicked cue is the next one for GO / Space (top-level cues only).
            if rows.first(where: { $0.cue.id == id })?.depth == 0 { show.setPlayhead(id) }
        }
    }

    @ViewBuilder private func menu(_ cue: Cue) -> some View {
        Button(loc.t("show.setPlayhead")) { show.setPlayhead(cue.id) }
        Button(loc.t("show.playNow")) { show.start(cue.id) }
        Button(loc.t("show.stopCue")) { show.stop(cue.id) }
        if !show.showMode {
            Divider()
            Button(loc.t("action.duplicate")) {
                if !show.selection.contains(cue.id) { show.selection = [cue.id] }
                show.duplicateSelection()
            }
            if show.selection.count > 1 && show.selection.contains(cue.id) {
                Button(loc.t("show.groupSelection")) { show.add(.group) }
            }
            if cue.kind == .group {
                Button(loc.t("show.addAudioToGroup")) {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = ShowStore.audioTypes
                    panel.allowsMultipleSelection = true
                    if panel.runModal() == .OK { show.addAudioFiles(panel.urls, intoGroup: cue.id) }
                }
            }
            Button(loc.t("action.delete"), role: .destructive) {
                if !show.selection.contains(cue.id) { show.selection = [cue.id] }
                show.deleteSelection()
            }
        }
    }

    /// Cue ids (reorder) or audio files (new cues) dropped onto a row.
    private func drop(_ providers: [NSItemProvider], before: Cue?, into target: UUID? = nil) -> Bool {
        guard !show.showMode, let lid = show.listID else { return false }
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        if !files.isEmpty {
            var urls: [URL] = []
            let group = DispatchGroup()
            let lock = NSLock()
            for p in files {
                group.enter()
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { lock.lock(); urls.append(url); lock.unlock() }
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                let audio = urls.filter { ShowStore.isPlayable($0) }
                // Dropped onto a row: insert before it (after the previous cue).
                var after: UUID?
                if let before, let list = show.currentList {
                    let flat = list.cues.flattened().map(\.cue.id)
                    if let i = flat.firstIndex(of: before.id), i > 0 { after = flat[i - 1] }
                }
                if let target {
                    show.addAudioFiles(audio, intoGroup: target)
                    show.collapsed.remove(target)
                    return
                }
                show.addAudioFiles(audio, after: before == nil ? show.currentList?.cues.last?.id : after)
            }
            return true
        }
        guard let p = providers.first else { return false }
        _ = p.loadObject(ofClass: NSString.self) { obj, _ in
            guard let s = obj as? String, let id = UUID(uuidString: s) else { return }
            DispatchQueue.main.async {
                let ids = show.selection.contains(id) ? show.orderedSelection : [id]
                if let target {
                    guard !ids.contains(target) else { return }
                    show.edit(loc.t("show.move")) { $0.move(ids, before: nil, intoGroup: target, list: lid) }
                    show.collapsed.remove(target)
                    return
                }
                guard before?.id != id else { return }
                show.edit(loc.t("show.move")) { $0.move(ids, before: before?.id, list: lid) }
            }
        }
        return true
    }
}

/// One row of the cue list.
struct CueRow: View {
    @EnvironmentObject var show: ShowStore
    @EnvironmentObject var loc: Localizer
    var cue: Cue
    var depth: Int
    var isPlayhead: Bool
    var isSelected: Bool
    var running: RunningCue?
    /// Localisation key of what is wrong with the cue (nil = fine).
    var problem: String?
    private var hasProblem: Bool { problem != nil && problem != "error.show.notReady" }

    var body: some View {
        HStack(spacing: 0) {
            // Playhead marker and live state.
            ZStack {
                if isPlayhead {
                    Image(systemName: "arrowtriangle.right.fill").font(.system(size: 11)).foregroundStyle(Theme.accent)
                }
            }
            .frame(width: 18)
            stateIcon.frame(width: 22)
            Text(cue.number).font(Theme.mono(13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                .lineLimit(1).frame(width: 54, alignment: .leading)
            HStack(spacing: 4) {
                Color.clear.frame(width: CGFloat(depth) * 16)
                if cue.kind == .group {
                    Button {
                        if show.collapsed.contains(cue.id) { show.collapsed.remove(cue.id) } else { show.collapsed.insert(cue.id) }
                    } label: {
                        Image(systemName: show.collapsed.contains(cue.id) ? "chevron.right" : "chevron.down")
                            .font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textSecondary).frame(width: 12)
                    }
                    .buttonStyle(.plain)
                }
                Image(systemName: cue.kind.icon).font(.system(size: 12))
                    .foregroundStyle(cue.armed ? Theme.textSecondary : Theme.textMuted).frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: isPlayhead ? .semibold : .regular))
                        .foregroundStyle(cue.armed ? Theme.textPrimary : Theme.textMuted)
                        .strikethrough(!cue.armed, color: Theme.textMuted)
                        .lineLimit(1)
                    if let sub = subtitle {
                        Text(sub).font(.system(size: 11)).foregroundStyle(hasProblem ? Theme.statusWarning : problem != nil ? Theme.dataBlue : Theme.textSecondary).lineLimit(1)
                    }
                }
                if let key = cue.hotkey, !key.isEmpty {
                    Text(key.uppercased()).font(Theme.mono(10, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.hairlineStrong))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            time(cue.preWait > 0 ? showTime(cue.preWait) : "", width: 64,
                 live: running?.phase == .preWait ? running?.remaining : nil)
            time(actionText, width: 76, live: running?.phase == .running ? running?.remaining : nil)
            time(cue.continueMode == .autoContinue ? showTime(cue.postWait) : "", width: 64, live: nil)
            continueGlyph.frame(width: 34)
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
        .background(background)
        .overlay(alignment: .leading) {
            if let c = CueColor(rawValue: cue.color), c != .none {
                RoundedRectangle(cornerRadius: 1.5).fill(c.color).frame(width: 3).padding(.vertical, 6)
            }
        }
        .contentShape(Rectangle())
    }

    private var title: String {
        if !cue.name.isEmpty { return cue.name }
        if cue.kind.needsTarget, let t = show.doc.cue(cue.target) {
            return loc.t("cue.kind.\(cue.kind.rawValue)") + " → " + (t.name.isEmpty ? t.number : t.name)
        }
        return loc.t("cue.kind.\(cue.kind.rawValue)")
    }

    private var subtitle: String? {
        if cue.kind == .audio {
            if let problem { return loc.t(problem) }
            return cue.audio.map { ($0.file as NSString).lastPathComponent }
        }
        if cue.kind.needsTarget {
            guard let t = show.doc.cue(cue.target) else { return loc.t("show.noTarget") }
            return "→ " + [t.number, t.name].filter { !$0.isEmpty }.joined(separator: " · ")
        }
        if cue.kind == .group { return loc.t("group.mode.\(cue.groupMode.rawValue)") }
        if !cue.notes.isEmpty { return cue.notes }
        return nil
    }

    /// Length of the action shown in the list.
    private var actionText: String {
        switch cue.kind {
        case .audio:
            guard cue.audio != nil, let length = show.fileLength(cue) else { return "" }
            return showTime(ShowTimeline.audioDuration(cue, fileLength: length))
        case .wait: return showTime(cue.duration)
        case .fade: return showTime(cue.fade?.duration)
        case .stop: return cue.stopFade > 0 ? showTime(cue.stopFade) : ""
        default: return ""
        }
    }

    private func time(_ text: String, width: CGFloat, live: Double?) -> some View {
        Text(live.map { "−" + showTime($0) } ?? text)
            .font(Theme.mono(12))
            .foregroundStyle(live != nil ? Theme.accent : Theme.textSecondary)
            .frame(width: width, alignment: .trailing)
    }

    @ViewBuilder private var stateIcon: some View {
        if let r = running {
            Image(systemName: r.paused ? "pause.circle.fill" : (r.phase == .preWait ? "clock.fill" : "play.circle.fill"))
                .font(.system(size: 13))
                .foregroundStyle(r.paused ? Theme.signalYellow : (r.phase == .preWait ? Theme.dataBlue : Theme.accent))
        } else if hasProblem {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(Theme.statusWarning)
        }
    }

    @ViewBuilder private var continueGlyph: some View {
        switch cue.continueMode {
        case .none: EmptyView()
        case .autoContinue:
            Image(systemName: "arrow.down.to.line.compact").font(.system(size: 12)).foregroundStyle(Theme.dataBlue)
                .help(loc.t("continue.autoContinue"))
        case .autoFollow:
            Image(systemName: "arrow.turn.right.down").font(.system(size: 12)).foregroundStyle(Theme.accent)
                .help(loc.t("continue.autoFollow"))
        }
    }

    @ViewBuilder private var background: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        ZStack(alignment: .leading) {
            shape.fill(isSelected ? Theme.accent.opacity(0.16) : (isPlayhead ? Color.white.opacity(0.07) : Color.white.opacity(0.025)))
            if let r = running, let p = r.progress {
                GeometryReader { g in
                    shape.fill((r.phase == .preWait ? Theme.dataBlue : Theme.accent).opacity(0.12))
                        .frame(width: g.size.width * p)
                }
            }
            if isPlayhead { shape.strokeBorder(Theme.accent.opacity(0.55), lineWidth: 1) }
        }
    }
}
