import SSMTCore
import SwiftUI

/// Wide multitrack timeline. "Whole show": a live strip where "now" stays put and sound flows
/// right to left; what the next GO would start is drawn dashed from "now". "Group": the contents
/// of the selected group, editable with the mouse (drag a clip = change its pre-wait).
struct ShowTimelineView: View {
    @EnvironmentObject var show: ShowStore
    @EnvironmentObject var loc: Localizer
    /// A group's own multitrack (inside its inspector): one track per cue, drag to set its start.
    var group: UUID? = nil
    /// Seconds across the whole width.
    @State private var span: Double = 40
    /// Group timeline: seconds at the left edge (pan with a drag on empty space, the wheel / trackpad or the slider).
    @State private var scroll: Double = 0
    @State private var panStart: Double?
    @State private var hovering = false
    @State private var wheelMonitor: Any?
    @State private var drag: (id: UUID, dx: CGFloat, mode: DragMode)?

    /// As in QLab's group timeline: the body moves the cue (its pre-wait); the left edge trims the start of the file
    /// together with the pre-wait; the right edge trims the end.
    enum DragMode { case move, trimStart, trimEnd }

    private var selectedGroup: Cue? {
        guard show.selection.count == 1, let id = show.selection.first, let c = show.doc.cue(id), c.kind == .group else { return nil }
        return c
    }

    private var groupMode: Cue? {
        guard let g = group ?? show.timelineGroup else { return nil }
        return show.doc.cue(g)
    }

    var body: some View {
        VStack(spacing: 6) {
            header
            GeometryReader { geo in
                let clips = currentClips()
                let layout = Layout(size: geo.size, span: span, live: groupMode == nil, clips: clips,
                                    scroll: groupMode == nil ? 0 : scroll)
                ZStack(alignment: .topLeading) {
                    Canvas { ctx, size in draw(&ctx, size: size, clips: clips, layout: layout) }
                    // Empty space: drag to move along the timeline.
                    Color.white.opacity(0.001)
                        .gesture(groupMode != nil ? DragGesture(minimumDistance: 2)
                            .onChanged { v in
                                if panStart == nil { panStart = scroll }
                                scroll = max(-2, (panStart ?? 0) - Double(v.translation.width) / layout.pps)
                            }
                            .onEnded { _ in panStart = nil } : nil)
                    ForEach(clips.filter { $0.style != .marker }) { c in
                        let r = layout.rect(c)
                        Color.white.opacity(0.001)
                            .frame(width: max(8, r.width), height: max(8, r.height))
                            .offset(x: r.minX, y: r.minY)
                            .onTapGesture { if group == nil { show.selection = [c.cueID] } }
                            .gesture(groupMode != nil && !show.showMode ? DragGesture(minimumDistance: 2)
                                .onChanged { v in
                                    let mode = drag?.mode ?? dragMode(c, at: v.startLocation.x, width: r.width)
                                    drag = (c.cueID, snapped(c, dx: v.translation.width, mode: mode, clips: clips, layout: layout), mode)
                                }
                                .onEnded { v in
                                    let mode = drag?.mode ?? .move
                                    commit(c, dx: snapped(c, dx: v.translation.width, mode: mode, clips: clips, layout: layout),
                                           mode: mode, layout: layout)
                                } : nil)
                            .help(label(c.cueID))
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .clipped()
            }
            .onHover { hovering = $0 }
            if groupMode != nil {
                let length = max(span, (currentClips().compactMap { c in c.duration.map { c.start + $0 } ?? c.start }.max() ?? 0) + 2)
                Slider(value: $scroll, in: -2...max(-1, length - span * 0.8))
                    .controlSize(.mini)
                    .help(loc.t("show.timeline.scroll"))
            }
        }
        .onAppear {
            // Wheel / trackpad over the group timeline scrolls it sideways.
            wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { e in
                guard hovering, groupMode != nil else { return e }
                let d = abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) ? e.scrollingDeltaX : e.scrollingDeltaY
                scroll = max(-2, scroll - Double(d) * span / 900)
                return nil
            }
        }
        .onDisappear {
            if let m = wheelMonitor { NSEvent.removeMonitor(m) }
            wheelMonitor = nil
        }
        .glassCard(padding: group == nil ? 10 : 0, plain: group != nil)
    }

    @ViewBuilder private var header: some View {
        if let g = group { multitrackHeader(g) } else { liveHeader }
    }

    private func multitrackHeader(_ g: UUID) -> some View {
        HStack(spacing: 8) {
            Button {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = ShowStore.audioTypes
                panel.allowsMultipleSelection = true
                if panel.runModal() == .OK { show.addAudioFiles(panel.urls, intoGroup: g) }
            } label: { Label(loc.t("show.group.addTracks"), systemImage: "plus") }
                .buttonStyle(SSMTButtonStyle())
                .disabled(show.showMode)
            if let c = show.doc.cue(g), c.groupMode != .simultaneous {
                // The multitrack shows the group as a timeline; it plays that way only in timeline mode.
                Text(loc.t("show.group.notTimeline")).font(.system(size: 11)).foregroundStyle(Theme.signalYellow).lineLimit(2)
                Button(loc.t("show.group.makeTimeline")) { show.updateCue(g) { $0.groupMode = .simultaneous } }
                    .buttonStyle(SSMTButtonStyle())
                    .disabled(show.showMode)
            } else {
                Text(loc.t("show.group.multitrackHint")).font(.system(size: 11)).foregroundStyle(Theme.textMuted).lineLimit(2)
            }
            Spacer()
            zoom
        }
    }

    private var zoom: some View {
        HStack(spacing: 8) {
            Button { span = min(600, span * 1.5) } label: { Image(systemName: "minus.magnifyingglass") }.buttonStyle(.borderless)
            Text("\(Int(span)) \(loc.t("show.sec"))").font(Theme.mono(10)).foregroundStyle(Theme.textSecondary).frame(width: 44)
            Button { span = max(5, span / 1.5) } label: { Image(systemName: "plus.magnifyingglass") }.buttonStyle(.borderless)
        }
    }

    private var liveHeader: some View {
        HStack(spacing: 8) {
            Text(loc.t("show.timeline").uppercased()).font(Theme.label(11)).tracking(1.2).foregroundStyle(Theme.textSecondary)
            Picker("", selection: Binding(get: { show.timelineGroup }, set: { show.timelineGroup = $0 })) {
                Text(loc.t("show.timeline.show")).tag(UUID?.none)
                if let g = groupMode ?? selectedGroup {
                    Text(String(format: loc.t("show.timeline.group"), g.number.isEmpty ? g.name : g.number)).tag(UUID?.some(g.id))
                }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            if groupMode != nil && !show.showMode {
                Text(loc.t("show.timeline.dragHint")).font(.system(size: 11)).foregroundStyle(Theme.textMuted)
            }
            Spacer()
            Button { span = min(600, span * 1.5) } label: { Image(systemName: "minus.magnifyingglass") }.buttonStyle(.borderless)
            Text("\(Int(span)) \(loc.t("show.sec"))").font(Theme.mono(10)).foregroundStyle(Theme.textSecondary).frame(width: 44)
            Button { span = max(5, span / 1.5) } label: { Image(systemName: "plus.magnifyingglass") }.buttonStyle(.borderless)
        }
    }

    // MARK: Data

    private func currentClips() -> [TimelineClip] {
        if let g = groupMode {
            return ShowTimeline.planGroup(show.doc, group: g.id, fileLength: show.fileLength, lanePerCue: group != nil)
        }
        var clips: [TimelineClip] = []
        for r in show.snapshot.running {
            guard let cue = show.doc.cue(r.id) else { continue }
            let style: TimelineClip.Style
            switch cue.kind {
            case .audio: style = .audio
            case .fade: style = .fade
            case .wait: style = .wait
            default: continue
            }
            if r.phase == .preWait {
                let d = cue.kind == .audio ? ShowTimeline.audioDuration(cue, fileLength: show.fileLength(cue))
                    : (cue.kind == .fade ? cue.fade?.duration : cue.duration)
                clips.append(TimelineClip(cueID: r.id, style: style, start: r.remaining ?? 0, duration: d, live: true, tag: "live"))
            } else {
                clips.append(TimelineClip(cueID: r.id, style: style, start: -r.elapsed, duration: r.duration, live: true, tag: "live"))
            }
        }
        // What the next GO starts, if pressed now.
        let playhead = show.snapshot == .empty ? show.currentList?.cues.first?.id : show.snapshot.playhead
        if let ph = playhead {
            let runningIDs = Set(show.snapshot.running.map(\.id))
            clips += ShowTimeline.plan(show.doc, from: ph, fileLength: show.fileLength, limit: 60)
                .filter { !runningIDs.contains($0.cueID) }
        }
        return ShowTimeline.assignLanes(clips)
    }

    private func dragMode(_ c: TimelineClip, at x: CGFloat, width: CGFloat) -> DragMode {
        guard c.style == .audio, width > 24 else { return .move }
        if x < 7 { return .trimStart }
        if c.duration != nil && x > width - 7 { return .trimEnd }
        return .move
    }

    /// Edges of the other clips (and the group start): the dragged edge snaps to them (⌘ while dragging: no snapping).
    private func guides(except id: UUID, clips: [TimelineClip]) -> [Double] {
        var g: [Double] = [0]
        for o in clips where o.cueID != id {
            g.append(o.start)
            if let d = o.duration { g.append(o.start + d) }
        }
        return g
    }

    private func snapped(_ c: TimelineClip, dx: CGFloat, mode: DragMode, clips: [TimelineClip], layout: Layout) -> CGFloat {
        guard !NSEvent.modifierFlags.contains(.command) else { return dx }
        let delta = Double(dx) / layout.pps
        let edges: [Double]
        switch mode {
        case .move: edges = [c.start] + (c.duration.map { [c.start + $0] } ?? [])
        case .trimStart: edges = [c.start]
        case .trimEnd: edges = c.duration.map { [c.start + $0] } ?? []
        }
        let tolerance = 8 / layout.pps
        var best: Double?
        for e in edges {
            for g in guides(except: c.cueID, clips: clips) where abs(e + delta - g) < tolerance {
                let d = g - e
                if best == nil || abs(d - delta) < abs(best! - delta) { best = d }
            }
        }
        return CGFloat((best ?? delta) * layout.pps)
    }

    private func commit(_ c: TimelineClip, dx: CGFloat, mode: DragMode, layout: Layout) {
        drag = nil
        let delta = Double(dx) / layout.pps
        guard abs(delta) > 0.01, let cue = show.doc.cue(c.cueID) else { return }
        func r(_ v: Double) -> Double { (v * 100).rounded() / 100 }
        switch mode {
        case .move:
            let newPre = max(0, r(cue.preWait + delta))
            show.edit(loc.t("show.preWait")) { $0.updateCue(c.cueID) { $0.preWait = newPre } }
        case .trimStart:
            guard let a = cue.audio else { return }
            let rate = max(a.rate, 0.05)
            let limitEnd = (a.end ?? show.fileLength(cue) ?? .infinity) - 0.05
            // Not before the file start or the group start, not past the end.
            let d = min(max(delta, -cue.preWait, -a.start / rate), (limitEnd - a.start) / rate)
            show.edit(loc.t("show.trim")) {
                $0.updateCue(c.cueID) { cue in
                    cue.preWait = max(0, r(cue.preWait + d))
                    cue.audio?.start = max(0, r(a.start + d * rate))
                }
            }
        case .trimEnd:
            guard let a = cue.audio, let dur = c.duration, a.plays == 1, a.loopStart == nil else { return }
            let rate = max(a.rate, 0.05)
            let length = show.fileLength(cue) ?? .infinity
            let newEnd = min(length, max(a.start + 0.05, a.start + (dur + delta) * rate))
            show.edit(loc.t("show.trim")) { $0.updateCue(c.cueID) { $0.audio?.end = r(newEnd) } }
        }
    }

    private func label(_ id: UUID) -> String {
        guard let c = show.doc.cue(id) else { return "" }
        return [c.number, c.name.isEmpty ? loc.t("cue.kind.\(c.kind.rawValue)") : c.name].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    // MARK: Geometry

    struct Layout {
        let size: CGSize
        let span: Double
        let live: Bool
        let ruler: CGFloat = 18
        let controlRow: CGFloat = 22
        let lanes: Int
        let laneHeight: CGFloat
        var pps: Double { Double(size.width) / span }
        /// x of time 0 ("now" in the live view, group start otherwise).
        var origin: CGFloat { live ? size.width * 0.25 : 12 - CGFloat(scroll * pps) }

        /// Seconds at the left edge (group timeline).
        let scroll: Double

        init(size: CGSize, span: Double, live: Bool, clips: [TimelineClip], scroll: Double = 0) {
            self.size = size
            self.span = span
            self.live = live
            self.scroll = scroll
            lanes = max(3, (clips.map(\.lane).max() ?? 0) + 1)
            laneHeight = max(16, min(46, (size.height - ruler - controlRow - 6) / CGFloat(lanes)))
        }

        func x(_ t: Double) -> CGFloat { origin + CGFloat(t * pps) }

        func laneY(_ lane: Int) -> CGFloat {
            lane == ShowTimeline.controlLane ? ruler + CGFloat(lanes) * laneHeight + 4 : ruler + CGFloat(lane) * laneHeight
        }

        func rect(_ c: TimelineClip, dx: CGFloat = 0) -> CGRect {
            let x0 = x(c.start) + dx
            let x1 = c.duration.map { x(c.start + $0) + dx } ?? size.width + 40
            let h = c.lane == ShowTimeline.controlLane ? controlRow - 4 : laneHeight - 4
            return CGRect(x: x0, y: laneY(c.lane) + 2, width: max(3, x1 - x0), height: h)
        }
    }

    // MARK: Drawing

    private func draw(_ ctx: inout GraphicsContext, size: CGSize, clips: [TimelineClip], layout L: Layout) {
        // Lanes.
        for i in 0..<L.lanes {
            let r = CGRect(x: 0, y: L.laneY(i) + 1, width: size.width, height: L.laneHeight - 2)
            ctx.fill(Path(roundedRect: r, cornerRadius: 4), with: .color(Color.white.opacity(i % 2 == 0 ? 0.03 : 0.018)))
        }
        let cr = CGRect(x: 0, y: L.laneY(ShowTimeline.controlLane), width: size.width, height: L.controlRow)
        ctx.fill(Path(roundedRect: cr, cornerRadius: 4), with: .color(Color.white.opacity(0.02)))

        // Ruler: a readable step for the zoom.
        let steps: [Double] = [1, 2, 5, 10, 15, 30, 60, 120, 300]
        let step = steps.first { $0 * L.pps >= 60 } ?? 600
        let tMin = -Double(L.origin) / L.pps, tMax = Double(size.width - L.origin) / L.pps
        var t = (tMin / step).rounded(.down) * step
        while t <= tMax {
            let x = L.x(t)
            var p = Path(); p.move(to: CGPoint(x: x, y: L.ruler - 5)); p.addLine(to: CGPoint(x: x, y: size.height))
            ctx.stroke(p, with: .color(Color.white.opacity(0.05)), lineWidth: 1)
            let text = (L.live && t > 0 ? "+" : "") + showTime(abs(t)).replacingOccurrences(of: ".0", with: "")
            ctx.draw(Text((t < 0 ? "−" : "") + text).font(.system(size: 9, design: .monospaced)).foregroundColor(Theme.textMuted),
                     at: CGPoint(x: x + 3, y: 7), anchor: .leading)
            t += step
        }

        // Clips.
        if let d = drag {
            for g in guides(except: d.id, clips: clips) {
                var p = Path(); p.move(to: CGPoint(x: L.x(g), y: L.ruler)); p.addLine(to: CGPoint(x: L.x(g), y: size.height))
                ctx.stroke(p, with: .color(Theme.dataBlue.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        for c in clips {
            var r = L.rect(c)
            if let d = drag, d.id == c.cueID {
                switch d.mode {
                case .move: r = r.offsetBy(dx: d.dx, dy: 0)
                case .trimStart: r = CGRect(x: r.minX + d.dx, y: r.minY, width: max(3, r.width - d.dx), height: r.height)
                case .trimEnd: r = CGRect(x: r.minX, y: r.minY, width: max(3, r.width + d.dx), height: r.height)
                }
            }
            guard r.maxX > -20, r.minX < size.width + 20 else { continue }
            let cue = show.doc.cue(c.cueID)
            let ghost = L.live && !c.live
            switch c.style {
            case .audio:
                let shape = Path(roundedRect: r, cornerRadius: 5)
                ctx.fill(shape, with: .color(Theme.accent.opacity(ghost ? 0.05 : 0.16)))
                if let cue { drawWave(&ctx, cue: cue, clip: c, rect: r, pps: L.pps, alpha: ghost ? 0.25 : 0.7) }
                if ghost {
                    ctx.stroke(shape, with: .color(Color.white.opacity(0.3)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                } else {
                    ctx.stroke(shape, with: .color(Theme.accent.opacity(0.6)), lineWidth: 1)
                }
                // Already played part (live view): darker.
                if L.live && r.minX < L.origin {
                    let past = CGRect(x: r.minX, y: r.minY, width: min(r.width, L.origin - r.minX), height: r.height)
                    ctx.fill(Path(roundedRect: past, cornerRadius: 5), with: .color(Color.black.opacity(0.35)))
                }
            case .fade:
                let up = (cue?.fade?.level ?? showSilenceDB) > -20
                var p = Path()
                p.move(to: CGPoint(x: r.minX, y: up ? r.maxY : r.minY))
                p.addLine(to: CGPoint(x: r.maxX, y: up ? r.minY : r.maxY))
                ctx.stroke(p, with: .color(Theme.dataBlue.opacity(ghost ? 0.4 : 0.9)),
                           style: StrokeStyle(lineWidth: 1.6, dash: ghost ? [4, 3] : []))
            case .wait:
                ctx.fill(Path(roundedRect: r, cornerRadius: 4), with: .color(Color.white.opacity(ghost ? 0.03 : 0.06)))
            case .marker:
                var d = Path()
                let m = CGPoint(x: r.minX, y: r.midY)
                d.move(to: CGPoint(x: m.x, y: m.y - 5)); d.addLine(to: CGPoint(x: m.x + 5, y: m.y))
                d.addLine(to: CGPoint(x: m.x, y: m.y + 5)); d.addLine(to: CGPoint(x: m.x - 5, y: m.y)); d.closeSubpath()
                ctx.fill(d, with: .color(Theme.signalYellow.opacity(ghost ? 0.4 : 0.9)))
            }
            // Caption at the visible left edge of the clip.
            let lx = max(r.minX, 0) + 6
            if r.maxX - lx > 30 || c.style == .marker {
                let name = label(c.cueID)
                ctx.draw(Text(name).font(.system(size: 10, weight: .medium))
                            .foregroundColor(ghost ? Theme.textSecondary : Theme.textPrimary),
                         at: CGPoint(x: c.style == .marker ? r.minX + 8 : lx, y: r.minY + min(9, r.height / 2)), anchor: .leading)
            }
        }

        // "Now" (live view).
        if L.live {
            var p = Path(); p.move(to: CGPoint(x: L.origin, y: 0)); p.addLine(to: CGPoint(x: L.origin, y: size.height))
            ctx.stroke(p, with: .color(Theme.textPrimary), lineWidth: 2)
            ctx.draw(Text(loc.t("show.timeline.now")).font(.system(size: 9, weight: .semibold)).foregroundColor(Theme.textPrimary),
                     at: CGPoint(x: L.origin + 4, y: 7), anchor: .leading)
        }
    }

    /// Waveform of an audio clip from the file overview, following region, rate and loops.
    private func drawWave(_ ctx: inout GraphicsContext, cue: Cue, clip: TimelineClip, rect r: CGRect, pps: Double, alpha: Double) {
        guard let a = cue.audio, let path = show.resolvedPath(cue), let wave = show.waveforms[path], !wave.isEmpty,
              let length = show.clipInfo[path]?.duration, length > 0 else { return }
        let map = a.playMap(fileLength: length)
        let rate = max(a.rate, 0.05)
        var p = Path()
        let mid = r.midY
        let half = r.height * 0.42
        var x = max(r.minX, -2)
        let xEnd = min(r.maxX, 4000)
        while x < xEnd {
            let tau = Double(x - r.minX) / pps * rate
            let fileT = map.position(tau)
            let i = min(wave.count - 1, max(0, Int(fileT / length * Double(wave.count))))
            let h = CGFloat(wave[i]) * half
            p.move(to: CGPoint(x: x, y: mid - h))
            p.addLine(to: CGPoint(x: x, y: mid + h))
            x += 2
        }
        ctx.stroke(p, with: .color(Theme.accent.opacity(alpha)), lineWidth: 1)
    }
}
