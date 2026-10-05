import AppKit
import SSMTCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - One-shot pads

/// Grid of one-shot pads of the current bank; F-keys and clicks fire them without moving the playhead.
struct PadGridView: View {
    /// Playback state (redraws this view only while something plays).
    @EnvironmentObject var live: ShowLive
    @EnvironmentObject var show: ShowStore
    @EnvironmentObject var loc: Localizer
    var columns: Int
    /// Inside the sidebar: no own title and card (the sidebar tab names it).
    var embedded = false

    var body: some View {
        let bank = show.currentBank
        let running = Dictionary(uniqueKeysWithValues: live.snapshot.running.map { ($0.id, $0) })
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if !embedded {
                    Text(loc.t("show.oneShot").uppercased()).font(Theme.label(11)).tracking(1.2).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(show.doc.banks) { b in
                            let on = b.id == bank?.id
                            Button { show.bankID = b.id } label: {
                                Text(b.name).font(.system(size: 11, weight: on ? .semibold : .regular)).lineLimit(1)
                                    .padding(.horizontal, 9).padding(.vertical, 4)
                                    .background(Capsule().fill(on ? Theme.accent.opacity(0.2) : Color.white.opacity(0.05)))
                                    .foregroundStyle(on ? Theme.textPrimary : Theme.textSecondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxWidth: 170)
                if !show.showMode {
                    Menu {
                        Button(loc.t("show.pad.add")) { show.choosePads() }
                        Button(loc.t("show.bank.add")) { show.addBank() }
                    } label: { Image(systemName: "plus") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .help(loc.t("show.pad.add"))
                }
            }
            if let bank, !bank.cues.isEmpty {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
                        ForEach(bank.cues) { cue in
                            PadButton(cue: cue, running: running[cue.id], selected: show.selection.contains(cue.id))
                        }
                    }
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "square.grid.3x3.square").font(.system(size: 26)).foregroundStyle(Theme.textMuted)
                    Text(loc.t("show.pad.empty")).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .glassCard(padding: embedded ? 0 : 12, plain: embedded)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard !show.showMode else { return false }
            var urls: [URL] = []
            let group = DispatchGroup()
            let lock = NSLock()
            for p in providers {
                group.enter()
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { lock.lock(); urls.append(url); lock.unlock() }
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                show.addPads(urls.filter { ShowStore.isPlayable($0) })
            }
            return true
        }
    }
}

private struct PadButton: View {
    @EnvironmentObject var show: ShowStore
    @EnvironmentObject var loc: Localizer
    var cue: Cue
    var running: RunningCue?
    var selected: Bool
    @State private var pressed = false

    var body: some View {
        let playing = running != nil
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        VStack(alignment: .leading, spacing: 4) {
            Text(cue.name.isEmpty ? loc.t("cue.kind.\(cue.kind.rawValue)") : cue.name)
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            HStack {
                Text(cue.hotkey ?? "").font(Theme.mono(10, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(playing ? "−" + showTime(running?.remaining) : length)
                    .font(Theme.mono(10)).foregroundStyle(playing ? Theme.accent : Theme.textSecondary)
            }
        }
        .padding(9)
        .frame(height: 66)
        .background(
            ZStack(alignment: .bottomLeading) {
                shape.fill(playing ? Theme.accent.opacity(0.2) : Color.white.opacity(pressed ? 0.12 : 0.05))
                if let p = running?.progress {
                    GeometryReader { g in
                        Rectangle().fill(Theme.accent).frame(width: g.size.width * p, height: 3)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                    .clipShape(shape)
                }
            }
        )
        .overlay(shape.strokeBorder(selected ? Theme.accent : (playing ? Theme.accent.opacity(0.6) : Color.white.opacity(0.08)),
                                    lineWidth: selected ? 2 : 1))
        .overlay(alignment: .topTrailing) {
            if cue.padMode == .hold { Image(systemName: "hand.point.up").font(.system(size: 9)).foregroundStyle(Theme.textMuted).padding(6) }
            if cue.audio?.plays == 0 { Image(systemName: "repeat").font(.system(size: 9)).foregroundStyle(Theme.dataBlue).padding(6) }
        }
        .contentShape(shape)
        // Show mode: press fires the pad (release matters for "hold" pads).
        // Edit mode: click selects; double-click fires.
        .gesture(show.showMode ? DragGesture(minimumDistance: 0)
            .onChanged { _ in
                if !pressed { pressed = true; show.pad(cue.id, pressed: true) }
            }
            .onEnded { _ in
                pressed = false
                show.pad(cue.id, pressed: false)
            } : nil)
        .onTapGesture(count: 2) { if !show.showMode { show.pad(cue.id, pressed: true) } }
        .simultaneousGesture(TapGesture().onEnded { if !show.showMode { show.selection = [cue.id] } })
        .contextMenu {
            Button(loc.t("show.playNow")) { show.pad(cue.id, pressed: true) }
            Button(loc.t("show.stopCue")) { show.stop(cue.id) }
            if !show.showMode {
                Button(loc.t("action.delete"), role: .destructive) { show.edit { $0.delete([cue.id]) } }
            }
        }
    }

    private var length: String {
        guard let d = ShowTimeline.audioDuration(cue, fileLength: show.fileLength(cue)) else {
            return cue.audio?.plays == 0 ? "∞" : ""
        }
        return showTime(d)
    }
}
