import SSMTCore
import SwiftUI

/// Wide multitrack timeline. "Whole show": a live strip where "now" stays put and sound flows
/// right to left; what the next GO would start is drawn dashed from "now". "Group": the contents
/// of the selected group, editable with the mouse (drag a clip = change its pre-wait).
struct ShowTimelineView: View {
    /// Playback state (redraws this view only while something plays).
    @EnvironmentObject var live: ShowLive
    @EnvironmentObject var show: ShowStore
    @EnvironmentObject var loc: Localizer
    /// A group's own multitrack (inside its inspector): one track per cue, drag to set its start.
    var group: UUID? = nil
    /// Seconds across the whole width (shared, so ⌘= / ⌘− zoom it).
    private var span: Double { show.timelineSpan }
    /// Group timeline: seconds at the left edge (pan with a drag on empty space, the wheel / trackpad or the slider).
    @State private var scroll: Double = 0
    @State private var panStart: Double?
    @State private var hovering = false
    @State private var wheelMonitor: Any?
    @State private var drag: (id: UUID, dx: CGFloat, mode: DragMode)?
    /// Group timeline: where the ruler is being dragged (the playback cursor follows; release = seek there).
    @State private var scrub: Double?

    /// Group timeline: the body moves the cue (its pre-wait); the left edge trims the start of the file
    /// together with the pre-wait; the right edge trims the end; ⌥ while dragging slips the sound inside the clip
    /// (file start and end move, the clip's place and length stay).
    enum DragMode { case move, trimStart, trimEnd, slip }

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
                    // Redrawn every display frame while something plays, so the cursor and the live clips glide.
                    TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !isPlaying)) { tl in
                        let dt = isPlaying ? min(0.15, max(0, tl.date.timeIntervalSince(live.snapshotDate))) : 0
                        let moving = groupMode == nil ? currentClips(dt) : clips
                        Canvas { ctx, size in draw(&ctx, size: size, clips: moving, layout: layout, cursor: cursor(dt, clips: clips)) }
                    }
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
                    // Ruler of a group timeline: click or drag to move playback there.
                    if let g = groupMode {
                        Color.white.opacity(0.001)
                            .frame(width: geo.size.width, height: layout.ruler + 4)
                            .gesture(DragGesture(minimumDistance: 0)
                                .onChanged { v in scrub = max(0, Double(v.location.x - layout.origin) / layout.pps) }
                                .onEnded { v in
                                    scrub = nil
                                    show.seekGroup(g.id, to: max(0, (Double(v.location.x - layout.origin) / layout.pps * 100).rounded() / 100))
                                })
                            .help(loc.t("show.timeline.seekHint"))
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
        .onChange(of: live.snapshot) { _ in followCursor() }
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
            Button { show.timelineSpan = min(600, span * 1.5) } label: { Image(systemName: "minus.magnifyingglass") }.buttonStyle(.borderless)
            Text("\(Int(span)) \(loc.t("show.sec"))").font(Theme.mono(10)).foregroundStyle(Theme.textSecondary).frame(width: 44)
            Button { show.timelineSpan = max(5, span / 1.5) } label: { Image(systemName: "plus.magnifyingglass") }.buttonStyle(.borderless)
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
            Button { show.timelineSpan = min(600, span * 1.5) } label: { Image(systemName: "minus.magnifyingglass") }.buttonStyle(.borderless)
            Text("\(Int(span)) \(loc.t("show.sec"))").font(Theme.mono(10)).foregroundStyle(Theme.textSecondary).frame(width: 44)
            Button { show.timelineSpan = max(5, span / 1.5) } label: { Image(systemName: "plus.magnifyingglass") }.buttonStyle(.borderless)
        }
    }

    // MARK: Data

    /// Something is playing (not paused): the timeline animates.
    private var isPlaying: Bool { live.snapshot.running.contains { !$0.paused } || scrub != nil }

    /// Playback position on a group timeline (seconds from the group start) and whether the group is under way.
    /// Like a DAW's play cursor: the group's own clock, smoothed between engine snapshots by `dt`.
    private func cursor(_ dt: Double, clips: [TimelineClip]) -> (time: Double, active: Bool)? {
        guard let g = groupMode else { return nil }
        if let s = scrub { return (s, true) }
        let running = live.snapshot.running
        if let r = running.first(where: { $0.id == g.id }) {
            let d = r.paused ? 0 : dt
            if r.phase == .preWait { return (-max(0, (r.remaining ?? 0) - d), true) }
            return (r.elapsed + d, true)
        }
        // A track of the group started on its own: its place on the timeline plus how far it has played.
        for r in running where r.phase != .preWait {
            if let c = clips.first(where: { $0.cueID == r.id && $0.style != .marker }) {
                return (c.start + r.elapsed + (r.paused ? 0 : dt), true)
            }
        }
        return (live.snapshot.loaded[g.id] ?? 0, false)
    }

    /// While a group plays, its timeline scrolls to keep the cursor in view.
    private func followCursor() {
        guard group != nil || groupMode != nil, panStart == nil, drag == nil, scrub == nil,
              let c = cursor(0, clips: currentClips()), c.active else { return }
        if c.time > scroll + span * 0.9 || c.time < scroll - 0.5 { scroll = max(-2, c.time - span * 0.1) }
    }

    private func currentClips(_ dt: Double = 0) -> [TimelineClip] {
        if let g = groupMode {
            return ShowTimeline.planGroup(show.doc, group: g.id, fileLength: show.fileLength, lanePerCue: group != nil)
        }
        var clips: [TimelineClip] = []
        for r in live.snapshot.running {
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
                let d0 = r.paused ? 0 : dt
                clips.append(TimelineClip(cueID: r.id, style: style, start: max(0, (r.remaining ?? 0) - d0), duration: d, live: true, tag: "live"))
            } else {
                let d0 = r.paused ? 0 : dt
                clips.append(TimelineClip(cueID: r.id, style: style, start: -(r.elapsed + d0), duration: r.duration, live: true, tag: "live"))
            }
        }
        // What the next GO starts, if pressed now.
        let playhead = live.snapshot == .empty ? show.currentList?.cues.first?.id : live.snapshot.playhead
        if let ph = playhead {
            let runningIDs = Set(live.snapshot.running.map(\.id))
            clips += ShowTimeline.plan(show.doc, from: ph, fileLength: show.fileLength, limit: 60)
                .filter { !runningIDs.contains($0.cueID) }
        }
        return ShowTimeline.assignLanes(clips)
    }

    private func dragMode(_ c: TimelineClip, at x: CGFloat, width: CGFloat) -> DragMode {
        if c.style == .audio && NSEvent.modifierFlags.contains(.option) { return .slip }
        guard c.style == .audio, width > 24 else { return .move }
        if x < 7 { return .trimStart }
        if c.duration != nil && x > width - 7 { return .trimEnd }
        return .move
    }

    /// Edges of the other clips (and the group start): the dragged edge snaps to them (⌘ while dragging: no snapping).
    private func guides(except id: UUID, clips: [TimelineClip]) -> [Double] {
        var g: [Double] = [0]
        // The playback cursor too (pause, then drag a cue to exactly that moment).
        if let c = cursor(0, clips: clips) { g.append(c.time) }
        for o in clips where o.cueID != id {
            g.append(o.start)
            if let d = o.duration { g.append(o.start + d) }
        }
        return g
    }

    private func snapped(_ c: TimelineClip, dx: CGFloat, mode: DragMode, clips: [TimelineClip], layout: Layout) -> CGFloat {
        guard !NSEvent.modifierFlags.contains(.command), mode != .slip else { return dx }
        let delta = Double(dx) / layout.pps
        let edges: [Double]
        switch mode {
        case .move: edges = [c.start] + (c.duration.map { [c.start + $0] } ?? [])
        case .trimStart: edges = [c.start]
        case .trimEnd: edges = c.duration.map { [c.start + $0] } ?? []
        case .slip: edges = []
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
        case .slip:
            // Dragging right moves the sound right inside the clip: the file starts earlier.
            guard let a = cue.audio, let length = show.fileLength(cue) else { return }
            let rate = max(a.rate, 0.05)
            let used = (a.end ?? length) - a.start
            let shift = min(max(-delta * rate, -a.start), length - used - a.start)
            guard abs(shift) > 0.005 else { return }
            show.edit(loc.t("show.trim")) {
                $0.updateCue(c.cueID) { cue in
                    cue.audio?.start = max(0, r(a.start + shift))
                    if let e = a.end { cue.audio?.end = r(e + shift) }
                    if let ls = a.loopStart { cue.audio?.loopStart = r(ls + shift) }
                    if let le = a.loopEnd { cue.audio?.loopEnd = r(le + shift) }
                }
            }
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

    private func draw(_ ctx: inout GraphicsContext, size: CGSize, clips: [TimelineClip], layout L: Layout,
                      cursor: (time: Double, active: Bool)?) {
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
                case .slip: break
                }
            }
            guard r.maxX > -20, r.minX < size.width + 20 else { continue }
            let cue = show.doc.cue(c.cueID)
            let ghost = L.live && !c.live
            switch c.style {
            case .audio:
                let shape = Path(roundedRect: r, cornerRadius: 5)
                // The cue's colour; green otherwise.
                let tint = cue.flatMap { CueColor(rawValue: $0.color) }.flatMap { $0 == .none ? nil : $0.color } ?? Theme.accent
                ctx.fill(shape, with: .color(tint.opacity(ghost ? 0.05 : 0.16)))
                var slip = 0.0
                if let d = drag, d.id == c.cueID, d.mode == .slip { slip = -Double(d.dx) / L.pps }
                if let cue { drawWave(&ctx, cue: cue, clip: c, rect: r, pps: L.pps, alpha: ghost ? 0.25 : 0.7, tint: tint, slip: slip) }
                if ghost {
                    ctx.stroke(shape, with: .color(Color.white.opacity(0.3)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                } else {
                    ctx.stroke(shape, with: .color(tint.opacity(0.6)), lineWidth: 1)
                }
                // Already played part (live view): darker.
                if L.live && r.minX < L.origin {
                    let past = CGRect(x: r.minX, y: r.minY, width: min(r.width, L.origin - r.minX), height: r.height)
                    ctx.fill(Path(roundedRect: past, cornerRadius: 5), with: .color(Color.black.opacity(0.35)))
                }
            case .fade:
                let up = cue?.fade?.fromSilence == true || (cue?.fade?.level ?? showSilenceDB) > -20
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

        // Playback cursor of a group timeline (yellow line): exactly at the group's clock on the ruler,
        // so it crosses each waveform at the sample being heard.
        if let c = cursor, !L.live {
            let x = L.x(c.time)
            if x >= -1 && x <= size.width + 1 {
                let color = Theme.signalYellow.opacity(c.active ? 1 : 0.55)
                var p = Path(); p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height))
                ctx.stroke(p, with: .color(color), lineWidth: c.active ? 1.5 : 1)
                var head = Path()
                head.move(to: CGPoint(x: x - 5, y: 0)); head.addLine(to: CGPoint(x: x + 5, y: 0))
                head.addLine(to: CGPoint(x: x, y: 7)); head.closeSubpath()
                ctx.fill(head, with: .color(color))
                let text = Text(clockText(c.time)).font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(.black)
                let resolved = ctx.resolve(text)
                let w = resolved.measure(in: CGSize(width: 200, height: 20)).width + 8
                let bx = min(max(x + 6, 0), size.width - w)
                ctx.fill(Path(roundedRect: CGRect(x: bx, y: 1, width: w, height: 13), cornerRadius: 3), with: .color(color))
                ctx.draw(resolved, at: CGPoint(x: bx + 4, y: 7.5), anchor: .leading)
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
    /// Cursor time as on a DAW: m:ss.t (or s.t under a minute); negative before the group starts.
    private func clockText(_ t: Double) -> String {
        let v = abs(t)
        let m = Int(v) / 60
        let s = v - Double(m * 60)
        let body = m > 0 ? String(format: "%d:%04.1f", m, s) : String(format: "%.1f", s)
        return (t < -0.05 ? "−" : "") + body
    }

    private func drawWave(_ ctx: inout GraphicsContext, cue: Cue, clip: TimelineClip, rect r: CGRect, pps: Double, alpha: Double,
                          tint: Color = Theme.accent, slip: Double = 0) {
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
            let fileT = map.position(tau) + slip * rate
            let i = min(wave.count - 1, max(0, Int(fileT / length * Double(wave.count))))
            let h = CGFloat(wave[i]) * half
            p.move(to: CGPoint(x: x, y: mid - h))
            p.addLine(to: CGPoint(x: x, y: mid + h))
            x += 2
        }
        ctx.stroke(p, with: .color(tint.opacity(alpha)), lineWidth: 1)
    }
}
