import Foundation

/// Console families and how remote-control apps reach them.
/// Only families marked `implemented` can be driven by the assistant in this version; the others
/// are listed with their documented transport so the user knows what is coming.
public enum MixerFamily: String, Codable, Sendable, CaseIterable {
    /// Behringer X32 / Midas M32: OSC over UDP, port 10023.
    case x32
    /// Behringer X Air / Midas MR (XR12/16/18, X18, MR18): OSC over UDP, port 10024.
    case xAir
    /// Behringer WING: OSC on UDP 2223 (one subscriber); native binary protocol on TCP 2222.
    case wing
    /// Yamaha TF / CL / QL / DM: Remote Control Protocol (text commands) on TCP 49280.
    case yamaha
    /// Allen & Heath SQ / dLive / Avantis: MIDI over TCP, port 51325.
    case allenHeath
    /// Built-in console with simulated sources, for learning and testing without hardware.
    case simulator

    public var defaultPort: UInt16 {
        switch self {
        case .x32: return 10023
        case .xAir: return 10024
        case .wing: return 2223
        case .yamaha: return 49280
        case .allenHeath: return 51325
        case .simulator: return 0
        }
    }

    public var implemented: Bool { self == .x32 || self == .xAir || self == .simulator }

    public var channelCount: Int {
        switch self {
        case .x32: return 32
        case .xAir: return 16
        case .wing: return 40
        case .yamaha: return 64
        case .allenHeath: return 48
        case .simulator: return 16
        }
    }
}

/// Parameter laws and addresses of the X32 / M32 and X Air OSC dialect.
/// Value laws follow the community-documented X32 OSC protocol (P.-G. Maillot, "Unofficial X32/M32
/// OSC Remote Protocol"); X Air shares the channel address tree.
public enum X32Codec {
    // MARK: value laws (normalized 0…1 ⇄ engineering units)

    static func logMap(_ v: Double, _ lo: Double, _ hi: Double) -> Double { lo * pow(hi / lo, min(max(v, 0), 1)) }
    static func logUnmap(_ x: Double, _ lo: Double, _ hi: Double) -> Double { min(max(log(x / lo) / log(hi / lo), 0), 1) }
    static func linMap(_ v: Double, _ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * min(max(v, 0), 1) }
    static func linUnmap(_ x: Double, _ lo: Double, _ hi: Double) -> Double { min(max((x - lo) / (hi - lo), 0), 1) }

    /// Fader position → dB (four linear segments, 0 → -inf).
    public static func faderDB(_ f: Double) -> Double {
        if f <= 0 { return -144 }
        if f >= 0.5 { return f * 40 - 30 }
        if f >= 0.25 { return f * 80 - 50 }
        if f >= 0.0625 { return f * 160 - 70 }
        return f * 480 - 90
    }

    public static func faderPosition(_ db: Double) -> Double {
        if db <= -90 { return 0 }
        let f: Double
        if db < -60 { f = (db + 90) / 480 } else if db < -30 { f = (db + 70) / 160 } else if db < -10 { f = (db + 50) / 80 } else { f = (db + 30) / 40 }
        return min(max(f, 0), 1)
    }

    public static let ratios: [Double] = [1.1, 1.3, 1.5, 2, 2.5, 3, 4, 5, 7, 10, 20, 100]

    public static func ratioIndex(_ r: Double) -> Int {
        ratios.indices.min { abs(log(ratios[$0] / r)) < abs(log(ratios[$1] / r)) } ?? 5
    }

    // MARK: addresses

    public static func channelPath(_ ch: Int) -> String { String(format: "/ch/%02d", ch) }

    /// Input gain address of a channel: the head amp that feeds it (X32: found through the routing — local inputs,
    /// an AES50 stage box…), or the channel's digital trim when no head amp feeds it (card, aux, USB). nil while the
    /// routing is not known: the gain is then neither read nor written, never guessed.
    public static func gainAddress(_ ch: Int, family: MixerFamily, routing: X32InputRouting) -> String? {
        switch routing.gainControl(ch, family: family) {
        case let .headamp(n)?: return family == .xAir ? String(format: "/headamp/%02d/gain", n) : String(format: "/headamp/%03d/gain", n)
        case .trim?: return channelPath(ch) + "/preamp/trim"
        case nil: return nil
        }
    }

    /// Normalized value of a gain in dB for the channel's gain control (head amp −12…+60 dB, trim −18…+18 dB).
    public static func gainValue(_ db: Double, control: X32InputRouting.GainControl) -> Double {
        if case .trim = control { return linUnmap(db, -18, 18) }
        return linUnmap(db, -12, 60)
    }

    public static func gainDB(_ v: Double, control: X32InputRouting.GainControl) -> Double {
        if case .trim = control { return linMap(v, -18, 18) }
        return linMap(v, -12, 60)
    }

    /// Every address of a strip the assistant reads (send each without arguments to query it). The gain is asked
    /// only once the routing says where it is; on X32 the channel's input source is asked too.
    public static func queryAddresses(_ ch: Int, family: MixerFamily, routing: X32InputRouting = X32InputRouting()) -> [String] {
        let p = channelPath(ch)
        var a = ["\(p)/config/name", "\(p)/preamp/hpon", "\(p)/preamp/hpf", "\(p)/eq/on",
                 "\(p)/dyn/on", "\(p)/dyn/mode", "\(p)/dyn/thr", "\(p)/dyn/ratio", "\(p)/dyn/attack", "\(p)/dyn/release",
                 "\(p)/dyn/knee", "\(p)/dyn/mgain", "\(p)/mix/fader", "\(p)/mix/on", "\(p)/preamp/invert"]
        if family != .xAir { a.append("\(p)/config/source") }
        if let g = gainAddress(ch, family: family, routing: routing) { a.insert(g, at: 1) }
        for b in 1...4 { a += ["\(p)/eq/\(b)/type", "\(p)/eq/\(b)/f", "\(p)/eq/\(b)/g", "\(p)/eq/\(b)/q"] }
        return a
    }

    static func eqType(_ t: EQBandType) -> Int32 { t == .lowShelf ? 1 : t == .highShelf ? 4 : 2 }
    static func eqType(_ i: Int32) -> EQBandType { i == 1 ? .lowShelf : i == 4 ? .highShelf : .peaking }

    /// Messages that set the console to `new`. Only parameters that differ from `old` are sent.
    public static func messages(from old: ChannelStrip?, to new: ChannelStrip, family: MixerFamily,
                                routing: X32InputRouting = X32InputRouting()) -> [OSCMessage] {
        let p = channelPath(new.id)
        var out: [OSCMessage] = []
        func f(_ addr: String, _ v: Double) { out.append(OSCMessage(addr, [.float(Float(v))])) }
        func i(_ addr: String, _ v: Int32) { out.append(OSCMessage(addr, [.int(v)])) }
        func changed<T: Equatable>(_ k: KeyPath<ChannelStrip, T>) -> Bool { old.map { $0[keyPath: k] != new[keyPath: k] } ?? true }

        // The console keeps up to 12 characters (ASCII on the X32 screen).
        if changed(\.name) { out.append(OSCMessage("\(p)/config/name", [.string(String(new.name.prefix(12)))])) }
        if changed(\.gainDB), let control = routing.gainControl(new.id, family: family),
           let a = gainAddress(new.id, family: family, routing: routing) {
            f(a, gainValue(new.gainDB, control: control))
        }
        if changed(\.highPassOn) { i("\(p)/preamp/hpon", new.highPassOn ? 1 : 0) }
        if changed(\.highPassHz) { f("\(p)/preamp/hpf", logUnmap(new.highPassHz, 20, 400)) }
        if changed(\.eqOn) { i("\(p)/eq/on", new.eqOn ? 1 : 0) }
        for (n, b) in new.eq.prefix(4).enumerated() {
            let ob = old.flatMap { n < $0.eq.count ? $0.eq[n] : nil }
            let e = "\(p)/eq/\(n + 1)"
            if ob?.type != b.type { i("\(e)/type", eqType(b.type)) }
            if ob?.frequency != b.frequency { f("\(e)/f", logUnmap(b.frequency, 20, 20000)) }
            if ob?.gainDB != b.gainDB { f("\(e)/g", linUnmap(b.gainDB, -15, 15)) }
            if ob?.q != b.q { f("\(e)/q", 1 - logUnmap(b.q, 0.3, 10)) }
        }
        let c = new.compressor, oc = old?.compressor
        // The dynamics block is a compressor or an expander (X32 / X Air): the assistant's settings are a compressor's.
        if oc?.expander != c.expander { i("\(p)/dyn/mode", c.expander ? 1 : 0) }
        if oc?.enabled != c.enabled { i("\(p)/dyn/on", c.enabled ? 1 : 0) }
        if oc?.thresholdDB != c.thresholdDB { f("\(p)/dyn/thr", linUnmap(c.thresholdDB, -60, 0)) }
        if oc?.ratio != c.ratio { i("\(p)/dyn/ratio", Int32(ratioIndex(c.ratio))) }
        if oc?.attackMS != c.attackMS { f("\(p)/dyn/attack", linUnmap(c.attackMS, 0, 120)) }
        if oc?.releaseMS != c.releaseMS { f("\(p)/dyn/release", logUnmap(c.releaseMS, 5, 4000)) }
        if oc?.kneeDB != c.kneeDB { f("\(p)/dyn/knee", linUnmap(c.kneeDB, 0, 5)) }
        if oc?.makeupDB != c.makeupDB { f("\(p)/dyn/mgain", linUnmap(c.makeupDB, 0, 24)) }
        if changed(\.faderDB) { f("\(p)/mix/fader", faderPosition(new.faderDB)) }
        if changed(\.muted) { i("\(p)/mix/on", new.muted ? 0 : 1) }
        if changed(\.polarityInverted) { i("\(p)/preamp/invert", new.polarityInverted ? 1 : 0) }
        return out
    }

    /// Applies a reply (or a pushed update) to the strips it concerns. Returns the channel touched.
    @discardableResult
    public static func apply(_ m: OSCMessage, to strips: inout [Int: ChannelStrip], family: MixerFamily,
                             routing: X32InputRouting = X32InputRouting()) -> Int? {
        let parts = m.address.split(separator: "/").map(String.init)
        guard let arg = m.arguments.first else { return nil }
        var num: Double? {
            switch arg { case let .float(v): return Double(v); case let .int(v): return Double(v); default: return nil }
        }
        if parts.count == 3, parts[0] == "headamp", let n = Int(parts[1]), parts[2] == "gain", let v = num {
            // Every channel this head amp feeds (usually one).
            let fed = strips.keys.sorted().filter { routing.gainControl($0, family: family) == .headamp(n) }
            for ch in fed { strips[ch]!.gainDB = (linMap(v, -12, 60) * 2).rounded() / 2 }
            return fed.first
        }
        guard parts.count >= 3, parts[0] == "ch", let ch = Int(parts[1]), strips[ch] != nil else { return nil }
        var s = strips[ch]!
        switch Array(parts[2...]) {
        case ["config", "name"]: if case let .string(t) = arg { s.name = t }
        case ["preamp", "trim"]:
            guard routing.gainControl(ch, family: family) == .trim else { return nil }
            s.gainDB = (linMap(num ?? 0.5, -18, 18) * 2).rounded() / 2
        case ["dyn", "mode"]: s.compressor.expander = (num ?? 0) > 0
        case ["preamp", "hpon"]: s.highPassOn = (num ?? 0) > 0
        case ["preamp", "hpf"]: s.highPassHz = logMap(num ?? 0, 20, 400)
        case ["eq", "on"]: s.eqOn = (num ?? 0) > 0
        case ["dyn", "on"]: s.compressor.enabled = (num ?? 0) > 0
        case ["dyn", "thr"]: s.compressor.thresholdDB = linMap(num ?? 1, -60, 0)
        case ["dyn", "ratio"]: s.compressor.ratio = ratios[min(max(Int(num ?? 5), 0), ratios.count - 1)]
        case ["dyn", "attack"]: s.compressor.attackMS = linMap(num ?? 0, 0, 120)
        case ["dyn", "release"]: s.compressor.releaseMS = logMap(num ?? 0, 5, 4000)
        case ["dyn", "knee"]: s.compressor.kneeDB = linMap(num ?? 0, 0, 5)
        case ["dyn", "mgain"]: s.compressor.makeupDB = linMap(num ?? 0, 0, 24)
        case ["mix", "fader"]: s.faderDB = faderDB(num ?? 0)
        case ["mix", "on"]: s.muted = (num ?? 1) == 0
        case ["preamp", "invert"]: s.polarityInverted = (num ?? 0) > 0
        default:
            guard parts.count == 5, parts[2] == "eq", let b = Int(parts[3]), (1...4).contains(b), let v = num else { return nil }
            while s.eq.count < b { s.eq.append(StripEQBand(frequency: 1000)) }
            switch parts[4] {
            case "type": s.eq[b - 1].type = eqType(Int32(v))
            case "f": s.eq[b - 1].frequency = logMap(v, 20, 20000)
            case "g": s.eq[b - 1].gainDB = linMap(v, -15, 15)
            case "q": s.eq[b - 1].q = logMap(1 - v, 0.3, 10)
            default: return nil
            }
        }
        strips[ch] = s
        return ch
    }

    // MARK: mix buses (stage monitors)

    public static func busPath(_ id: Int, family: MixerFamily) -> String {
        family == .xAir ? "/bus/\(id)" : String(format: "/bus/%02d", id)
    }

    public static func busCount(_ family: MixerFamily) -> Int { family == .xAir ? 6 : 16 }

    public static func busQueryAddresses(_ id: Int, family: MixerFamily) -> [String] {
        let p = busPath(id, family: family)
        return ["\(p)/config/name", "\(p)/mix/fader", "\(p)/mix/on"]
    }

    public static func busMessages(from old: BusStrip?, to new: BusStrip, family: MixerFamily) -> [OSCMessage] {
        let p = busPath(new.id, family: family)
        var out: [OSCMessage] = []
        if old.map({ abs($0.faderDB - new.faderDB) > 0.01 }) ?? true { out.append(OSCMessage("\(p)/mix/fader", [.float(Float(faderPosition(new.faderDB)))])) }
        if old?.muted != new.muted { out.append(OSCMessage("\(p)/mix/on", [.int(new.muted ? 0 : 1)])) }
        return out
    }

    @discardableResult
    public static func apply(_ m: OSCMessage, toBuses buses: inout [Int: BusStrip]) -> Int? {
        let parts = m.address.split(separator: "/").map(String.init)
        guard parts.count == 4, parts[0] == "bus", let id = Int(parts[1]), var b = buses[id], let arg = m.arguments.first else { return nil }
        var num: Double? { switch arg { case let .float(v): return Double(v); case let .int(v): return Double(v); default: return nil } }
        switch (parts[2], parts[3]) {
        case ("config", "name"): if case let .string(t) = arg { b.name = t }
        case ("mix", "fader"): b.faderDB = faderDB(num ?? 0)
        case ("mix", "on"): b.muted = (num ?? 1) == 0
        default: return nil
        }
        buses[id] = b
        return id
    }

    /// Keeps the console sending parameter changes to us (must be repeated within 10 s).
    public static func subscribe(family: MixerFamily) -> OSCMessage { OSCMessage(family == .xAir ? "/xremote" : "/xremote") }

    /// Console identification request ("/info" → version, name, model, firmware).
    public static let info = OSCMessage("/info")

    /// On / off of the main stereo output (1 = on).
    public static func mainOnAddress(_ family: MixerFamily) -> String { family == .xAir ? "/lr/mix/on" : "/main/st/mix/on" }

    public static func faderAddress(_ ch: Int) -> String { channelPath(ch) + "/mix/fader" }
}

/// Console test "fader wave": every channel fader travels its whole range, top to bottom, as a sine wave that runs
/// across the console (each channel a little behind its left neighbour), so the smoothness of the motor faders
/// can be judged by eye.
public struct FaderWave: Sendable {
    /// Seconds for one fader to go top → bottom → top.
    public var cycleSeconds: Double
    /// How many waves are spread across the channels at once.
    public var wavesAcross: Double = 1

    public init(cycleSeconds: Double = 4) { self.cycleSeconds = cycleSeconds }

    /// Fader positions (0 = bottom, 1 = top) of channels 1…n at time `t` (seconds).
    public func positions(at t: Double, channels n: Int) -> [Double] {
        guard n > 0 else { return [] }
        let c = max(0.2, cycleSeconds)
        return (0..<n).map { i in 0.5 + 0.5 * sin(2 * .pi * (t / c - wavesAcross * Double(i) / Double(n))) }
    }

    /// The OSC messages that put the console's faders where the wave is at `t`.
    public func messages(at t: Double, channels n: Int) -> [OSCMessage] {
        positions(at: t, channels: n).enumerated().map { OSCMessage(X32Codec.faderAddress($0.offset + 1), [.float(Float($0.element))]) }
    }
}

/// Which head amp feeds each channel of an X32 / M32 (local inputs, AES50 A / B stage boxes, card…), so the
/// assistant changes the gain of the right preamp. Read from the console:
///  - `/config/routing/IN/1-8` … `/25-32`: the source block of the console's 32 inputs, in groups of eight
///    (0…3 local AN1-8…AN25-32, 4…9 AES50 A1-8…A41-48, 10…15 AES50 B1-8…B41-48, 16…19 card 1-8…25-32);
///  - `/ch/NN/config/source`: the input a channel takes (0 off, 1…32 inputs 1…32, then aux, USB, FX, buses).
/// Head amps: 0…31 local, 32…79 AES50 A, 80…127 AES50 B. X Air: channel n is head amp n.
/// After the public unofficial protocol description; not yet verified on a live console (ASSUMPTIONS A99).
public struct X32InputRouting: Equatable, Sendable {
    public enum GainControl: Equatable, Sendable {
        /// An analogue preamp (head amp index).
        case headamp(Int)
        /// No preamp feeds the channel: its digital trim (−18…+18 dB).
        case trim
    }

    /// `/config/routing/IN` block (0…3 for inputs 1-8 … 25-32) → its source.
    public var blocks: [Int: Int] = [:]
    /// Channel → `/ch/NN/config/source`.
    public var sources: [Int: Int] = [:]

    public init() {}

    /// A console with its 32 local inputs on channels 1…32 (the factory routing).
    public static var localInputs: X32InputRouting {
        var r = X32InputRouting()
        for b in 0..<4 { r.blocks[b] = b }
        for c in 1...32 { r.sources[c] = c }
        return r
    }

    public static let blockAddresses = ["/config/routing/IN/1-8", "/config/routing/IN/9-16", "/config/routing/IN/17-24",
                                        "/config/routing/IN/25-32"]

    /// Where the gain of channel `ch` is set; nil while not known yet.
    public func gainControl(_ ch: Int, family: MixerFamily) -> GainControl? {
        if family == .xAir { return .headamp(ch) }
        guard let src = sources[ch] else { return nil }
        guard (1...32).contains(src) else { return .trim }   // off, aux, USB, FX returns, buses
        guard let block = blocks[(src - 1) / 8] else { return nil }
        let k = (src - 1) % 8
        switch block {
        case 0...3: return .headamp(block * 8 + k)
        case 4...9: return .headamp(32 + (block - 4) * 8 + k)
        case 10...15: return .headamp(80 + (block - 10) * 8 + k)
        default: return .trim                                  // card inputs: no preamp
        }
    }

    /// Takes a routing reply; true when it was one.
    @discardableResult
    public mutating func apply(_ m: OSCMessage) -> Bool {
        guard let arg = m.arguments.first else { return false }
        let v: Int
        switch arg { case let .int(i): v = Int(i); case let .float(f): v = Int(f); default: return false }
        if let i = Self.blockAddresses.firstIndex(of: m.address) { blocks[i] = v; return true }
        let parts = m.address.split(separator: "/").map(String.init)
        if parts.count == 4, parts[0] == "ch", let ch = Int(parts[1]), parts[2] == "config", parts[3] == "source" {
            sources[ch] = v
            return true
        }
        return false
    }
}
