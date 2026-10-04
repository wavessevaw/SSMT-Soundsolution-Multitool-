import Foundation

/// A mix bus as the guard sees it (monitor wedges and in-ears are buses on X32 / X Air).
public struct BusStrip: Equatable, Codable, Sendable, Identifiable {
    public var id: Int
    public var name: String
    public var faderDB: Double
    public var muted: Bool
    public init(id: Int, name: String = "", faderDB: Double = 0, muted: Bool = false) {
        self.id = id; self.name = name; self.faderDB = faderDB; self.muted = muted
    }

    /// Named like a stage monitor ("Mon 1", "Wedge", "IEM Vox", "Мон", "Монитор", "Ушки").
    public var looksLikeMonitor: Bool {
        let n = " " + name.lowercased() + " "
        return ["mon", "wedge", "iem", "ear", "foldback", "fb ", "sidefill", "мон", "ушк", "ушн", "прострел", "wdg"].contains { n.contains($0) }
    }
}

/// What the show guard did, for the log. Every correction is temporary and undone when it is no longer needed.
public enum GuardAction: Equatable, Codable, Sendable {
    case notch(channel: Int, frequency: Double, depthDB: Double)
    case notchReleased(channel: Int)
    case monitorDip(bus: Int, byDB: Double)
    case monitorRestored(bus: Int)
    case monitorHeld(bus: Int, belowDB: Double)
    case unmask(channel: Int, frequency: Double, offsetDB: Double)
    case unmaskReleased(channel: Int)
    case tonalHold(channel: Int, frequency: Double, offsetDB: Double)
    case tonalReleased(channel: Int)
    case yielded(channel: Int?, bus: Int?)
}

/// Show assistant: the engineer mixes, the guard backs them up without getting in the way.
///  - feedback in the hall (measurement mic): a narrow notch on the channel feeding it, released after a quiet while;
///  - a monitor loop on stage (bus meters, optional stage mic): the monitor bus is pulled down a reasonable step,
///    then brought back step by step when it stays quiet;
///  - mass scenes (choir, ensemble, orchestra over a lead): the ensemble's presence band is dipped a little so
///    the lead stays intelligible, and released when the scene ends;
///  - tonal drift (a singer eating the mic): a temporary low-mid hold against the soundcheck reference.
/// It never moves channel faders, keeps every correction within a few dB, and when the engineer touches a
/// parameter the guard is holding, it drops its correction and leaves that strip alone for a while.
public final class ShowGuard {
    public struct Settings: Sendable {
        public var maxEQOffsetDB = 3.0
        public var monitorStepDB = 3.0
        public var monitorMaxDipDB = 9.0
        /// Quiet time before a dip is released (s).
        public var holdSeconds = 8.0
        public var restoreStepDB = 1.0
        /// After the engineer touches a strip the guard keeps off it for this long (s).
        public var engineerHoldSeconds = 30.0
        /// For safety (a ringing monitor, feedback in the hall) the guard waits only this long after a touch.
        public var safetyHoldSeconds = 3.0
        /// Ensemble channels playing at once that make a "mass scene".
        public var massSceneMinActive = 4
        /// Quiet time before a feedback notch is released (s).
        public var notchReleaseSeconds = 180.0
        public init() {}
    }

    public var settings = Settings()
    public var character: MixCharacter
    /// Channel strips as the engineer set them (without the guard's corrections).
    public private(set) var base: [Int: ChannelStrip]
    public private(set) var buses: [Int: BusStrip]
    /// Soundcheck reference spectra per channel (one-third octaves), for tonal drift.
    public var references: [Int: [Double]] = [:]
    /// Lead channels to keep intelligible (default: channels recognised as lead vocals or speech).
    public var leads: Set<Int>
    public var monitorBuses: Set<Int>
    public private(set) var log: [(time: Double, action: GuardAction)] = []

    struct Offset {
        var band: Int; var original: StripEQBand; var gainDB: Double
        /// A flat band borrowed and moved to this frequency (bell, Q 1).
        var retune: Double? = nil
    }
    var notches: [Int: (offset: Offset, frequency: Double, last: Double)] = [:]
    var unmasks: [Int: Offset] = [:]
    var tonal: [Int: Offset] = [:]
    /// Monitor dips: where the engineer had the bus, how far it is pulled down, since when it is quiet, and when and
    /// at what bus level it was last pulled (to pull again at once if it keeps ringing).
    var dips: [Int: (original: Double, dipDB: Double, quietSince: Double?, at: Double, level: Double)] = [:]
    /// Highest fader a monitor bus may be brought back to: 1 dB under where it rang (until the engineer moves it).
    var safeMax: [Int: Double] = [:]
    var rangAt: [Int: Double] = [:]
    var hands: [Int: Double] = [:]          // channel → time the engineer last touched it
    var busHands: [Int: Double] = [:]
    /// Recent bus levels and summed input level, by time (the last 6 s).
    var busHistory: [Int: [(t: Double, v: Double)]] = [:]
    var inputHistory: [(t: Double, v: Double)] = []
    var drift: [Int: [Double]] = [:]          // EMA of bands per channel
    var previousBands: [Int: [(t: Double, b: [Double])]] = [:]  // the last three seconds' spectra per channel
    var lastMassScene = -1e9
    /// Time of the last slow step: tone, intelligibility and bringing things back run once a second; feedback and
    /// ringing monitors are handled at every step (4 a second in the app).
    var lastSlowStep = -1e9
    var slowAcc: [Int: (last: SignalFeatures, bands: [Double], n: Int, rms: Double, count: Int)] = [:]
    let kinds: [Int: SourceKind]

    public init(strips: [ChannelStrip], buses: [BusStrip], character: MixCharacter, sampleRate: Double = 48000) {
        self.character = character
        base = Dictionary(uniqueKeysWithValues: strips.map { ($0.id, $0) })
        self.buses = Dictionary(uniqueKeysWithValues: buses.map { ($0.id, $0) })
        let choirContext = strips.contains { SourceClassifier.kind(forName: $0.name) == .choir }
        var k: [Int: SourceKind] = [:]
        for s in strips { k[s.id] = SourceClassifier.kind(forName: s.name, choirContext: choirContext) ?? .unknown }
        kinds = k
        leads = Set(k.filter { [.maleVocal, .femaleVocal, .speech].contains($0.value) }.keys)
        monitorBuses = Set(buses.filter(\.looksLikeMonitor).map(\.id))
    }

    // MARK: what the console shows (base + guard corrections)

    public func strip(_ ch: Int) -> ChannelStrip? {
        guard var s = base[ch] else { return nil }
        for o in [notches[ch]?.offset, unmasks[ch], tonal[ch]].compactMap({ $0 }) where o.band < s.eq.count {
            if notches[ch]?.offset.band == o.band, let n = notches[ch] {
                s.eq[o.band] = StripEQBand(type: .peaking, frequency: n.frequency, gainDB: n.offset.gainDB, q: 8)
            } else if let f = o.retune {
                s.eq[o.band] = StripEQBand(type: .peaking, frequency: f, gainDB: o.gainDB, q: 1.0)
            } else {
                s.eq[o.band].gainDB = max(-15, min(15, s.eq[o.band].gainDB + o.gainDB))
            }
        }
        return s
    }

    public func bus(_ id: Int) -> BusStrip? {
        guard var b = buses[id] else { return nil }
        if let d = dips[id] { b.faderDB = d.original - d.dipDB }
        return b
    }

    /// A strip arrived from the console. If it differs from what the guard last sent, the engineer touched it:
    /// the guard drops its corrections there and stays away for a while.
    public func consoleChanged(_ s: ChannelStrip, time: Double) {
        guard let shown = strip(s.id) else { base[s.id] = s; return }
        if Self.same(shown, s) { return }
        // A fader ride or a mute is the engineer mixing, not taking over the channel's EQ: keep the corrections.
        var ride = shown
        ride.faderDB = s.faderDB
        ride.muted = s.muted
        if Self.same(ride, s) {
            base[s.id]?.faderDB = s.faderDB
            base[s.id]?.muted = s.muted
            return
        }
        base[s.id] = s
        hands[s.id] = time
        let had = notches[s.id] != nil || unmasks[s.id] != nil || tonal[s.id] != nil
        notches[s.id] = nil; unmasks[s.id] = nil; tonal[s.id] = nil
        if had { record(time, .yielded(channel: s.id, bus: nil)) }
    }

    public func consoleChanged(bus b: BusStrip, time: Double) {
        guard let shown = bus(b.id) else { buses[b.id] = b; return }
        if abs(shown.faderDB - b.faderDB) < 0.3 && shown.muted == b.muted { return }
        buses[b.id] = b
        busHands[b.id] = time
        safeMax[b.id] = nil
        rangAt[b.id] = nil
        if dips[b.id] != nil { dips[b.id] = nil; record(time, .yielded(channel: nil, bus: b.id)) }
    }

    /// Equal within what the console's parameter steps round to (an echo of our own change is not a touch).
    static func same(_ a: ChannelStrip, _ b: ChannelStrip) -> Bool {
        guard a.muted == b.muted, a.polarityInverted == b.polarityInverted, a.eqOn == b.eqOn, a.highPassOn == b.highPassOn, abs(a.faderDB - b.faderDB) < 0.3,
              abs(a.gainDB - b.gainDB) < 0.6, a.eq.count == b.eq.count else { return false }
        for (x, y) in zip(a.eq, b.eq) where x.type != y.type || abs(x.gainDB - y.gainDB) > 0.3
            || abs(log2(x.frequency / y.frequency)) > 0.05 || abs(log2(x.q / y.q)) > 0.1 { return false }
        return true
    }

    /// EQ bands of a channel the guard already uses.
    func used(_ ch: Int) -> Set<Int> {
        Set([notches[ch]?.offset.band, unmasks[ch]?.band, tonal[ch]?.band].compactMap { $0 })
    }

    func handsOff(_ ch: Int, _ t: Double) -> Bool { (hands[ch].map { t - $0 < settings.engineerHoldSeconds }) ?? false }
    func record(_ t: Double, _ a: GuardAction) { log.append((t, a)); if log.count > 500 { log.removeFirst(100) } }

    // MARK: step (4 a second in the app; anything from 1 a second works)

    /// - Parameters:
    ///   - time: seconds since the guard started.
    ///   - channels: features of the last second per channel (console meters / RTA or audio).
    ///   - busLevels: monitor bus meter levels (dBFS).
    ///   - hallFeedback / stageFeedback: events from the hall and (optional) stage measurement mics.
    /// - Returns: channel strips and buses whose console values changed.
    public func step(time t: Double, channels: [Int: SignalFeatures], busLevels: [Int: Double],
                     hallFeedback: [FeedbackDetector.Event] = [], stageFeedback: [FeedbackDetector.Event] = [])
        -> (strips: [ChannelStrip], buses: [BusStrip], actions: [GuardAction]) {
        let before = Dictionary(uniqueKeysWithValues: base.keys.compactMap { ch in strip(ch).map { (ch, $0) } })
        let busBefore = Dictionary(uniqueKeysWithValues: buses.keys.compactMap { id in bus(id).map { (id, $0) } })
        let mark = log.count

        let slow = t - lastSlowStep >= 1 - 1e-9
        if slow { lastSlowStep = t }
        // Tone and intelligibility judge a whole second: the spectra of the fast steps are averaged (power).
        for (k, f) in channels {
            var a = slowAcc[k] ?? (f, [Double](repeating: 0, count: f.bandsDB.count), 0, 0, 0)
            a.last = f
            if f.bandsDB.contains(where: { $0 > -119 }) {
                if a.bands.count != f.bandsDB.count { a.bands = [Double](repeating: 0, count: f.bandsDB.count); a.n = 0 }
                for i in f.bandsDB.indices { a.bands[i] += pow(10, f.bandsDB[i] / 10) }
                a.n += 1
            }
            a.rms += pow(10, f.rmsDB / 10)
            a.count += 1
            slowAcc[k] = a
        }
        var slowChannels: [Int: SignalFeatures] = [:]
        if slow {
            for (k, a) in slowAcc {
                var f = a.last
                if a.n > 0 { f.bandsDB = a.bands.map { Decibel.fromPower($0 / Double(a.n) + 1e-15) } }
                if a.count > 0 { f.rmsDB = Decibel.fromPower(a.rms / Double(a.count) + 1e-15) }
                slowChannels[k] = f
            }
            slowAcc.removeAll()
        }
        hall(t, channels, hallFeedback)
        for (k, f) in channels where f.bandsDB.contains(where: { $0 > -119 }) {
            previousBands[k, default: []].append((t, f.bandsDB))
            previousBands[k]!.removeAll { t - $0.t >= 3 - 1e-9 }
        }
        monitors(t, channels, busLevels, stageFeedback, slow: slow)
        if slow {
            massScene(t, slowChannels)
            tonalDrift(t, slowChannels)
        }

        let strips = base.keys.sorted().compactMap { ch -> ChannelStrip? in
            guard let s = strip(ch), s != before[ch] else { return nil }
            return s
        }
        let bs = buses.keys.sorted().compactMap { id -> BusStrip? in
            guard let b = bus(id), b != busBefore[id] else { return nil }
            return b
        }
        return (strips, bs, log[mark...].map(\.action))
    }

    /// Band the guard may borrow: the one nearest `f` that is nearly flat, else the nearest peaking band.
    func bandFor(_ s: ChannelStrip, near f: Double, allowRetune: Bool, exclude: Set<Int> = []) -> Int? {
        let idx = s.eq.indices.filter { !exclude.contains($0) }.sorted { abs(log2(s.eq[$0].frequency / f)) < abs(log2(s.eq[$1].frequency / f)) }
        if allowRetune, let flat = idx.first(where: { abs(s.eq[$0].gainDB) < 0.5 }) { return flat }
        return idx.first { s.eq[$0].type == .peaking && abs(log2(s.eq[$0].frequency / f)) < 0.75 }
    }

    // MARK: hall feedback → notch on the channel feeding it

    func hall(_ t: Double, _ ch: [Int: SignalFeatures], _ events: [FeedbackDetector.Event]) {
        for e in events {
            // The same howl dying away right after a fresh notch: neither deepen nor blame another channel. Still
            // howling 1.5 s later: the notch goes deeper.
            if notches.values.contains(where: { abs(log2($0.frequency / e.frequency)) < 1.0 / 6 && t - $0.last < 1.5 }) { continue }
            let b = ThirdOctave.index(of: e.frequency)
            let culprit = base.values.filter { !$0.muted && $0.faderDB > -60 && !((hands[$0.id].map { t - $0 < settings.safetyHoldSeconds }) ?? false) }
                .max { score($0, b, ch) < score($1, b, ch) }
            guard let s = culprit else { continue }
            if var n = notches[s.id], abs(log2(n.frequency / e.frequency)) < 1.0 / 6 {
                n.offset.gainDB = max(n.offset.gainDB - 3, -12)
                n.last = t
                notches[s.id] = n
                record(t, .notch(channel: s.id, frequency: n.frequency, depthDB: n.offset.gainDB))
            } else if notches[s.id].map({ t - $0.last > 10 }) ?? true,
                      let band = bandFor(s, near: e.frequency, allowRetune: true,
                                         exclude: used(s.id).subtracting([notches[s.id]?.offset.band].compactMap { $0 })) {
                // A new problem on this channel replaces an old notch that has been quiet for a while.
                notches[s.id] = (Offset(band: band, original: s.eq[band], gainDB: -4), (e.frequency * 10).rounded() / 10, t)
                unmasks[s.id] = unmasks[s.id]?.band == band ? nil : unmasks[s.id]
                tonal[s.id] = tonal[s.id]?.band == band ? nil : tonal[s.id]
                record(t, .notch(channel: s.id, frequency: e.frequency, depthDB: -4))
            }
        }
        for (ch, n) in notches where t - n.last > settings.notchReleaseSeconds {
            var m = n
            m.offset.gainDB += 1
            m.last = t - settings.notchReleaseSeconds + 10   // next step in 10 s
            if m.offset.gainDB >= 0 { notches[ch] = nil; record(t, .notchReleased(channel: ch)) } else { notches[ch] = m }
        }
    }

    /// The channel feeding a loop hears the howl in its own microphone: its energy at that frequency jumps.
    /// So the rise over the last seconds counts most; how loud the channel is sent to the room breaks ties.
    func score(_ s: ChannelStrip, _ band: Int, _ ch: [Int: SignalFeatures]) -> Double {
        let now = ch[s.id].map { $0.bandsDB[band] > -119 ? $0.bandsDB[band] : $0.rmsDB - 15 } ?? -100
        let before = previousBands[s.id]?.map { $0.b[band] }.filter { $0 > -119 }.min() ?? now
        return (now - before) + 0.2 * (now + s.faderDB)
    }

    // MARK: monitor loops → dip the bus, then bring it back

    func monitors(_ t: Double, _ ch: [Int: SignalFeatures], _ levels: [Int: Double], _ stage: [FeedbackDetector.Event],
                  slow: Bool = true) {
        let inputs = Decibel.fromPower(ch.values.filter(\.hasSignal).reduce(0) { $0 + pow(10, $1.rmsDB / 10) } + 1e-12)
        inputHistory.append((t, inputs))
        inputHistory.removeAll { t - $0.t >= 6 - 1e-9 }
        var looping: Set<Int> = []
        for id in monitorBuses {
            guard let l = levels[id] else { continue }
            var h = busHistory[id] ?? []
            h.append((t, l))
            h.removeAll { t - $0.t >= 6 - 1e-9 }
            busHistory[id] = h
            // Recent = the last ¾ s (at least the last two readings); before = what came earlier (≥ 1 s of history).
            let nRecent = max(2, h.filter { t - $0.t < 0.75 }.count)
            guard h.count >= nRecent + 2, t - h[0].t >= 1 - 1e-9 else { continue }
            let recent = h.suffix(nRecent).map(\.v), before = h.prefix(h.count - nRecent).map(\.v).min() ?? l
            let rise = (recent.min() ?? l) - before
            let steady = (recent.max() ?? l) - (recent.min() ?? l) < 1.5
            let inputBefore = inputHistory.prefix(max(1, inputHistory.count - nRecent)).map(\.v).min() ?? 0
            let inputRise = (inputHistory.last?.v ?? 0) - inputBefore
            // A loop: the bus jumps and holds a steady level that the inputs do not explain.
            if l > -30 && rise >= 8 && steady && inputRise < rise - 5 { looping.insert(id) }
        }
        // Pulled down half a second ago and not one dB quieter for it: still ringing — pull again now.
        for (id, d) in dips where t - d.at >= 0.5 - 1e-9 && t - d.at < 3 {
            if let l = levels[id], l > -30, l >= d.level - 1 { looping.insert(id) }
        }
        if !stage.isEmpty {
            // The stage mic heard it: blame the monitor bus that rose most recently, else the loudest.
            let rising = monitorBuses.max { a, b in
                let ra = (busHistory[a]?.last?.v ?? -120) - (busHistory[a]?.first?.v ?? -120)
                let rb = (busHistory[b]?.last?.v ?? -120) - (busHistory[b]?.first?.v ?? -120)
                return ra < rb
            }
            if let r = rising { looping.insert(r) }
        }
        for id in looping {
            guard let b = buses[id], !(busHands[id].map { t - $0 < settings.safetyHoldSeconds } ?? false) else { continue }
            var d = dips[id] ?? (b.faderDB, 0, nil, t, levels[id] ?? -120)
            guard d.dipDB < settings.monitorMaxDipDB else { continue }
            // First time: pull down and later bring it all the way back. If it rings again, it is the setting
            // itself: from then on it is only brought back to 1 dB under where it rang.
            let rang = d.original - d.dipDB
            if let first = rangAt[id] { safeMax[id] = min(safeMax[id] ?? .infinity, min(first, rang) - 1) } else { rangAt[id] = rang }
            d.dipDB = min(d.dipDB + settings.monitorStepDB, settings.monitorMaxDipDB)
            d.quietSince = nil
            d.at = t
            d.level = levels[id] ?? d.level
            dips[id] = d
            busHistory[id] = []
            record(t, .monitorDip(bus: id, byDB: d.dipDB))
        }
        for (id, var d) in dips where !looping.contains(id) {
            if d.quietSince == nil { d.quietSince = t }
            // Brought back 1 dB a second (on the slow steps), after `holdSeconds` of quiet.
            if slow, t - d.quietSince! >= settings.holdSeconds {
                let target = max(0, d.original - (safeMax[id] ?? d.original))
                if d.dipDB > target {
                    d.dipDB = max(target, d.dipDB - settings.restoreStepDB)
                    if d.dipDB <= 0 { dips[id] = nil; record(t, .monitorRestored(bus: id)); continue }
                    if d.dipDB <= target { record(t, .monitorHeld(bus: id, belowDB: d.dipDB)) }
                }
            }
            dips[id] = d
        }
    }

    // MARK: mass scenes → keep the lead intelligible

    func massScene(_ t: Double, _ ch: [Int: SignalFeatures]) {
        guard character != .classical else { releaseUnmasks(t); return }
        let margin: Double = character == .speech ? 8 : character == .rock ? 3 : 5
        let ensemble = base.keys.filter { k in
            guard let kind = kinds[k], !leads.contains(k) else { return false }
            return kind == .choir || kind == .backingVocal || kind.isOrchestral
        }
        let activeEns = ensemble.filter { ch[$0]?.hasSignal == true && !(base[$0]?.muted ?? true) }
        let activeLeads = leads.filter { ch[$0]?.hasSignal == true && !(base[$0]?.muted ?? true) }
        let presence = ThirdOctave.centers.indices.filter { (1600...5000).contains(ThirdOctave.centers[$0]) }
        func presenceLevel(_ k: Int) -> Double {
            guard let f = ch[k], let s = base[k] else { return -200 }
            let p = presence.map { f.bandsDB[$0] }.filter { $0 > -119 }
            let raw = p.isEmpty ? f.rmsDB - 8 : Decibel.fromPower(p.reduce(0) { $0 + pow(10, $1 / 10) })
            return raw + s.faderDB
        }
        if activeEns.count >= settings.massSceneMinActive, !activeLeads.isEmpty {
            lastMassScene = t
            let lead = activeLeads.map(presenceLevel).max() ?? -200
            let ens = Decibel.fromPower(activeEns.reduce(0) { $0 + pow(10, presenceLevel($1) / 10) })
            if lead - ens < margin {
                for k in activeEns where !handsOff(k, t) {
                    guard let s = base[k] else { continue }
                    var o = unmasks[k] ?? {
                        guard let band = bandFor(s, near: 3000, allowRetune: false, exclude: used(k)) else { return nil }
                        return Offset(band: band, original: s.eq[band], gainDB: 0)
                    }() ?? Offset(band: -1, original: StripEQBand(frequency: 3000), gainDB: 0)
                    guard o.band >= 0, o.gainDB > -settings.maxEQOffsetDB else { continue }
                    o.gainDB = max(o.gainDB - 1, -settings.maxEQOffsetDB)
                    unmasks[k] = o
                    record(t, .unmask(channel: k, frequency: s.eq[o.band].frequency, offsetDB: o.gainDB))
                }
            }
        } else if t - lastMassScene > 4 {
            releaseUnmasks(t)
        }
    }

    func releaseUnmasks(_ t: Double) {
        for (k, var o) in unmasks {
            o.gainDB = min(0, o.gainDB + settings.restoreStepDB)
            if o.gainDB >= 0 { unmasks[k] = nil; record(t, .unmaskReleased(channel: k)) } else { unmasks[k] = o }
        }
    }

    // MARK: tonal drift → hold the low-mids against the soundcheck reference

    func tonalDrift(_ t: Double, _ ch: [Int: SignalFeatures]) {
        let lowMid = ThirdOctave.centers.indices.filter { (160...400).contains(ThirdOctave.centers[$0]) }
        let body = ThirdOctave.centers.indices.filter { (800...3150).contains(ThirdOctave.centers[$0]) }
        for (k, ref) in references {
            guard let f = ch[k], f.hasSignal, f.bandsDB.contains(where: { $0 > -119 }), let s = base[k], !handsOff(k, t) else { continue }
            var e = drift[k] ?? f.bandsDB
            for i in e.indices { e[i] = 0.8 * e[i] + 0.2 * f.bandsDB[i] }
            drift[k] = e
            func tilt(_ b: [Double]) -> Double {
                lowMid.map { b[$0] }.reduce(0, +) / Double(lowMid.count) - body.map { b[$0] }.reduce(0, +) / Double(body.count)
            }
            let excess = tilt(e) - tilt(ref)
            if excess > 4 {
                var o = tonal[k] ?? {
                    guard let band = bandFor(s, near: 250, allowRetune: true, exclude: used(k)) else { return nil }
                    let flat = abs(s.eq[band].gainDB) < 0.5
                    return Offset(band: band, original: s.eq[band], gainDB: 0, retune: flat ? 250 : nil)
                }() ?? Offset(band: -1, original: StripEQBand(frequency: 250), gainDB: 0)
                guard o.band >= 0, o.gainDB > -settings.maxEQOffsetDB else { continue }
                o.gainDB = max(o.gainDB - 1, -settings.maxEQOffsetDB)
                tonal[k] = o
                record(t, .tonalHold(channel: k, frequency: o.retune ?? s.eq[o.band].frequency, offsetDB: o.gainDB))
            } else if excess < 2, var o = tonal[k] {
                o.gainDB = min(0, o.gainDB + settings.restoreStepDB)
                if o.gainDB >= 0 { tonal[k] = nil; record(t, .tonalReleased(channel: k)) } else { tonal[k] = o }
            }
        }
    }

    /// Everything the guard is holding, undone (when the guard is switched off).
    public func releaseAll() -> (strips: [ChannelStrip], buses: [BusStrip]) {
        let chans = Set(notches.keys).union(unmasks.keys).union(tonal.keys)
        let bs = Array(dips.keys)
        notches.removeAll(); unmasks.removeAll(); tonal.removeAll(); dips.removeAll(); safeMax.removeAll(); rangAt.removeAll()
        return (chans.sorted().compactMap { strip($0) }, bs.sorted().compactMap { bus($0) })
    }

    public var activeCorrections: Int { notches.count + unmasks.count + tonal.count + dips.count }

    /// One correction the guard is holding right now (for the "active corrections" list).
    public struct Correction: Equatable, Sendable, Identifiable {
        public enum Kind: String, Sendable { case notch, unmask, tonal, monitorDip }
        public var kind: Kind
        /// Channel (EQ corrections) or bus (monitor dips).
        public var target: Int
        public var frequency: Double?
        /// Size of the correction (dB, negative = cut / lower).
        public var amountDB: Double
        /// For a monitor dip: seconds left before it starts coming back (nil while the loop is still there).
        public var restoreInSeconds: Double?
        public var id: String { "\(kind.rawValue)-\(target)" }
    }

    /// What the guard holds at time `t`, monitor dips first.
    public func corrections(at t: Double) -> [Correction] {
        var out: [Correction] = []
        for (id, d) in dips.sorted(by: { $0.key < $1.key }) {
            let left = d.quietSince.map { max(0, settings.holdSeconds - (t - $0)) }
            out.append(Correction(kind: .monitorDip, target: id, frequency: nil, amountDB: -d.dipDB, restoreInSeconds: left))
        }
        for (ch, n) in notches.sorted(by: { $0.key < $1.key }) {
            out.append(Correction(kind: .notch, target: ch, frequency: n.frequency, amountDB: n.offset.gainDB, restoreInSeconds: nil))
        }
        for (ch, o) in unmasks.sorted(by: { $0.key < $1.key }) {
            out.append(Correction(kind: .unmask, target: ch, frequency: base[ch].map { $0.eq.indices.contains(o.band) ? $0.eq[o.band].frequency : 3000 }, amountDB: o.gainDB, restoreInSeconds: nil))
        }
        for (ch, o) in tonal.sorted(by: { $0.key < $1.key }) {
            out.append(Correction(kind: .tonal, target: ch, frequency: o.retune ?? base[ch].map { $0.eq.indices.contains(o.band) ? $0.eq[o.band].frequency : 250 }, amountDB: o.gainDB, restoreInSeconds: nil))
        }
        return out
    }

    /// The engineer cancels one correction from the list: it is undone at once and the guard leaves that
    /// channel or bus alone as if the engineer had touched it. Returns what to send to the console.
    public func cancel(_ id: String, time: Double) -> (strips: [ChannelStrip], buses: [BusStrip]) {
        let parts = id.split(separator: "-")
        guard parts.count == 2, let kind = Correction.Kind(rawValue: String(parts[0])), let target = Int(parts[1]) else { return ([], []) }
        switch kind {
        case .monitorDip:
            guard dips[target] != nil else { return ([], []) }
            dips[target] = nil
            safeMax[target] = nil
            rangAt[target] = nil
            busHands[target] = time
            record(time, .yielded(channel: nil, bus: target))
            return ([], bus(target).map { [$0] } ?? [])
        case .notch: notches[target] = nil
        case .unmask: unmasks[target] = nil
        case .tonal: tonal[target] = nil
        }
        hands[target] = time
        record(time, .yielded(channel: target, bus: nil))
        return (strip(target).map { [$0] } ?? [], [])
    }
}
