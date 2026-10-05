import SSMTCore
import SwiftUI

/// Waveform editor of an audio cue: drag the start / end flags, the fade handles and the loop
/// edges; click to listen from that point; zoom and pan. One undo step per drag.
struct WaveformEditor: View {
    @EnvironmentObject var show: ShowStore
    @EnvironmentObject var loc: Localizer
    var cue: Cue
    var compact: Bool

    /// Visible window in file seconds (nil span = whole file).
    @State private var viewStart: Double = 0
    @State private var viewSpan: Double?
    @State private var detail: [Float]?
    @State private var detailKey = ""
    @State private var dragHandle: Handle?
    @State private var draft: AudioCueParams?
    @State private var panOrigin: Double?
    @State private var showFull = false

    enum Handle: Equatable { case start, end, fadeIn, fadeOut, loopStart, loopEnd, pan, envelope(Int), envelopeNew }

    private var path: String? { show.resolvedPath(cue) }
    private var length: Double? { show.fileLength(cue) }
    private var params: AudioCueParams { draft ?? cue.audio ?? AudioCueParams() }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let length, length > 0 {
                canvas(length: length)
                    .frame(height: compact ? 120 : 280)
                transport(length: length)
                fields(length: length)
                loopControls(length: length)
                envelopeControls
            } else {
                Text(loc.t(path.map { show.missingFiles.contains($0) } == true ? "show.fileMissing" : "show.wave.loading"))
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            }
        }
        .sheet(isPresented: $showFull) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text([cue.number, cue.name].filter { !$0.isEmpty }.joined(separator: " · ")).font(Theme.heading(17))
                    Spacer()
                    Button(loc.t("settings.done")) { showFull = false }.buttonStyle(SSMTButtonStyle(kind: .primary))
                }
                WaveformEditor(cue: show.doc.cue(cue.id) ?? cue, compact: false)
            }
            .padding(20)
            .frame(width: 1100)
            .background(Backdrop())
            .environmentObject(show)
            .environmentObject(show.live)
            .environmentObject(loc)
            .preferredColorScheme(.dark)
        }
    }

    // MARK: Canvas

    private func window(_ length: Double) -> (Double, Double) {
        let span = min(length, max(0.05, viewSpan ?? length))
        let start = min(max(0, viewStart), max(0, length - span))
        return (start, span)
    }

    private func canvas(length: Double) -> some View {
        GeometryReader { geo in
            let (v0, span) = window(length)
            let pps = Double(geo.size.width) / span
            let x = { (t: Double) -> CGFloat in CGFloat((t - v0) * pps) }
            let t = { (x: CGFloat) -> Double in v0 + Double(x) / pps }
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in draw(&ctx, size: size, length: length, v0: v0, span: span) }
                if let a = show.audition, a.cue == cue.id {
                    TimelineView(.animation) { tl in
                        let pos = a.from + tl.date.timeIntervalSince(a.startedAt) * a.rate
                        Rectangle().fill(Theme.textPrimary).frame(width: 2)
                            .offset(x: x(min(pos, a.from + a.length)))
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if dragHandle == nil {
                            dragHandle = handle(at: g.startLocation, x: x, height: geo.size.height)
                            draft = cue.audio
                            panOrigin = v0
                            if dragHandle == .envelopeNew {
                                // A click on the volume line adds a control point there (integrated fade).
                                dragHandle = addEnvelopePoint(time: t(g.startLocation.x), length: length)
                            }
                        }
                        apply(dragHandle, time: t(g.location.x), dx: g.translation.width, pps: pps, length: length,
                              y: g.location.y, height: geo.size.height)
                    }
                    .onEnded { g in
                        if case let .envelope(i)? = dragHandle {
                            // ⌥-click on a point removes it; anything else keeps what was drawn.
                            if NSEvent.modifierFlags.contains(.option), abs(g.translation.width) < 3, abs(g.translation.height) < 3 {
                                draft?.envelope?.points.remove(at: i)
                            }
                            if let d = draft { show.updateCue(cue.id) { $0.audio = d } }
                        } else if abs(g.translation.width) < 3 && abs(g.translation.height) < 3 {
                            // A click: listen from here.
                            show.audition(cue, from: max(0, min(length, t(g.location.x))))
                        } else if dragHandle != .pan, let d = draft {
                            show.updateCue(cue.id) { $0.audio = d }
                        }
                        dragHandle = nil
                        draft = nil
                        panOrigin = nil
                    }
            )
            .task(id: "\(path ?? "")|\(v0)|\(span)|\(Int(geo.size.width))") {
                guard let path else { return }
                let key = "\(path)|\(v0)|\(span)|\(Int(geo.size.width))"
                if let d = await show.waveSlice(path: path, from: v0, to: v0 + span, buckets: max(50, Int(geo.size.width / 2))) {
                    detail = d
                    detailKey = key
                }
            }
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.3)))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    // MARK: Integrated fade (volume line)

    private var envelopeOn: Bool { params.envelope?.enabled == true }

    /// File seconds the envelope's 0…1 runs over (the cue's start…end when locked, else the whole file).
    private func envelopeSpan(_ length: Double) -> (Double, Double) {
        let a = params
        guard a.envelope?.lockToRegion ?? true else { return (0, length) }
        return (a.start, max(a.start + 0.001, a.end ?? length))
    }

    private static let envTop: CGFloat = 32
    private func envY(_ db: Double, height: CGFloat) -> CGFloat {
        let v = max(VolumeEnvelope.floorDB, min(0, db))
        return Self.envTop + CGFloat(v / VolumeEnvelope.floorDB) * (height - 22 - Self.envTop)
    }
    private func envDB(_ y: CGFloat, height: CGFloat) -> Double {
        let f = Double((y - Self.envTop) / max(1, height - 22 - Self.envTop))
        return ((max(0, min(1, f)) * VolumeEnvelope.floorDB) * 2).rounded() / 2
    }

    private func addEnvelopePoint(time: Double, length: Double) -> Handle {
        guard var a = draft ?? cue.audio else { return .pan }
        var env = a.envelope ?? VolumeEnvelope()
        let (s, e) = envelopeSpan(length)
        let u = max(0, min(1, (time - s) / (e - s)))
        let db = env.points.isEmpty ? 0 : env.db(at: u)
        env.points.append(.init(u: u, db: db <= showSilenceDB ? VolumeEnvelope.floorDB : db))
        env.points.sort { $0.u < $1.u }
        a.envelope = env
        draft = a
        return .envelope(env.points.firstIndex { $0.u == u } ?? 0)
    }

    /// Which handle a drag starting at `p` grabs. Fade handles live in the top strip.
    private func handle(at p: CGPoint, x: (Double) -> CGFloat, height: CGFloat) -> Handle {
        let a = params
        let len = length ?? 0
        let s = a.start, e = a.end ?? len
        if envelopeOn, let env = a.envelope {
            let (es, ee) = envelopeSpan(len)
            // A control point under the pointer…
            for (i, pt) in env.points.enumerated() {
                let px = x(es + pt.u * (ee - es)), py = envY(pt.db, height: height)
                if abs(px - p.x) <= 8 && abs(py - p.y) <= 8 { return .envelope(i) }
            }
        }
        var candidates: [(Handle, CGFloat)] = []
        if p.y < 24 {
            candidates += [(.fadeIn, x(s + a.fadeIn)), (.fadeOut, x(e - a.fadeOut))]
        }
        if let ls = a.loopStart, let le = a.loopEnd, p.y > height - 26 {
            candidates += [(.loopStart, x(ls)), (.loopEnd, x(le))]
        }
        candidates += [(.start, x(s)), (.end, x(e))]
        let best = candidates.min { abs($0.1 - p.x) < abs($1.1 - p.x) }
        if let best, abs(best.1 - p.x) <= 12 { return best.0 }
        // …or the volume line itself: a new point.
        if envelopeOn, let env = a.envelope {
            let (es, ee) = envelopeSpan(len)
            let tt = (Double(p.x) - Double(x(0))) / Double(x(1) - x(0))
            if tt >= es && tt <= ee, abs(envY(env.db(at: (tt - es) / (ee - es)), height: height) - p.y) <= 8 { return .envelopeNew }
        }
        return .pan
    }

    private func apply(_ h: Handle?, time: Double, dx: CGFloat, pps: Double, length: Double, y: CGFloat = 0, height: CGFloat = 1) {
        guard var a = draft ?? cue.audio else { return }
        if case let .envelope(i)? = h, var env = a.envelope, env.points.indices.contains(i) {
            // Between its neighbours, so the points keep their order.
            let (s, e) = envelopeSpan(length)
            let lo = i > 0 ? env.points[i - 1].u + 0.0005 : 0
            let hi = i + 1 < env.points.count ? env.points[i + 1].u - 0.0005 : 1
            env.points[i].u = max(lo, min(hi, (time - s) / (e - s)))
            env.points[i].db = envDB(y, height: height)
            a.envelope = env
            draft = a
            return
        }
        let t = (max(0, min(length, time)) * 1000).rounded() / 1000
        let e = a.end ?? length
        switch h {
        case .start?: a.start = min(t, e - 0.01)
        case .end?: a.end = t >= length - 0.001 ? nil : max(t, a.start + 0.01)
        case .fadeIn?: a.fadeIn = max(0, min(t - a.start, e - a.start))
        case .fadeOut?: a.fadeOut = max(0, min(e - t, e - a.start))
        case .loopStart?: if let le = a.loopEnd { a.loopStart = max(a.start, min(t, le - 0.01)) }
        case .loopEnd?: if let ls = a.loopStart { a.loopEnd = min(e, max(t, ls + 0.01)) }
        case .pan?:
            if let o = panOrigin, viewSpan != nil { viewStart = max(0, o - Double(dx) / pps) }
            return
        case .envelope?, .envelopeNew?, nil: return
        }
        draft = a
    }

    private func draw(_ ctx: inout GraphicsContext, size: CGSize, length: Double, v0: Double, span: Double) {
        let a = params
        let pps = Double(size.width) / span
        func x(_ t: Double) -> CGFloat { CGFloat((t - v0) * pps) }
        let s = a.start, e = a.end ?? length
        let mid = size.height / 2
        let half = size.height * 0.42

        // Waveform: detailed slice when ready, otherwise the file overview.
        var p = Path()
        let cols = max(1, Int(size.width / 2))
        let overview = path.flatMap { show.waveforms[$0] } ?? []
        for k in 0..<cols {
            let px = CGFloat(k) * 2
            var v: Float = 0
            if let d = detail, !d.isEmpty, detailKey.hasSuffix("|\(Int(size.width))") {
                v = d[min(d.count - 1, k * d.count / cols)]
            } else if !overview.isEmpty {
                let tt = v0 + Double(px) / pps
                v = overview[min(overview.count - 1, max(0, Int(tt / length * Double(overview.count))))]
            }
            let h = CGFloat(v) * half
            p.move(to: CGPoint(x: px, y: mid - h)); p.addLine(to: CGPoint(x: px, y: mid + max(0.5, h)))
        }
        ctx.stroke(p, with: .color(Theme.accent.opacity(0.8)), lineWidth: 1)

        // Outside the region: dimmed.
        ctx.fill(Path(CGRect(x: 0, y: 0, width: max(0, x(s)), height: size.height)), with: .color(Color.black.opacity(0.55)))
        ctx.fill(Path(CGRect(x: x(e), y: 0, width: max(0, size.width - x(e)), height: size.height)), with: .color(Color.black.opacity(0.55)))

        // Inner loop.
        if let ls = a.loopStart, let le = a.loopEnd {
            let r = CGRect(x: x(ls), y: 0, width: max(1, x(le) - x(ls)), height: size.height)
            ctx.fill(Path(r), with: .color(Theme.dataBlue.opacity(0.12)))
            ctx.fill(Path(CGRect(x: r.minX, y: size.height - 18, width: r.width, height: 18)), with: .color(Theme.dataBlue.opacity(0.35)))
            for lx in [r.minX, r.maxX] {
                var l = Path(); l.move(to: CGPoint(x: lx, y: 0)); l.addLine(to: CGPoint(x: lx, y: size.height))
                ctx.stroke(l, with: .color(Theme.dataBlue), lineWidth: 1.5)
            }
            let label = a.plays == 0 ? "∞" : "×\(a.plays)"
            ctx.draw(Text(loc.t("show.wave.loop") + " " + label).font(.system(size: 10, weight: .semibold)).foregroundColor(Theme.textPrimary),
                     at: CGPoint(x: r.midX, y: size.height - 9))
        }

        // Fades: the gain curve over the waveform, handles in the top strip.
        var curve = Path()
        curve.move(to: CGPoint(x: x(s), y: size.height))
        curve.addLine(to: CGPoint(x: x(s + a.fadeIn), y: 8))
        curve.addLine(to: CGPoint(x: x(e - a.fadeOut), y: 8))
        curve.addLine(to: CGPoint(x: x(e), y: size.height))
        ctx.stroke(curve, with: .color(Theme.signalYellow.opacity(0.85)), lineWidth: 1.3)
        for hx in [x(s + a.fadeIn), x(e - a.fadeOut)] {
            ctx.fill(Path(ellipseIn: CGRect(x: hx - 5, y: 3, width: 10, height: 10)), with: .color(Theme.signalYellow))
        }

        // Integrated fade: the volume line (0 dB at the top) and its control points.
        if let env = a.envelope, env.enabled {
            let (es, ee) = envelopeSpan(length)
            var line = Path()
            var started = false
            var px: CGFloat = max(0, x(es))
            while px <= min(size.width, x(ee)) {
                let tt = v0 + Double(px) / pps
                let pt = CGPoint(x: px, y: envY(env.db(at: (tt - es) / (ee - es)), height: size.height))
                if started { line.addLine(to: pt) } else { line.move(to: pt); started = true }
                px += 2
            }
            ctx.stroke(line, with: .color(Theme.signalYellow), lineWidth: 2)
            for pt in env.points {
                let c = CGPoint(x: x(es + pt.u * (ee - es)), y: envY(pt.db, height: size.height))
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)), with: .color(Theme.signalYellow))
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)), with: .color(.black.opacity(0.5)), lineWidth: 1)
            }
        }

        // Start / end flags.
        for (fx, isStart) in [(x(s), true), (x(e), false)] {
            var l = Path(); l.move(to: CGPoint(x: fx, y: 0)); l.addLine(to: CGPoint(x: fx, y: size.height))
            ctx.stroke(l, with: .color(Theme.accent), lineWidth: 2)
            var flag = Path()
            let w: CGFloat = isStart ? 12 : -12
            flag.move(to: CGPoint(x: fx, y: size.height - 2)); flag.addLine(to: CGPoint(x: fx + w, y: size.height - 9))
            flag.addLine(to: CGPoint(x: fx, y: size.height - 16)); flag.closeSubpath()
            ctx.fill(flag, with: .color(Theme.accent))
        }

        // Time ticks.
        let steps: [Double] = [0.01, 0.05, 0.1, 0.5, 1, 2, 5, 10, 30, 60, 120]
        let step = steps.first { $0 * pps >= 70 } ?? 300
        var tt = (v0 / step).rounded(.up) * step
        while tt < v0 + span {
            ctx.draw(Text(showTime(tt)).font(.system(size: 9, design: .monospaced)).foregroundColor(Theme.textMuted),
                     at: CGPoint(x: x(tt) + 3, y: 22), anchor: .leading)
            var l = Path(); l.move(to: CGPoint(x: x(tt), y: 16)); l.addLine(to: CGPoint(x: x(tt), y: 28))
            ctx.stroke(l, with: .color(Color.white.opacity(0.15)), lineWidth: 1)
            tt += step
        }
    }

    // MARK: Controls

    /// "Integrated fade" under the waveform: on / off, curve type, lock to start / end, reset.
    @ViewBuilder private var envelopeControls: some View {
        let env = params.envelope
        HStack(spacing: 10) {
            Toggle(loc.t("show.env.on"), isOn: Binding(get: { env?.enabled == true }, set: { on in
                show.updateCue(cue.id) { c in
                    if c.audio?.envelope == nil { c.audio?.envelope = VolumeEnvelope() }
                    c.audio?.envelope?.enabled = on
                }
            }))
            .help(loc.t("show.env.help"))
            if env?.enabled == true {
                Picker("", selection: Binding(get: { env?.smooth ?? true }, set: { v in show.updateCue(cue.id) { $0.audio?.envelope?.smooth = v } })) {
                    Text(loc.t("show.env.smooth")).tag(true)
                    Text(loc.t("show.env.linear")).tag(false)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Toggle(loc.t("show.env.lock"), isOn: Binding(get: { env?.lockToRegion ?? true },
                                                              set: { v in show.updateCue(cue.id) { $0.audio?.envelope?.lockToRegion = v } }))
                Button(loc.t("show.env.reset")) { show.updateCue(cue.id) { $0.audio?.envelope?.points = [] } }
                    .buttonStyle(ToolButtonStyle())
                    .disabled(env?.points.isEmpty ?? true)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        if env?.enabled == true {
            Text(loc.t("show.env.hint")).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func transport(length: Double) -> some View {
        let a = params
        let playing = show.audition?.cue == cue.id
        let e = a.end ?? length
        return HStack(spacing: 6) {
            Button { playing ? show.stopAudition() : show.audition(cue, from: a.start) } label: {
                Label(loc.t(playing ? "show.wave.stop" : "show.wave.play"), systemImage: playing ? "stop.fill" : "play.fill").fixedSize()
            }
            .buttonStyle(ToolButtonStyle())
            Button { show.audition(cue, from: max(a.start, e - 3)) } label: {
                Label(loc.t("show.wave.end"), systemImage: "forward.end").fixedSize()
            }
            .buttonStyle(ToolButtonStyle())
            .help(loc.t("show.wave.end.help"))
            Button { show.trimSilence(cue.id) } label: { Label(loc.t("show.wave.trim"), systemImage: "scissors").fixedSize() }
                .buttonStyle(ToolButtonStyle())
                .help(loc.t("show.wave.trim.help"))
            Spacer(minLength: 0)
            Button { zoom(0.5, length: length) } label: { Image(systemName: "plus.magnifyingglass") }.buttonStyle(.borderless)
            Button { zoom(2, length: length) } label: { Image(systemName: "minus.magnifyingglass") }.buttonStyle(.borderless)
            if compact {
                Button { showFull = true } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(.borderless).help(loc.t("show.wave.expand"))
            }
        }
        .font(.system(size: 12))
    }

    private func zoom(_ factor: Double, length: Double) {
        let (v0, span) = window(length)
        let center = v0 + span / 2
        let newSpan = min(length, max(0.05, span * factor))
        viewSpan = newSpan >= length ? nil : newSpan
        viewStart = max(0, center - newSpan / 2)
    }

    private func fields(length: Double) -> some View {
        let cols = compact ? 2 : 4
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: cols), alignment: .leading, spacing: 8) {
            number(loc.t("show.start"), get: { $0.start }, set: { $0.start = max(0, $1) })
            number(loc.t("show.wave.endField"), get: { $0.end ?? length }, set: { $0.end = $1 >= length - 0.001 ? nil : max(0, $1) })
            number(loc.t("show.fadeIn"), get: { $0.fadeIn }, set: { $0.fadeIn = max(0, $1) })
            number(loc.t("show.fadeOut"), get: { $0.fadeOut }, set: { $0.fadeOut = max(0, $1) })
        }
    }

    private func loopControls(length: Double) -> some View {
        let a = params
        let mode: Int = a.loopStart != nil ? 2 : (a.plays == 1 ? 0 : 1)
        return VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: Binding(get: { mode }, set: { m in
                show.updateCue(cue.id) { c in
                    guard var p = c.audio else { return }
                    switch m {
                    case 0: p.loopStart = nil; p.loopEnd = nil; p.plays = 1
                    case 1: p.loopStart = nil; p.loopEnd = nil; if p.plays == 1 { p.plays = 0 }
                    default:
                        let s = p.start, e = p.end ?? length
                        p.loopStart = ((s + (e - s) / 3) * 100).rounded() / 100
                        p.loopEnd = ((s + 2 * (e - s) / 3) * 100).rounded() / 100
                        if p.plays == 1 { p.plays = 0 }
                    }
                    c.audio = p
                }
            })) {
                Text(loc.t("show.wave.noLoop")).tag(0)
                Text(loc.t("show.wave.loopAll")).tag(1)
                Text(loc.t("show.wave.loopPart")).tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if mode != 0 {
                HStack(spacing: 8) {
                    Toggle("∞", isOn: Binding(get: { a.plays == 0 }, set: { v in show.updateCue(cue.id) { $0.audio?.plays = v ? 0 : 2 } }))
                        .toggleStyle(.button)
                    if a.plays != 0 {
                        Stepper(String(format: loc.t("show.wave.times"), a.plays),
                                value: Binding(get: { a.plays }, set: { v in show.updateCue(cue.id) { $0.audio?.plays = max(1, v) } }), in: 1...999)
                    }
                    Spacer()
                }
                if mode == 2 {
                    HStack(spacing: 8) {
                        number(loc.t("show.wave.loopStart"), get: { $0.loopStart ?? 0 }, set: { $0.loopStart = max($0.start, $1) })
                        number(loc.t("show.wave.loopEnd"), get: { $0.loopEnd ?? 0 }, set: { $0.loopEnd = $1 })
                    }
                    Text(loc.t("show.wave.loopPart.hint")).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.system(size: 12))
    }

    private func number(_ title: String, get: @escaping (AudioCueParams) -> Double,
                        set: @escaping (inout AudioCueParams, Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title + ", " + loc.t("show.sec")).font(.system(size: 11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            TextField("", value: Binding(get: { get(params) }, set: { v in
                show.updateCue(cue.id) { c in if var p = c.audio { set(&p, v); c.audio = p } }
            }), format: .number.precision(.fractionLength(0...3)))
            .textFieldStyle(.roundedBorder)
        }
    }
}
