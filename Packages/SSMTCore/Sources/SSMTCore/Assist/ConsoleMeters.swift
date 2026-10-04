import Foundation

/// Levels and RTA read from the console over the network — the way remote-control apps see a
/// console over Wi-Fi, with no audio cable to the computer.
///
/// X32 / M32: `/meters ,s "/meters/1"` streams channel meters for 10 s (renew), `/meters/2` buses, and
/// `/meters/15` the RTA of the console's RTA source. Blobs hold a little-endian count followed by values:
/// linear floats (1.0 = 0 dBFS) for levels, and for the RTA 100 signed 16-bit values in 1/256 dB.
/// X Air: `/meters/1` channel levels and `/meters/4` RTA, both as 16-bit values in 1/256 dB.
/// Layouts follow the public unofficial protocol descriptions and are marked unverified in ASSUMPTIONS.
public enum ConsoleMeters {
    public enum Bank: String, Sendable {
        case channels, buses, rta
    }

    /// Subscription request for a bank (repeat within 10 s).
    public static func request(_ bank: Bank, family: MixerFamily) -> OSCMessage {
        let path: String
        switch (bank, family) {
        case (.channels, _): path = "/meters/1"
        case (.buses, .xAir): path = "/meters/5"
        case (.buses, _): path = "/meters/2"
        case (.rta, .xAir): path = "/meters/4"
        case (.rta, _): path = "/meters/15"
        }
        return OSCMessage("/meters", [.string(path)])
    }

    /// Makes the console RTA follow a channel (selects it; the RTA source is set to the selected channel).
    public static func rtaFollow(channel: Int, family: MixerFamily) -> [OSCMessage] {
        family == .xAir
            ? [OSCMessage("/-stat/rta/source", [.int(Int32(channel - 1))])]
            : [OSCMessage("/-stat/selidx", [.int(Int32(channel - 1))]), OSCMessage("/-stat/rta/source", [.int(Int32(channel))])]
    }

    /// Which bank a message carries, and its values in dBFS (levels) or dB (RTA). nil = not meters.
    public static func decode(_ m: OSCMessage, family: MixerFamily) -> (Bank, [Double])? {
        guard m.address.hasPrefix("/meters/"), case let .blob(data)? = m.arguments.first else { return nil }
        let path = String(m.address.dropFirst("/meters/".count))
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return nil }
        let count = Int(UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24)
        let body = Array(bytes.dropFirst(4))
        func shorts() -> [Double] {
            stride(from: 0, to: body.count - 1, by: 2).map { Double(Int16(bitPattern: UInt16(body[$0]) | UInt16(body[$0 + 1]) << 8)) / 256 }
        }
        func floats() -> [Double] {
            stride(from: 0, to: body.count - 3, by: 4).prefix(count).map {
                let v = Float(bitPattern: UInt32(body[$0]) | UInt32(body[$0 + 1]) << 8 | UInt32(body[$0 + 2]) << 16 | UInt32(body[$0 + 3]) << 24)
                return Decibel.fromAmplitude(Double(max(v, 0)))
            }
        }
        switch (family, path) {
        case (.xAir, "1"): return (.channels, shorts())
        case (.xAir, "5"): return (.buses, shorts())
        case (.xAir, "4"): return (.rta, shorts())
        case (_, "1"): return (.channels, Array(floats().prefix(32)))
        // X32 /meters/2: 16 buses, 6 matrices, main L, main R, mono… (main used by the polarity check).
        case (_, "2"): return (.buses, floats())
        case (_, "15"): return (.rta, Array(shorts().prefix(100)))
        default: return nil
        }
    }

    /// Centre frequencies of the console's 100 RTA bands (20 Hz … 20 kHz, log spaced).
    public static let rtaFrequencies: [Double] = (0..<100).map { 20 * pow(1000, Double($0) / 99) }

    /// Folds 100 RTA bands into the assistant's one-third-octave bands (power sum).
    public static func thirdOctaves(fromRTA rta: [Double]) -> [Double] {
        var power = [Double](repeating: 0, count: ThirdOctave.centers.count)
        for (k, db) in rta.enumerated() where k < rtaFrequencies.count {
            power[ThirdOctave.index(of: rtaFrequencies[k])] += pow(10, db / 10)
        }
        return power.map { Decibel.fromPower($0 + 1e-15) }
    }
}

/// Turns the meter stream of one window (≈ 2 s at ~20 frames/s) into `SignalFeatures` per channel.
/// Spectra come from the console RTA while it follows a channel; the last spectrum is kept per channel
/// so a group can be measured round-robin.
public struct ConsoleMeterAccumulator: Sendable {
    var frames: [Int: [Double]] = [:]
    var rta: [Int: [Double]] = [:]
    var rtaFrames: [Int: Int] = [:]
    /// Last complete spectrum per channel (one-third octaves, dB).
    public private(set) var lastBands: [Int: [Double]] = [:]
    /// Channel the console RTA follows now. After a switch the first frames still show the previous source
    /// (the console needs a moment), so they are skipped.
    public var rtaChannel: Int? { didSet { if rtaChannel != oldValue { rtaSkip = Self.framesAfterSwitch } } }
    var rtaSkip = 0
    /// ≈ 0.3 s of RTA frames (the console sends about 20 a second).
    static let framesAfterSwitch = 6
    public var gateDB = -65.0

    public init() {}

    public mutating func add(channelLevels: [Double]) {
        for (i, db) in channelLevels.enumerated() { frames[i + 1, default: []].append(db) }
    }

    public mutating func add(rtaBands: [Double]) {
        guard let ch = rtaChannel else { return }
        if rtaSkip > 0 { rtaSkip -= 1; return }
        let b = ConsoleMeters.thirdOctaves(fromRTA: rtaBands)
        if var sum = rta[ch] {
            for k in sum.indices { sum[k] = Decibel.fromPower(pow(10, sum[k] / 10) + pow(10, b[k] / 10)) }
            rta[ch] = sum
        } else {
            rta[ch] = b
        }
        rtaFrames[ch, default: 0] += 1
    }

    /// Features of the window that just ended; clears the window.
    public mutating func takeWindow(seconds: Double = 2) -> [Int: SignalFeatures] {
        for (ch, sum) in rta { let n = Double(rtaFrames[ch] ?? 1); lastBands[ch] = sum.map { $0 - 10 * log10(n) } }
        var out: [Int: SignalFeatures] = [:]
        for (ch, f) in frames where !f.isEmpty {
            var s = SignalFeatures()
            let active = f.filter { $0 > gateDB }
            s.activity = Double(active.count) / Double(f.count)
            s.peakDB = f.max() ?? -120
            if !active.isEmpty {
                let sorted = active.sorted()
                s.level50DB = sorted[sorted.count / 2]
                s.level95DB = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
                s.rmsDB = Decibel.fromPower(active.reduce(0) { $0 + pow(10, $1 / 10) } / Double(active.count))
                // Console meters are peak-reading and slow: crest from frame-to-frame spread, not samples.
                s.crestDB = max(0, (sorted.last ?? 0) - s.level50DB) + 6
                var onsets = 0
                for k in 1..<f.count where f[k] > gateDB && f[k] - f[k - 1] > 6 { onsets += 1 }
                s.onsetRate = Double(onsets) / seconds
            }
            if let b = lastBands[ch] {
                // RTA shape, levelled to the channel meter (the RTA has its own gain).
                let total = Decibel.fromPower(b.reduce(0) { $0 + pow(10, $1 / 10) })
                s.bandsDB = b.map { $0 - total + s.rmsDB }
                var num = 0.0, den = 0.0
                for (k, d) in s.bandsDB.enumerated() { let p = pow(10, d / 10); num += ThirdOctave.centers[k] * p; den += p }
                s.centroidHz = den > 0 ? num / den : 0
            }
            out[ch] = s
        }
        frames.removeAll(keepingCapacity: true)
        rta.removeAll()
        rtaFrames.removeAll()
        return out
    }
}

/// The measurement microphone: any microphone from the library of function #1 (individual calibration
/// file or a built-in typical profile) plus the SPL calibration, if done.
public struct MeasurementMic: Sendable {
    public var calibration: MicrophoneCalibration?
    public var spl: SPLCalibration?
    public init(calibration: MicrophoneCalibration? = nil, spl: SPLCalibration? = nil) {
        self.calibration = calibration
        self.spl = spl
    }

    /// Spectrum corrected by the microphone's own frequency response.
    public func corrected(_ f: SignalFeatures) -> SignalFeatures {
        guard let c = calibration else { return f }
        var g = f
        g.bandsDB = zip(ThirdOctave.centers, f.bandsDB).map { fr, d in d - c.deviation(at: fr) }
        return g
    }

    /// A-weighted level of a window: dB SPL when calibrated, else dBFS (and `calibrated` false).
    public func levelA(_ x: [Float], sampleRate: Double) -> (value: Double, calibrated: Bool) {
        var m = SoundLevelMeter(sampleRate: sampleRate, calibration: spl)
        m.process(x)
        let r = m.reading()
        return (r.laeq, r.isCalibrated)
    }
}
