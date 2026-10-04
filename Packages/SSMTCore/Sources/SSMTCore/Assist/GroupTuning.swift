import Foundation

/// Which channels go into a group tuning.
public enum AssistGroupSelection: Equatable, Codable, Sendable {
    /// Every channel whose name reads as a musical instrument: drums, band and orchestral ("Kick In", "Bass DI",
    /// "Violin 1", "Vc", "Скрипка", "Tpt"…).
    case orchestra
    /// Every channel whose name reads as a choir or backing vocal ("Choir L", "Хор 2", "Sopr", "BV").
    case choir
    /// An explicit range of console channels (inclusive), e.g. 17…24 for a choir on eight mics.
    case range(Int, Int)

    /// Channels selected from the console names.
    public func channels(in strips: [ChannelStrip]) -> [Int] {
        let names = strips.map(\.name)
        let choirContext = names.contains { SourceClassifier.kind(forName: $0) == .choir }
        switch self {
        case .orchestra:
            // Same reading as the choir button, so a choir's "Bass" / "Alto" stays in the choir.
            return strips.filter {
                SourceClassifier.kind(forName: $0.name, choirContext: choirContext)?.isOrchestral == true
            }.map(\.id)
        case .choir:
            return strips.filter {
                SourceClassifier.kind(forName: $0.name, choirContext: choirContext) == .choir
            }.map(\.id)
        case let .range(a, b):
            let lo = min(a, b), hi = max(a, b)
            return strips.map(\.id).filter { (lo...hi).contains($0) }
        }
    }
}

public enum GroupPhase: String, Codable, Sendable {
    /// Faders down to a safe level, snapshot taken.
    case prepare
    /// Every member tunes its gain, filters, EQ and dynamics at the same time.
    case tune
    /// Members are balanced against each other by their measured loudness and role.
    case balance
    /// The whole group is brought up step by step while the measurement mic listens for feedback.
    case ringOut
    case done
}

/// Tunes several channels at once (orchestra, choir, a range of channels).
public struct GroupTuning: Sendable {
    public let members: [Int]
    public var character: MixCharacter
    public private(set) var phase: GroupPhase = .prepare
    public private(set) var tunings: [Int: ChannelTuning] = [:]
    /// Fader level the group starts from (dB): quiet enough to be safe in the room.
    public var safeFaderDB = -30.0
    /// Fader ceiling: the loudest member never goes above this.
    public var maxFaderDB = 0.0
    /// Stop raising when the measurement mic reads this (dB SPL, A-weighted), if it is calibrated.
    public var targetSPL: Double
    public var stepDB = 2.0
    /// Distance kept below the level where feedback appeared (dB).
    public var feedbackMarginDB = 3.0
    public private(set) var groupLevelDB = 0.0
    public private(set) var notches: [Int: (frequency: Double, depthDB: Double)] = [:]
    public private(set) var ringOutStopped = false
    var lastFeatures: [Int: SignalFeatures] = [:]
    var tuneSteps = 0
    let notchBand = 2

    public init(members: [Int], names: [Int: String], character: MixCharacter, tap: TapPoint = .preEQ) {
        self.members = members
        self.character = character
        let choirContext = names.values.contains { SourceClassifier.kind(forName: $0) == .choir }
        for ch in members {
            let name = names[ch] ?? ""
            var kind = SourceClassifier.kind(forName: name, choirContext: choirContext)
            if kind == .backingVocal && choirContext { kind = .choir }
            tunings[ch] = ChannelTuning(channel: ch, name: name, kind: kind, character: character, tap: tap)
        }
        switch character {
        case .classical: targetSPL = 82
        case .musical: targetSPL = 92
        case .rock: targetSPL = 98
        case .speech: targetSPL = 78
        }
    }

    public var doneMembers: Int { tunings.values.filter { $0.state == .done }.count }

    /// One step (≈ 2 s). `features`: what each member's channel sounded like; `feedback`: events from the
    /// measurement mic during this window; `splA`: calibrated mic level, if any.
    public mutating func step(strips: [Int: ChannelStrip], features: [Int: SignalFeatures], feedback: [FeedbackDetector.Event],
                              splA: Double? = nil) -> (strips: [Int: ChannelStrip], notes: [Int: [AssistNote]]) {
        var out = strips
        var notes: [Int: [AssistNote]] = [:]
        for (ch, f) in features where f.hasSignal { lastFeatures[ch] = f }

        // Feedback is handled first in every phase: notch, then back off.
        if cooldown > 0 { cooldown -= 1 }
        // While a howl dies away after a notch the detector still hears it: ignore it for two steps.
        let fresh = cooldown > 0 ? feedback.filter { e in !notches.values.contains { abs(log2($0.frequency / e.frequency)) < 1.0 / 6 } } : feedback
        if !fresh.isEmpty && phase != .prepare && phase != .done {
            cooldown = 2
            for e in fresh {
                guard let ch = culprit(of: e.frequency, strips: out) else { continue }
                var s = out[ch]!
                let prev = notches[ch]
                let depth = prev.map { abs(log2($0.frequency / e.frequency)) < 1.0 / 6 ? min($0.depthDB + 3, 12) : 4 } ?? 4
                let sameAndDeep = prev.map { abs(log2($0.frequency / e.frequency)) < 1.0 / 6 && $0.depthDB >= 12 } ?? false
                while s.eq.count <= notchBand { s.eq.append(StripEQBand(frequency: 1000)) }
                s.eq[notchBand] = StripEQBand(type: .peaking, frequency: (e.frequency * 10).rounded() / 10, gainDB: -depth, q: 8)
                s.eqOn = true
                notches[ch] = (e.frequency, depth)
                tunings[ch]?.reservedBands.insert(notchBand)
                notes[ch, default: []].append(.feedback(frequency: e.frequency, notchDB: -depth))
                if sameAndDeep { ringOutStopped = true }
                out[ch] = s
            }
            if phase == .ringOut || phase == .balance {
                groupLevelDB -= feedbackMarginDB
                for ch in members { if var s = out[ch] { s.faderDB = max(s.faderDB - feedbackMarginDB, safeFaderDB - 12); out[ch] = s } }
                groupLevelDB = max(groupLevelDB, safeFaderDB - 12)
                notchesUsed += fresh.count
                if notchesUsed >= maxNotches { ringOutStopped = true }
            }
        }

        switch phase {
        case .prepare:
            for ch in members {
                guard var s = out[ch] else { continue }
                s.faderDB = min(s.faderDB, safeFaderDB)
                s.muted = false
                out[ch] = s
                notes[ch, default: []].append(.fader(toDB: s.faderDB))
            }
            phase = .tune

        case .tune:
            tuneSteps += 1
            for ch in members {
                guard var t = tunings[ch], let s = out[ch], let f = features[ch] else { continue }
                let (ns, n) = t.step(features: f, strip: s, choirContext: true)
                tunings[ch] = t
                out[ch] = ns
                if !n.isEmpty { notes[ch, default: []] += n }
            }
            // Members that never play are left alone after a while; the rest must be done.
            let waiting = members.filter { tunings[$0]?.state != .done }
            let silentTooLong = tuneSteps > 15 && waiting.allSatisfy { lastFeatures[$0] == nil }
            if waiting.isEmpty || silentTooLong || tuneSteps > 40 { phase = .balance }

        case .balance:
            // Level each member by its loudness at the tap (after gain) and its role in the group.
            let loud = members.compactMap { ch -> (Int, Double)? in
                guard let f = lastFeatures[ch] else { return nil }
                return (ch, f.level50DB)
            }
            guard !loud.isEmpty else { phase = .done; break }
            let roles = tunings.mapValues { $0.profile.mixLevelDB }
            let role = { (ch: Int) -> Double in roles[ch] ?? 0 }
            let topRole = loud.map { role($0.0) }.max() ?? 0
            // Fader that puts each member at its role level when the loudest-role member sits at 0 dB.
            var rel: [Int: Double] = [:]
            let refLevel = loud.map(\.1).max() ?? -20
            for (ch, l) in loud { rel[ch] = (role(ch) - topRole) - (l - refLevel) }
            let top = rel.values.max() ?? 0
            groupLevelDB = safeFaderDB
            for (ch, r) in rel {
                guard var s = out[ch] else { continue }
                s.faderDB = ((groupLevelDB + r - top) * 2).rounded() / 2
                out[ch] = s
                notes[ch, default: []].append(.fader(toDB: s.faderDB))
            }
            balanceOffsets = rel.mapValues { $0 - top }
            phase = .ringOut

        case .ringOut:
            let reached = (splA.map { $0 >= targetSPL } ?? false) || groupLevelDB + stepDB > maxFaderDB
            if ringOutStopped || reached {
                phase = .done
                for ch in members { notes[ch, default: []].append(.done(remainingDeviationDB: tunings[ch]?.deviationDB ?? 0)) }
                break
            }
            if fresh.isEmpty && cooldown == 0 {
                groupLevelDB += stepDB
                for (ch, off) in balanceOffsets {
                    guard var s = out[ch] else { continue }
                    s.faderDB = ((groupLevelDB + off) * 2).rounded() / 2
                    out[ch] = s
                }
            }

        case .done:
            break
        }
        return (out, notes)
    }

    var balanceOffsets: [Int: Double] = [:]
    var cooldown = 0
    public private(set) var notchesUsed = 0
    /// Notches the ring-out may place before it settles for the level it has.
    public var maxNotches = 4

    /// The member most likely feeding a feedback loop at f: the most energy at f in its own channel,
    /// weighted by how loud it is sent to the room.
    func culprit(of f: Double, strips: [Int: ChannelStrip]) -> Int? {
        let b = ThirdOctave.index(of: f)
        return members.max { a, c in score(a, b, strips) < score(c, b, strips) }
    }

    func score(_ ch: Int, _ band: Int, _ strips: [Int: ChannelStrip]) -> Double {
        guard let s = strips[ch] else { return -1000 }
        let level = lastFeatures[ch].map { $0.bandsDB[band] } ?? -100
        return level + s.faderDB + s.filterResponseDB(at: ThirdOctave.centers[band])
    }
}
