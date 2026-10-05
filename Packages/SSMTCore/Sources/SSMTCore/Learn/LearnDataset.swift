import Foundation

/// Training data from the recordings, for the model that will learn soundcheck decisions: one row per playing channel
/// per window (10 s), with what the channel sounded like (meters) and how the console was set for it (every parameter
/// of the channel, as the console sends it). Written as JSON lines, one file for all recordings.
public enum LearnDataset {
    public struct Row: Codable, Equatable, Sendable {
        /// Recording id, its title and the console family.
        public var event: String
        public var title: String
        public var console: String
        /// Start of the window, seconds since the start of the recording.
        public var t: Double
        public var ch: Int
        public var name: String
        /// Source kind guessed from the name (`SourceKind`), "unknown" when the name says nothing.
        public var kind: String
        /// Channel level over the window: peak and median of the per-second peaks, dBFS.
        public var peak: Double
        public var level: Double
        /// Most gate and compressor gain reduction in the window, dB.
        public var gate: Double?
        public var dyn: Double?
        /// Console RTA (mean of the window, third octaves) and what the console says its RTA source is.
        public var rta: [Double]?
        public var rtaSource: ParamValue?
        /// Every parameter of the channel at the end of the window, by address below the channel ("mix/fader",
        /// "eq/2/g", "dyn/thr", "mix/03/level"…), plus its head amp ("headamp/gain", "headamp/phantom") when known.
        public var settings: [String: ParamValue]
    }

    public static let window = 10.0

    /// Channel prefix in the parameter addresses ("/ch/07/").
    static func prefix(_ ch: Int) -> String { String(format: "/ch/%02d/", ch) }

    /// Head amp address prefix feeding a channel, from the recorded routing (X32) or one to one (X Air).
    static func headamp(_ ch: Int, family: MixerFamily, params: [String: ParamValue]) -> String? {
        var r = X32InputRouting()
        for (k, a) in X32InputRouting.blockAddresses.enumerated() { if let v = params[a]?.number { r.blocks[k] = Int(v) } }
        if let v = params[prefix(ch) + "config/source"]?.number { r.sources[ch] = Int(v) }
        guard case let .headamp(n)? = r.gainControl(ch, family: family) else { return nil }
        return family == .xAir ? String(format: "/headamp/%02d/", n) : String(format: "/headamp/%03d/", n)
    }

    /// Rows of one recording.
    public static func rows(_ rec: LearnRecording) -> [Row] {
        let family = MixerFamily(rawValue: rec.header.console) ?? .x32
        var out: [Row] = []
        var start = 0.0
        var peaks: [Int: [Double]] = [:]
        var gates: [Int: Double] = [:]
        var dyns: [Int: Double] = [:]
        var rtaPower: [Double] = []
        var rtaFrames = 0
        var lastParams: [String: ParamValue] = [:]
        var lastStrips: [Int: ChannelStrip] = [:]

        func flush() {
            let rta = rtaFrames > 0 ? rtaPower.map { (max(-120, Decibel.fromPower($0 / Double(rtaFrames) + 1e-15)) * 2).rounded() / 2 } : nil
            let names = lastStrips.values.map(\.name)
            let choir = names.contains { SourceClassifier.kind(forName: $0) == .choir }
            for (ch, p) in peaks.sorted(by: { $0.key < $1.key }) {
                let sorted = p.sorted()
                guard let top = sorted.last, top > PatternLearner.activeDB else { continue }
                let pre = prefix(ch)
                var settings: [String: ParamValue] = [:]
                for (k, v) in lastParams where k.hasPrefix(pre) { settings[String(k.dropFirst(pre.count))] = v }
                if let h = headamp(ch, family: family, params: lastParams) {
                    for (k, v) in lastParams where k.hasPrefix(h) { settings["headamp/" + String(k.dropFirst(h.count))] = v }
                }
                if settings.isEmpty, let s = lastStrips[ch] {
                    // Format 1 recordings: the typed strip, through the messages that would set it.
                    var c = ConsoleCapture(family: .x32)
                    c.absorb(strips: [ch: s], buses: [:])
                    for (k, v) in c.params where k.hasPrefix(pre) { settings[String(k.dropFirst(pre.count))] = v }
                }
                let name = lastStrips[ch]?.name ?? (lastParams[pre + "config/name"]?.text ?? "")
                let kind = SourceClassifier.kind(forName: name, choirContext: choir) ?? .unknown
                out.append(Row(event: rec.header.id, title: rec.header.title, console: rec.header.console, t: start, ch: ch,
                               name: name, kind: kind.rawValue, peak: top, level: sorted[sorted.count / 2],
                               gate: gates[ch], dyn: dyns[ch], rta: rta,
                               rtaSource: lastParams["/-stat/rta/source"], settings: settings))
            }
            peaks = [:]; gates = [:]; dyns = [:]; rtaPower = []; rtaFrames = 0
        }

        rec.replay { frame, strips, _ in
            lastStrips = strips
            lastParams.merge(frame.p ?? [:]) { $1 }
            if frame.t - start >= window { flush(); start = (frame.t / window).rounded(.down) * window }
            guard frame.lost != true else { return }
            for (i, v) in frame.levels.enumerated() { peaks[i + 1, default: []].append(v) }
            if let m = frame.m {
                for (i, v) in m.gate.enumerated() { gates[i + 1] = min(gates[i + 1] ?? 0, v) }
                for (i, v) in m.dyn.enumerated() { dyns[i + 1] = min(dyns[i + 1] ?? 0, v) }
                if !m.rta.isEmpty {
                    if rtaPower.count != m.rta.count { rtaPower = [Double](repeating: 0, count: m.rta.count); rtaFrames = 0 }
                    for k in m.rta.indices { rtaPower[k] += pow(10, m.rta[k] / 10) }
                    rtaFrames += 1
                }
            }
        }
        flush()
        return out
    }

    /// All rows of all recordings, as JSON lines.
    public static func jsonLines(_ recordings: [LearnRecording]) -> Data {
        var d = Data()
        for rec in recordings { for r in rows(rec) { d.append(LearningRecorder.line(r)) } }
        return d
    }

    /// File name of the dataset next to the recordings.
    public static let fileName = "SSMT-dataset.jsonl"
}
