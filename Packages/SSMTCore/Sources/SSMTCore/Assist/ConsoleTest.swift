import Foundation

/// A made-up show for the console test: channel names (as the console shows them: ASCII, ≤ 12 characters),
/// what plays on each, and how its "microphone" colours the sound.
public struct AssistScenario: Sendable, Identifiable {
    public struct Channel: Sendable {
        public var name: String
        public var kind: SourceKind
        public var pitch: Double
        /// Colouring the assistant should find and correct.
        public var flaw: Flaw
        public var levelDB: Double
        /// Second mic of the previous channel (index in the list), with delay and physical polarity.
        public var sameAs: Int?
        public var delayMS: Double = 0
        public var physicalPolarity: Double = 1
    }

    public enum Flaw: Sendable { case none, mud, harsh, dull, boom }

    public let id: String
    public let channels: [Channel]

    static func ch(_ n: String, _ k: SourceKind, _ p: Double, _ f: Flaw, _ l: Double, same: Int? = nil, delay: Double = 0, pol: Double = 1) -> Channel {
        Channel(name: String(n.prefix(12)), kind: k, pitch: p, flaw: f, levelDB: l, sameAs: same, delayMS: delay, physicalPolarity: pol)
    }

    /// Musical: band, two leads, backing vocals, a four-part choir and a small string section.
    public static let musical = AssistScenario(id: "musical", channels: [
        ch("Kick In", .kick, 55, .boom, -30), ch("Kick Out", .kick, 55, .dull, -32, same: 0, delay: 1),
        ch("Snare Top", .snare, 190, .harsh, -26), ch("Snare Btm", .snare, 190, .none, -28, same: 2, delay: 0.3, pol: -1),
        ch("OH L", .overhead, 0, .dull, -38), ch("Bass DI", .bassGuitar, 55, .mud, -24), ch("Keys L", .keys, 262, .none, -28),
        ch("Gtr", .electricGuitar, 196, .harsh, -30), ch("Vox Anna", .femaleVocal, 262, .mud, -42), ch("Vox Ivan", .maleVocal, 130, .harsh, -40),
        ch("BV 1", .backingVocal, 330, .boom, -44), ch("BV 2", .backingVocal, 220, .mud, -44),
        ch("Choir S", .choir, 392, .mud, -46), ch("Choir A", .choir, 294, .dull, -46), ch("Choir T", .choir, 220, .harsh, -45),
        ch("Choir B", .choir, 147, .boom, -45), ch("Violin 1", .violin, 440, .harsh, -42), ch("Violin 2", .violin, 392, .mud, -44),
        ch("Viola", .viola, 262, .dull, -44), ch("Cello", .cello, 98, .boom, -40),
    ])

    /// Rock band with doubled drum mics and a guitar on two mics.
    public static let rock = AssistScenario(id: "rock", channels: [
        ch("Kick In", .kick, 50, .boom, -28), ch("Kick Out", .kick, 50, .dull, -30, same: 0, delay: 1.2),
        ch("Snare Top", .snare, 200, .harsh, -24), ch("Snare Btm", .snare, 200, .none, -27, same: 2, delay: 0.3, pol: -1),
        ch("Tom 1", .tom, 110, .mud, -30), ch("Tom 2", .tom, 82, .mud, -30), ch("OH L", .overhead, 0, .dull, -36),
        ch("Bass DI", .bassGuitar, 41, .mud, -22), ch("Bass Mic", .bassGuitar, 41, .boom, -26, same: 7, delay: 2),
        ch("Gtr L", .electricGuitar, 165, .harsh, -28), ch("Gtr R", .electricGuitar, 165, .mud, -29, same: 9, delay: 0.5),
        ch("Keys", .keys, 220, .none, -30), ch("Vox Lead", .maleVocal, 147, .harsh, -38), ch("BV 1", .backingVocal, 220, .mud, -42),
    ])

    /// Chamber orchestra: one button "Orchestra" finds all of it by the names.
    public static let orchestra = AssistScenario(id: "orchestra", channels: [
        ch("Violin 1", .violin, 659, .harsh, -42), ch("Violin 2", .violin, 523, .harsh, -43), ch("Viola", .viola, 330, .mud, -44),
        ch("Cello", .cello, 131, .boom, -40), ch("Contrabass", .doubleBass, 55, .mud, -38), ch("Flute", .flute, 784, .dull, -44),
        ch("Clarinet", .clarinet, 392, .mud, -42), ch("Oboe", .oboe, 523, .harsh, -43), ch("Horn", .frenchHorn, 196, .boom, -40),
        ch("Trumpet", .trumpet, 466, .harsh, -38), ch("Timpani", .percussion, 98, .boom, -34), ch("Harp", .harp, 294, .dull, -44),
    ])

    public static let all: [AssistScenario] = [musical, rock, orchestra]
}

extension SimulatedConsole {
    /// Simulated musicians for a scenario, on console channels starting at `first`.
    public static func scenario(_ sc: AssistScenario, first: Int = 1, sampleRate: Double = 48000, seed: UInt64 = 7) -> SimulatedConsole {
        let c = SimulatedConsole(sampleRate: sampleRate, seed: seed)
        func coloring(_ f: AssistScenario.Flaw) -> [StripEQBand] {
            switch f {
            case .none: return []
            case .mud: return [StripEQBand(type: .peaking, frequency: 315, gainDB: 6, q: 1.2)]
            case .harsh: return [StripEQBand(type: .peaking, frequency: 3150, gainDB: 5, q: 2)]
            case .dull: return [StripEQBand(type: .highShelf, frequency: 5000, gainDB: -6)]
            case .boom: return [StripEQBand(type: .lowShelf, frequency: 150, gainDB: 6)]
            }
        }
        for (i, e) in sc.channels.enumerated() {
            let ch = first + i
            c.strips[ch] = ChannelStrip(id: ch, name: e.name, gainDB: 20, faderDB: -10)
            let vocalish = e.kind.family == .choir || e.kind.family == .vocals
            c.sources[ch] = Source(kind: e.kind, pitch: e.pitch, coloring: coloring(e.flaw), levelDB: e.levelDB,
                                   couplingDB: vocalish ? -18 : -30, sameSourceAs: e.sameAs.map { first + $0 },
                                   delayMS: e.delayMS, physicalPolarity: e.physicalPolarity)
        }
        for b in 1...4 { c.setBus(BusStrip(id: b, name: "Mon \(b)", faderDB: -3)) }
        c.loopAtDB = [2: 0]
        return c
    }
}

/// Compares what the assistant sent with what the console reports back, within the console's own parameter steps.
public enum ConsoleReadback {
    public struct Mismatch: Equatable, Sendable {
        public var channel: Int
        public var parameter: String
        public var sent: String
        public var read: String
    }

    /// Parameters of a strip that differ beyond the console's quantisation (X32 / X Air steps).
    public static func compare(sent a: ChannelStrip, read b: ChannelStrip) -> [Mismatch] {
        var out: [Mismatch] = []
        func check(_ name: String, _ x: Double, _ y: Double, tol: Double, fmt: String = "%.2f") {
            if abs(x - y) > tol { out.append(Mismatch(channel: a.id, parameter: name, sent: String(format: fmt, x), read: String(format: fmt, y))) }
        }
        func flag(_ name: String, _ x: Bool, _ y: Bool) {
            if x != y { out.append(Mismatch(channel: a.id, parameter: name, sent: "\(x)", read: "\(y)")) }
        }
        if a.name != b.name { out.append(Mismatch(channel: a.id, parameter: "name", sent: a.name, read: b.name)) }
        check("gain", a.gainDB, b.gainDB, tol: 0.6)
        flag("hpf on", a.highPassOn, b.highPassOn)
        if a.highPassOn { check("hpf Hz", a.highPassHz, b.highPassHz, tol: a.highPassHz * 0.04, fmt: "%.0f") }
        flag("polarity", a.polarityInverted, b.polarityInverted)
        flag("eq on", a.eqOn, b.eqOn)
        for (k, (x, y)) in zip(a.eq, b.eq).enumerated() {
            if x.type != y.type { out.append(Mismatch(channel: a.id, parameter: "eq\(k + 1) type", sent: x.type.rawValue, read: y.type.rawValue)) }
            check("eq\(k + 1) Hz", x.frequency, y.frequency, tol: x.frequency * 0.04, fmt: "%.0f")
            check("eq\(k + 1) dB", x.gainDB, y.gainDB, tol: 0.3)
            if x.type == .peaking { check("eq\(k + 1) Q", x.q, y.q, tol: x.q * 0.08) }
        }
        flag("comp on", a.compressor.enabled, b.compressor.enabled)
        if a.compressor.enabled {
            check("comp thr", a.compressor.thresholdDB, b.compressor.thresholdDB, tol: 0.6)
            check("comp ratio", a.compressor.ratio, b.compressor.ratio, tol: 0.01)
            check("comp att", a.compressor.attackMS, b.compressor.attackMS, tol: 1.1, fmt: "%.0f")
            check("comp rel", a.compressor.releaseMS, b.compressor.releaseMS, tol: a.compressor.releaseMS * 0.06, fmt: "%.0f")
            check("comp makeup", a.compressor.makeupDB, b.compressor.makeupDB, tol: 0.6)
        }
        if a.faderDB > -60 { check("fader", a.faderDB, b.faderDB, tol: 0.3) }
        flag("mute", a.muted, b.muted)
        return out
    }

    /// The strip a console stores for this one: values snapped to the console's own steps (X32 / X Air).
    public static func quantized(_ s: ChannelStrip, family: MixerFamily) -> ChannelStrip {
        var strips = [s.id: ChannelStrip(id: s.id)]
        // Quantization only: any routing that reaches the gain will do.
        let routing = X32InputRouting.localInputs
        for m in X32Codec.messages(from: nil, to: s, family: family, routing: routing) {
            var q = m
            if case let .float(v)? = m.arguments.first {
                // Floats are stored in fixed steps: 1024 for faders, 201 for frequencies, 72 for Q, 145 for gain…
                let steps: Double
                if m.address.hasSuffix("/fader") { steps = 1023 } else if m.address.hasSuffix("/f") { steps = 200 }
                else if m.address.hasSuffix("/q") { steps = 71 } else if m.address.hasSuffix("/g") { steps = 120 }
                else if m.address.hasSuffix("/gain") { steps = 144 } else if m.address.hasSuffix("/hpf") { steps = 100 }
                else if m.address.hasSuffix("/thr") { steps = 120 } else if m.address.hasSuffix("/mgain") { steps = 48 }
                else if m.address.hasSuffix("/attack") { steps = 120 } else if m.address.hasSuffix("/release") { steps = 100 }
                else { steps = 1000 }
                q = OSCMessage(m.address, [.float(Float((Double(v) * steps).rounded() / steps))])
            }
            X32Codec.apply(q, to: &strips, family: family, routing: routing)
        }
        var r = strips[s.id]!
        r.name = s.name
        return r
    }
}

/// One line of the console test report.
public struct ConsoleTestCheck: Equatable, Sendable, Identifiable {
    public enum Status: String, Sendable { case ok, warning, failed, running }
    public var id: String
    public var status: Status
    public var detail: String
    public init(id: String, status: Status, detail: String = "") { self.id = id; self.status = status; self.detail = detail }
}
