import Foundation

// FOH Assist (function #4): the console's channel strip as the assistant sees it, what is plugged
// into each channel, and the overall character of the mix.

/// What a channel carries. Decides the tonal target, filters, dynamics and level in the mix.
public enum SourceKind: String, Codable, Sendable, CaseIterable {
    case kick, snare, tom, hiHat, overhead, percussion
    case bassGuitar, electricGuitar, acousticGuitar, keys, piano
    case maleVocal, femaleVocal, backingVocal, choir, speech
    case violin, viola, cello, doubleBass, harp
    case flute, clarinet, oboe, bassoon, saxophone
    case trumpet, trombone, frenchHorn, tuba
    case playback, unknown

    public var family: SourceFamily {
        switch self {
        case .kick, .snare, .tom, .hiHat, .overhead, .percussion: return .drums
        case .bassGuitar, .electricGuitar, .acousticGuitar, .keys, .piano: return .band
        case .maleVocal, .femaleVocal, .backingVocal, .speech: return .vocals
        case .choir: return .choir
        case .violin, .viola, .cello, .doubleBass, .harp: return .strings
        case .flute, .clarinet, .oboe, .bassoon, .saxophone: return .woodwinds
        case .trumpet, .trombone, .frenchHorn, .tuba: return .brass
        case .playback, .unknown: return .other
        }
    }

    /// True for every musical instrument — drums, band, strings, woodwinds, brass. Owner's rule: all musical
    /// instruments are part of the orchestra, so the one-button "Orchestra" tuning picks all of them (only voices,
    /// choir, speech, playback and unknown sources are left out).
    public var isOrchestral: Bool {
        switch family {
        case .drums, .band, .strings, .woodwinds, .brass: return true
        case .vocals, .choir, .other: return false
        }
    }
}

public enum SourceFamily: String, Codable, Sendable, CaseIterable {
    case drums, band, vocals, choir, strings, woodwinds, brass, other
}

/// Overall style of the show. Scales how hard the assistant equalizes and compresses.
public enum MixCharacter: String, Codable, Sendable, CaseIterable {
    /// Musical theatre: intelligible headset vocals first, smooth and dense.
    case musical
    /// Rock / pop: tight low end, upfront, more compression.
    case rock
    /// Classical / acoustic: transparent, only what the room and the microphone need.
    case classical
    /// Speech, conference, theatre drama.
    case speech

    /// Share of the measured tonal deviation the EQ corrects (0…1).
    public var eqAmount: Double {
        switch self { case .musical: return 0.7; case .rock: return 0.85; case .classical: return 0.4; case .speech: return 0.75 }
    }
    /// Largest boost / cut per band (dB).
    public var maxBoostDB: Double {
        switch self { case .musical: return 4; case .rock: return 5; case .classical: return 2; case .speech: return 4 }
    }
    public var maxCutDB: Double {
        switch self { case .musical: return 8; case .rock: return 9; case .classical: return 4; case .speech: return 9 }
    }
    /// Multiplies the source's nominal gain reduction.
    public var compressionScale: Double {
        switch self { case .musical: return 1.0; case .rock: return 1.4; case .classical: return 0.35; case .speech: return 1.1 }
    }
}

public enum EQBandType: String, Codable, Sendable { case lowShelf, peaking, highShelf }

public struct StripEQBand: Equatable, Codable, Sendable {
    public var type: EQBandType
    public var frequency: Double
    public var gainDB: Double
    public var q: Double
    public init(type: EQBandType = .peaking, frequency: Double, gainDB: Double = 0, q: Double = 1.4) {
        self.type = type; self.frequency = frequency; self.gainDB = gainDB; self.q = q
    }

    public func biquad(sampleRate: Double) -> Biquad {
        switch type {
        case .lowShelf: return Biquad.design(.lowShelf, frequency: frequency, q: 0.7071, gainDB: gainDB, sampleRate: sampleRate)
        case .highShelf: return Biquad.design(.highShelf, frequency: frequency, q: 0.7071, gainDB: gainDB, sampleRate: sampleRate)
        case .peaking: return Biquad.design(.peaking, frequency: frequency, q: q, gainDB: gainDB, sampleRate: sampleRate)
        }
    }

    public func responseDB(at f: Double, sampleRate: Double = 48000) -> Double {
        abs(gainDB) < 0.01 ? 0 : Decibel.fromAmplitude(biquad(sampleRate: sampleRate).response(at: f, sampleRate: sampleRate).magnitude)
    }
}

public struct StripCompressor: Equatable, Codable, Sendable {
    public var enabled: Bool
    public var thresholdDB: Double
    public var ratio: Double
    public var attackMS: Double
    public var releaseMS: Double
    public var kneeDB: Double
    public var makeupDB: Double
    public init(enabled: Bool = false, thresholdDB: Double = 0, ratio: Double = 3, attackMS: Double = 10,
                releaseMS: Double = 150, kneeDB: Double = 2, makeupDB: Double = 0) {
        self.enabled = enabled; self.thresholdDB = thresholdDB; self.ratio = ratio; self.attackMS = attackMS
        self.releaseMS = releaseMS; self.kneeDB = kneeDB; self.makeupDB = makeupDB
    }

    /// Static gain change (dB, ≤ 0 before make-up) for an input level, with a soft knee.
    public func gainReduction(atInputDB x: Double) -> Double {
        guard enabled, ratio > 1 else { return 0 }
        let over = x - thresholdDB
        let k = max(kneeDB, 0.01)
        if over <= -k / 2 { return 0 }
        if over >= k / 2 { return -over * (1 - 1 / ratio) }
        let t = over + k / 2
        return -(1 - 1 / ratio) * t * t / (2 * k)
    }
}

/// One input channel of the console: what the assistant reads and writes.
public struct ChannelStrip: Equatable, Codable, Sendable, Identifiable {
    /// 1-based channel number on the console.
    public var id: Int
    public var name: String
    /// Analogue preamp gain (dB).
    public var gainDB: Double
    public var highPassOn: Bool
    public var highPassHz: Double
    public var eqOn: Bool
    /// Four bands, as on X32 / M32 / X-Air channels.
    public var eq: [StripEQBand]
    public var compressor: StripCompressor
    /// Fader (dB, -inf as -144).
    public var faderDB: Double
    public var muted: Bool
    /// Polarity (phase) inverted on the console's input.
    public var polarityInverted: Bool = false

    public init(id: Int, name: String = "", gainDB: Double = 20, highPassOn: Bool = false, highPassHz: Double = 80,
                eqOn: Bool = true, eq: [StripEQBand] = ChannelStrip.flatEQ, compressor: StripCompressor = StripCompressor(),
                faderDB: Double = -144, muted: Bool = false) {
        self.id = id; self.name = name; self.gainDB = gainDB; self.highPassOn = highPassOn; self.highPassHz = highPassHz
        self.eqOn = eqOn; self.eq = eq; self.compressor = compressor; self.faderDB = faderDB; self.muted = muted
    }

    public static let flatEQ: [StripEQBand] = [
        StripEQBand(type: .lowShelf, frequency: 120, gainDB: 0),
        StripEQBand(type: .peaking, frequency: 500, gainDB: 0, q: 1.4),
        StripEQBand(type: .peaking, frequency: 2500, gainDB: 0, q: 1.4),
        StripEQBand(type: .highShelf, frequency: 8000, gainDB: 0),
    ]

    /// Combined EQ + high-pass response (dB) at f.
    public func filterResponseDB(at f: Double, sampleRate: Double = 48000) -> Double {
        var db = 0.0
        if eqOn { for b in eq { db += b.responseDB(at: f, sampleRate: sampleRate) } }
        if highPassOn {
            // X32 / X-Air channel low cut: 12 dB/oct.
            let hp = Biquad.design(.highPass, frequency: highPassHz, q: 0.7071, sampleRate: sampleRate)
            db += Decibel.fromAmplitude(hp.response(at: f, sampleRate: sampleRate).magnitude)
        }
        return db
    }
}

/// Where the computer hears each console channel.
public enum TapPoint: String, Codable, Sendable, CaseIterable {
    /// Before the channel EQ (typical for USB / Dante card sends: "pre EQ" or "insert" taps).
    case preEQ
    /// After EQ and dynamics: the assistant removes its own EQ from the measurement.
    case postEQ
}
