import Foundation

// FOH Assist learning mode: while an engineer mixes a real event, the console is read once a second and written to a
// recording (JSON lines). About twenty events later the recordings show how this engineer works each kind of source;
// a soundcheck engine is built from that later.

/// First line of a recording: which event, which console.
public struct LearnHeader: Codable, Equatable, Sendable {
    /// 1: strips, buses and levels. 2: also every console parameter (`p`) and meters (gain reduction, outputs, RTA).
    public var format = 2
    public var id: String
    public var title: String
    /// Start, seconds since 1970.
    public var startedAt: Double
    /// `MixerFamily` raw value.
    public var console: String
    /// Model and firmware as the console reports them ("X32 · 4.06").
    public var model: String
    /// The program that recorded ("SSMT 1.5.0 macOS").
    public var app: String

    public init(id: String = UUID().uuidString, title: String, startedAt: Double = Date().timeIntervalSince1970,
                console: String, model: String = "", app: String = "") {
        self.id = id; self.title = title; self.startedAt = startedAt; self.console = console; self.model = model; self.app = app
    }
}

/// One second of the console. Strips and buses are stored when they changed (all of them in a key frame, once a
/// minute); raw parameters likewise, all of them every ten minutes. Meters add about 1 kB a second, so a four-hour
/// show takes some 20 MB.
public struct LearnFrame: Codable, Equatable, Sendable {
    /// Seconds since the start of the recording.
    public var t: Double
    /// Channel meters, dBFS (index 0 = channel 1), rounded to 0.5 dB; -120 = no signal or not known.
    public var levels: [Double]
    /// Mix bus meters, dBFS (index 0 = bus 1).
    public var busLevels: [Double]
    /// Strips that changed since the previous frame (all strips in a key frame).
    public var strips: [ChannelStrip]?
    public var buses: [BusStrip]?
    /// Every strip and bus is in this frame.
    public var key: Bool?
    /// Console parameters by OSC address (as the console sends them) that changed since the previous frame; all of
    /// them when `pkey`.
    public var p: [String: ParamValue]?
    public var pkey: Bool?
    /// Gain reduction, output levels and RTA of the second (`LearnMeters`).
    public var m: LearnMeters?

    public init(t: Double, levels: [Double], busLevels: [Double], strips: [ChannelStrip]? = nil, buses: [BusStrip]? = nil, key: Bool? = nil) {
        self.t = t; self.levels = levels; self.busLevels = busLevels; self.strips = strips; self.buses = buses; self.key = key
    }
}

/// Turns the console state, sampled once a second, into the lines of a recording.
public struct LearningRecorder: Sendable {
    public let header: LearnHeader
    /// A key frame (every strip and bus) this often, seconds.
    public var keyInterval = 60.0
    public private(set) var frames = 0
    /// Parameter changes seen so far (a strip or bus that changed in a second counts once).
    public private(set) var changes = 0
    private var last: [Int: ChannelStrip] = [:]
    private var lastBuses: [Int: BusStrip] = [:]
    private var lastKey = -Double.infinity
    /// All raw parameters are written again this often, seconds.
    public var paramKeyInterval = 600.0
    private var lastParams: [String: ParamValue] = [:]
    private var lastParamKey = -Double.infinity

    public init(header: LearnHeader) { self.header = header }

    public func headerLine() -> Data { Self.line(header) }

    /// The frame for second `t` of the recording, as one JSON line (with the newline).
    public mutating func record(t: Double, strips: [Int: ChannelStrip], buses: [Int: BusStrip],
                                channelLevels: [Int: Double], busLevels: [Int: Double],
                                params: [String: ParamValue]? = nil, meters: LearnMeters? = nil) -> Data {
        let frame = makeFrame(t: t, strips: strips, buses: buses, channelLevels: channelLevels, busLevels: busLevels,
                              params: params, meters: meters)
        return Self.line(frame)
    }

    public mutating func makeFrame(t: Double, strips: [Int: ChannelStrip], buses: [Int: BusStrip],
                                   channelLevels: [Int: Double], busLevels: [Int: Double],
                                   params: [String: ParamValue]? = nil, meters: LearnMeters? = nil) -> LearnFrame {
        let s = strips.mapValues(Self.rounded)
        let b = buses.mapValues(Self.rounded)
        let key = t - lastKey >= keyInterval
        let changedStrips = s.values.filter { last[$0.id] != $0 }.sorted { $0.id < $1.id }
        let changedBuses = b.values.filter { lastBuses[$0.id] != $0 }.sorted { $0.id < $1.id }
        if frames > 0, params == nil { changes += changedStrips.count + changedBuses.count }
        var frame = LearnFrame(t: (t * 10).rounded() / 10,
                               levels: Self.levels(channelLevels, count: strips.keys.max() ?? 0),
                               busLevels: Self.levels(busLevels, count: buses.keys.max() ?? 0))
        if key {
            frame.key = true
            frame.strips = s.values.sorted { $0.id < $1.id }
            frame.buses = b.values.sorted { $0.id < $1.id }
            lastKey = t
        } else {
            if !changedStrips.isEmpty { frame.strips = changedStrips }
            if !changedBuses.isEmpty { frame.buses = changedBuses }
        }
        if let params {
            if t - lastParamKey >= paramKeyInterval {
                if !params.isEmpty {
                    frame.p = params
                    frame.pkey = true
                    lastParamKey = t
                }
                changes += Self.edits(params, since: lastParams)
            } else {
                let changed = params.filter { lastParams[$0.key] != $0.value }
                if !changed.isEmpty { frame.p = changed }
                changes += Self.edits(changed, since: lastParams)
            }
            lastParams = params
        }
        if var meters {
            // Per-second peaks from the meter stream are better than the last meter value.
            if !meters.levels.isEmpty { frame.levels = meters.levels; meters.levels = [] }
            if meters != LearnMeters() { frame.m = meters }
        }
        last = s
        lastBuses = b
        frames += 1
        return frame
    }

    /// Parameters that had a value before and now have another (a value heard for the first time is not an edit).
    static func edits(_ params: [String: ParamValue], since old: [String: ParamValue]) -> Int {
        params.filter { key, value in old[key].map { $0 != value } ?? false }.count
    }

    static func levels(_ map: [Int: Double], count: Int) -> [Double] {
        guard count > 0 else { return [] }
        return (1...count).map { ch in
            guard let v = map[ch], v.isFinite else { return -120 }
            return (max(-120, min(20, v)) * 2).rounded() / 2
        }
    }

    static func r(_ v: Double, _ step: Double) -> Double { (v / step).rounded() * step }

    /// Values rounded to what an engineer can tell apart, so small jitter on the console is not a "change".
    static func rounded(_ s: ChannelStrip) -> ChannelStrip {
        var x = s
        x.gainDB = r(s.gainDB, 0.5)
        x.highPassHz = r(s.highPassHz, 1)
        x.faderDB = max(-144, r(s.faderDB, 0.1))
        x.eq = s.eq.map { b in
            var c = b
            c.frequency = b.frequency >= 1000 ? r(b.frequency, 10) : r(b.frequency, 1)
            c.gainDB = r(b.gainDB, 0.25)
            c.q = r(b.q, 0.01)
            return c
        }
        x.compressor.thresholdDB = r(s.compressor.thresholdDB, 0.5)
        x.compressor.attackMS = r(s.compressor.attackMS, 0.5)
        x.compressor.releaseMS = r(s.compressor.releaseMS, 1)
        x.compressor.kneeDB = r(s.compressor.kneeDB, 0.5)
        x.compressor.makeupDB = r(s.compressor.makeupDB, 0.5)
        return x
    }

    static func rounded(_ b: BusStrip) -> BusStrip {
        var x = b
        x.faderDB = max(-144, r(b.faderDB, 0.1))
        return x
    }

    static func line<T: Encodable>(_ v: T) -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        var d = (try? e.encode(v)) ?? Data()
        d.append(0x0A)
        return d
    }

    /// File name for a new recording: date, time and a short form of the title.
    public static func fileName(for header: LearnHeader) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let date = f.string(from: Date(timeIntervalSince1970: header.startedAt))
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_абвгдеёжзийклмнопрстуфхцчшщъыьэюяАБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ")
        let title = String(header.title.map { allowed.contains($0) ? $0 : "-" }.prefix(40))
        return title.isEmpty ? "\(date).ssmtlearn" : "\(date)_\(title).ssmtlearn"
    }
}

/// A recording read back.
public struct LearnRecording: Equatable, Sendable {
    public var header: LearnHeader
    public var frames: [LearnFrame]

    public init(header: LearnHeader, frames: [LearnFrame]) {
        self.header = header
        self.frames = frames
    }

    /// Length, seconds.
    public var duration: Double { frames.last?.t ?? 0 }

    /// Parses a recording; a line cut short (the computer went off mid-write) is skipped.
    public static func parse(_ data: Data) -> LearnRecording? {
        let d = JSONDecoder()
        var header: LearnHeader?
        var frames: [LearnFrame] = []
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            let chunk = Data(line)
            if header == nil {
                guard let h = try? d.decode(LearnHeader.self, from: chunk) else { return nil }
                header = h
            } else if let f = try? d.decode(LearnFrame.self, from: chunk) {
                frames.append(f)
            }
        }
        return header.map { LearnRecording(header: $0, frames: frames) }
    }

    /// Every console parameter at each frame (the last value heard), with the frame.
    public func replayParams(_ body: (_ frame: LearnFrame, _ params: [String: ParamValue]) -> Void) {
        var params: [String: ParamValue] = [:]
        for f in frames {
            params.merge(f.p ?? [:]) { $1 }
            body(f, params)
        }
    }

    /// Plays the recording back second by second with the full console state at each frame.
    public func replay(_ body: (_ frame: LearnFrame, _ strips: [Int: ChannelStrip], _ buses: [Int: BusStrip]) -> Void) {
        var strips: [Int: ChannelStrip] = [:]
        var buses: [Int: BusStrip] = [:]
        for f in frames {
            if f.key == true { strips = [:]; buses = [:] }
            for s in f.strips ?? [] { strips[s.id] = s }
            for b in f.buses ?? [] { buses[b.id] = b }
            body(f, strips, buses)
        }
    }
}
