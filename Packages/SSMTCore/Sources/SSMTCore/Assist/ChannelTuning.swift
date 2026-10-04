import Foundation

/// What the assistant did or saw on a channel during one step. The UI turns these into sentences.
public enum AssistNote: Equatable, Codable, Sendable {
    case waitingForSignal
    case recognised(SourceKind, confidence: Double)
    case gain(fromDB: Double, toDB: Double)
    case clipRisk(peakDB: Double)
    case highPass(hz: Double)
    case eqBand(index: Int, type: EQBandType, frequency: Double, gainDB: Double, q: Double)
    case compressor(thresholdDB: Double, ratio: Double, attackMS: Double, releaseMS: Double, gainReductionDB: Double)
    case compressorOff
    case fader(toDB: Double)
    case feedback(frequency: Double, notchDB: Double)
    case polarityChecking(against: Int)
    /// Result of the polarity check: kept or inverted, and how much fuller the sum is in that position (dB).
    case polarity(inverted: Bool, differenceDB: Double)
    case polarityUnclear(differenceDB: Double)
    case done(remainingDeviationDB: Double)
    case gaveUp(reason: String)
}

public enum TuningState: String, Codable, Sendable {
    case idle, listening, tuning, done
}

/// Per-channel auto-tuning: called every analysis window (≈ 2 s) with what the computer heard on the
/// channel; returns the strip to send to the console. Order of work in each step:
///  1. gain staging (nothing else changes while the gain moves: the picture would be stale);
///  2. high-pass from the source profile and the lowest pitch actually played;
///  3. tonal EQ: long-term spectrum vs. the source's target, fitted with the four console bands,
///     moved at most 2 dB per step;
///  4. compression from the measured level distribution.
/// The channel is ready when two consecutive steps change less than 0.5 dB.
public struct ChannelTuning: Sendable {
    public let channel: Int
    public var kind: SourceKind
    public var character: MixCharacter
    public var tap: TapPoint
    public private(set) var state: TuningState = .idle
    public private(set) var steps = 0
    /// Remaining tonal deviation after the EQ (dB RMS over the working band).
    public private(set) var deviationDB: Double = 0
    /// Bands held for feedback notches (not touched by the tonal EQ).
    public var reservedBands: Set<Int> = []
    /// Kind was given by the user: do not re-classify.
    public var kindLocked = false

    /// Target for loud passages at the tap point (dBFS, 95th percentile of 50 ms levels).
    public var targetLevelDB = -14.0
    /// Highest acceptable sample peak (dBFS).
    public var peakCeilingDB = -4.0
    public var maxSteps = 25

    var averager = FeatureAverager()
    var stable = 0
    var silent = 0
    var name: String

    public init(channel: Int, name: String, kind: SourceKind? = nil, character: MixCharacter, tap: TapPoint = .preEQ) {
        self.channel = channel
        self.name = name
        self.kind = kind ?? SourceClassifier.kind(forName: name) ?? .unknown
        self.kindLocked = kind != nil
        self.character = character
        self.tap = tap
    }

    public var profile: ToneProfile { ToneProfile.profile(for: kind, character: character) }

    /// One step. `features` were measured at the tap point with `strip` applied on the console.
    public mutating func step(features measured: SignalFeatures, strip: ChannelStrip, choirContext: Bool = false) -> (ChannelStrip, [AssistNote]) {
        guard state != .done else { return (strip, []) }
        steps += 1
        var notes: [AssistNote] = []
        var s = strip
        if steps > maxSteps {
            state = .done
            return (s, [.gaveUp(reason: averager.windows == 0 ? "no signal" : "did not settle"), .done(remainingDeviationDB: deviationDB)])
        }
        guard measured.hasSignal else {
            silent += 1
            state = .listening
            steps -= 1   // waiting does not count towards the step limit
            return (s, [.waitingForSignal])
        }
        state = .tuning

        // Remove what the console already does so the averager sees the source itself.
        var raw = measured
        let gainRef = strip.gainDB
        if tap == .postEQ {
            raw.bandsDB = zip(ThirdOctave.centers, measured.bandsDB).map { f, d in d - strip.filterResponseDB(at: f) }
        }
        // Gain-independent levels (dB re. preamp gain).
        raw.rmsDB -= gainRef; raw.peakDB -= gainRef; raw.level50DB -= gainRef; raw.level95DB -= gainRef
        raw.bandsDB = raw.bandsDB.map { $0 - gainRef }

        if !kindLocked && steps <= 3 {
            averager.add(raw)
            if let avg = averager.average {
                var withGain = avg
                withGain.rmsDB += gainRef
                let r = SourceClassifier.classify(name: name, features: measured, choirContext: choirContext)
                if r.kind != .unknown && r.kind != kind { kind = r.kind; notes.append(.recognised(r.kind, confidence: r.confidence)) }
                else if steps == 1 { notes.append(.recognised(kind, confidence: r.confidence)) }
            }
        } else {
            averager.add(raw)
        }
        guard let avg = averager.average else { return (s, notes) }
        let p = profile
        var change = 0.0

        // 1. Gain staging.
        let loud = avg.level95DB + s.gainDB
        let peak = measured.peakDB
        var wantGain = s.gainDB + (targetLevelDB - loud)
        if peak + (wantGain - s.gainDB) > peakCeilingDB { wantGain = s.gainDB + (peakCeilingDB - peak) }
        let dg = wantGain - s.gainDB
        if abs(dg) > 1.5 {
            let stepDB = (min(max(dg, -6), 6) * 2).rounded() / 2
            let newGain = min(max(s.gainDB + stepDB, -12), 60)
            if newGain != s.gainDB {
                notes.append(.gain(fromDB: s.gainDB, toDB: newGain))
                if measured.peakDB > -1 { notes.append(.clipRisk(peakDB: measured.peakDB)) }
                change = max(change, abs(newGain - s.gainDB))
                s.gainDB = newGain
                stable = 0
                return (s, notes)
            }
        }

        // 2. High-pass: the profile's point, but never above the lowest note actually played.
        if p.highPassHz > 0 {
            var hp = p.highPassHz
            if avg.pitchHz > 0 && avg.harmonicity > 0.4 { hp = min(hp, avg.pitchHz * 0.7) }
            hp = (hp / 5).rounded() * 5
            if !s.highPassOn || abs(log2(s.highPassHz / hp)) > 0.1 {
                s.highPassOn = true
                s.highPassHz = hp
                notes.append(.highPass(hz: hp))
                change = max(change, 1)
            }
        }

        // 3. Tonal EQ once the long-term picture has at least two windows.
        if averager.windows >= 2 && !p.target.isEmpty {
            let ideal = Self.idealEQ(bands: avg.bandsDB, profile: p, character: character, highPassHz: s.highPassOn ? s.highPassHz : 0,
                                     current: s.eq, reserved: reservedBands)
            deviationDB = ideal.residualDB
            s.eqOn = true
            for (i, b) in ideal.bands.enumerated() where !reservedBands.contains(i) && i < s.eq.count {
                var nb = s.eq[i]
                let move = min(max(b.gainDB - nb.gainDB, -2), 2)
                if b.type != nb.type || abs(log2(b.frequency / nb.frequency)) > 0.05 || abs(b.q - nb.q) > 0.05 {
                    // Retune the band only while it is nearly flat, so no audible jump.
                    if abs(nb.gainDB) <= 1.0 { nb.type = b.type; nb.frequency = b.frequency; nb.q = b.q }
                    else { nb.gainDB -= min(max(nb.gainDB, -2), 2); change = max(change, 1); s.eq[i] = nb; continue }
                }
                nb.gainDB = ((nb.gainDB + move) * 4).rounded() / 4
                if abs(nb.gainDB - s.eq[i].gainDB) > 0.01 || nb.frequency != s.eq[i].frequency {
                    change = max(change, abs(nb.gainDB - s.eq[i].gainDB))
                    notes.append(.eqBand(index: i, type: nb.type, frequency: nb.frequency, gainDB: nb.gainDB, q: nb.q))
                }
                s.eq[i] = nb
            }
        }

        // 4. Compression from the level distribution at the tap (after the new gain).
        if averager.windows >= 2 {
            let l95 = avg.level95DB + s.gainDB
            let gr = p.gainReductionDB
            if gr < 1 {
                // Only the assistant's compressor is switched off; an expander the engineer set stays.
                if s.compressor.compressing { s.compressor.enabled = false; notes.append(.compressorOff); change = max(change, 1) }
            } else {
                let ratio = X32Codec.ratios[X32Codec.ratioIndex(p.ratio)]
                let thr = (min(max(l95 - gr / (1 - 1 / ratio), -60), 0) * 2).rounded() / 2
                // Release follows the playing: faster for busy parts, slower for long notes.
                var rel = p.releaseMS
                if avg.onsetRate > 0.5 { rel = min(max(rel, 1000 * 0.35 / avg.onsetRate), rel * 2) }
                rel = min(max(rel, 40), 600).rounded()
                var c = s.compressor
                c.enabled = true; c.expander = false; c.ratio = ratio; c.attackMS = p.attackMS; c.releaseMS = rel; c.kneeDB = 2
                c.makeupDB = ((gr * 0.5) * 2).rounded() / 2
                let dThr = thr - c.thresholdDB
                c.thresholdDB = s.compressor.compressing ? c.thresholdDB + min(max(dThr, -3), 3) : thr
                if c != s.compressor {
                    change = max(change, abs(c.thresholdDB - s.compressor.thresholdDB), s.compressor.compressing ? 0 : 1)
                    notes.append(.compressor(thresholdDB: c.thresholdDB, ratio: c.ratio, attackMS: c.attackMS, releaseMS: c.releaseMS, gainReductionDB: gr))
                    s.compressor = c
                }
            }
        }

        // Ready when two steps in a row barely change anything (after the picture has settled).
        if averager.windows >= 3 && change < 0.5 { stable += 1 } else { stable = 0 }
        if stable >= 2 {
            state = .done
            notes.append(.done(remainingDeviationDB: deviationDB))
        }
        return (s, notes)
    }

    /// Restarts listening (e.g. after the musician changed instrument or the mic was moved).
    public mutating func reset() {
        averager = FeatureAverager()
        state = .idle
        steps = 0
        stable = 0
    }

    // MARK: EQ fitting

    public struct IdealEQ: Equatable, Sendable {
        public var bands: [StripEQBand]
        /// RMS of the correction the bands could not reproduce (dB).
        public var residualDB: Double
    }

    /// Fits the console's four bands to the wanted correction: band 1 low (shelf or bell ≤ 400 Hz), band 4 high
    /// (shelf or bell ≥ 2 kHz), bands 2–3 bells anywhere. Greedy search on the 1/3-octave grid, then refinement.
    public static func idealEQ(bands measuredDB: [Double], profile p: ToneProfile, character: MixCharacter, highPassHz: Double,
                               current: [StripEQBand], reserved: Set<Int>) -> IdealEQ {
        let fc = ThirdOctave.centers
        let lo = max(p.lowerHz, highPassHz * 1.3), hi = p.upperHz
        let idx = fc.indices.filter { fc[$0] >= lo && fc[$0] <= hi }
        guard idx.count >= 4 else { return IdealEQ(bands: current, residualDB: 0) }
        // Ignore bands near the noise floor (no energy there to correct).
        let top = idx.map { measuredDB[$0] }.max() ?? 0
        let used = idx.filter { measuredDB[$0] > top - 45 }
        guard used.count >= 4 else { return IdealEQ(bands: current, residualDB: 0) }
        let target = fc.map { p.targetDB(at: $0) }
        // Align levels: the mean over the working band carries no tonal information.
        let off = used.map { measuredDB[$0] - target[$0] }.reduce(0, +) / Double(used.count)
        var want = [Double](repeating: 0, count: fc.count)
        for k in used { want[k] = -(measuredDB[k] - target[k] - off) * character.eqAmount }
        // Smooth across neighbours: an EQ band is never narrower than about 1/2 octave here.
        var sm = want
        for k in used {
            let nb = [k - 1, k, k + 1].filter { used.contains($0) }
            sm[k] = nb.map { want[$0] * ($0 == k ? 2 : 1) }.reduce(0, +) / Double(nb.count + 1)
        }
        for k in used { sm[k] = min(max(sm[k], -character.maxCutDB), character.maxBoostDB) }

        var result = current
        while result.count < 4 { result.append(StripEQBand(frequency: 1000)) }
        var residual = sm
        // Reserved bands (notches) are part of the response already: subtract them.
        for i in reserved where i < result.count {
            for k in used { residual[k] -= result[i].responseDB(at: fc[k]) }
        }
        let qs: [Double] = [0.7, 1.0, 1.4, 2.0, 3.0]
        let order = [1, 2, 0, 3].filter { !reserved.contains($0) }
        // Pick the bands by the size of what they fix: the largest error first.
        var chosen: [Int: StripEQBand] = [:]
        for slot in order {
            var best: (StripEQBand, Double)?
            let freqs = fc.filter { f in
                switch slot {
                case 0: return f >= max(lo, 40) && f <= 400
                case 3: return f >= 2000 && f <= min(hi, 12500)
                default: return f >= lo && f <= hi
                }
            }
            for f in freqs {
                let types: [EQBandType] = slot == 0 ? [.lowShelf, .peaking] : slot == 3 ? [.highShelf, .peaking] : [.peaking]
                for t in types {
                    for q in (t == .peaking ? qs : [0.7071]) {
                        let unit = StripEQBand(type: t, frequency: f, gainDB: 6, q: q)
                        let shape = used.map { unit.responseDB(at: fc[$0]) / 6 }
                        let num = zip(used, shape).reduce(0.0) { $0 + residual[$1.0] * $1.1 }
                        let den = shape.reduce(0.0) { $0 + $1 * $1 }
                        guard den > 1e-6 else { continue }
                        let g = min(max(num / den, -character.maxCutDB), character.maxBoostDB)
                        let band = StripEQBand(type: t, frequency: f, gainDB: g, q: q)
                        let err = used.reduce(0.0) { acc, k in let e = residual[k] - band.responseDB(at: fc[k]); return acc + e * e }
                        if best == nil || err < best!.1 { best = (band, err) }
                    }
                }
            }
            guard var b = best?.0 else { continue }
            // Corrections under 1 dB are not worth a band.
            if abs(b.gainDB) < 1 { b.gainDB = 0 }
            b.gainDB = (b.gainDB * 4).rounded() / 4
            chosen[slot] = b
            for k in used { residual[k] -= b.responseDB(at: fc[k]) }
        }
        for (slot, b) in chosen { result[slot] = b }
        for slot in order where chosen[slot] == nil { result[slot].gainDB = 0 }
        let rms = (used.reduce(0.0) { $0 + residual[$1] * residual[$1] } / Double(used.count)).squareRoot()
        return IdealEQ(bands: result, residualDB: rms)
    }
}
