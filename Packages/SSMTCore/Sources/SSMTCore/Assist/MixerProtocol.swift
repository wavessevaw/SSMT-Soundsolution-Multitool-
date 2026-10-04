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

    /// Preamp gain address. On X32 it lives on the head amp feeding the channel; this assumes local
    /// inputs patched 1:1 (channel n ← head amp n-1). X Air: /headamp/NN/gain.
    public static func gainAddress(_ ch: Int, family: MixerFamily) -> String {
        family == .xAir ? String(format: "/headamp/%02d/gain", ch) : String(format: "/headamp/%03d/gain", ch - 1)
    }

    public static func gainValue(_ db: Double, family: MixerFamily) -> Double {
        family == .xAir ? linUnmap(db, -12, 60) : linUnmap(db, -12, 60)
    }

    public static func gainDB(_ v: Double, family: MixerFamily) -> Double { linMap(v, -12, 60) }

    /// Every address of a strip the assistant reads (send each without arguments to query it).
    public static func queryAddresses(_ ch: Int, family: MixerFamily) -> [String] {
        let p = channelPath(ch)
        var a = ["\(p)/config/name", gainAddress(ch, family: family), "\(p)/preamp/hpon", "\(p)/preamp/hpf", "\(p)/eq/on",
                 "\(p)/dyn/on", "\(p)/dyn/thr", "\(p)/dyn/ratio", "\(p)/dyn/attack", "\(p)/dyn/release", "\(p)/dyn/knee",
                 "\(p)/dyn/mgain", "\(p)/mix/fader", "\(p)/mix/on", "\(p)/preamp/invert"]
        for b in 1...4 { a += ["\(p)/eq/\(b)/type", "\(p)/eq/\(b)/f", "\(p)/eq/\(b)/g", "\(p)/eq/\(b)/q"] }
        return a
    }

    static func eqType(_ t: EQBandType) -> Int32 { t == .lowShelf ? 1 : t == .highShelf ? 4 : 2 }
    static func eqType(_ i: Int32) -> EQBandType { i == 1 ? .lowShelf : i == 4 ? .highShelf : .peaking }

    /// Messages that set the console to `new`. Only parameters that differ from `old` are sent.
    public static func messages(from old: ChannelStrip?, to new: ChannelStrip, family: MixerFamily) -> [OSCMessage] {
        let p = channelPath(new.id)
        var out: [OSCMessage] = []
        func f(_ addr: String, _ v: Double) { out.append(OSCMessage(addr, [.float(Float(v))])) }
        func i(_ addr: String, _ v: Int32) { out.append(OSCMessage(addr, [.int(v)])) }
        func changed<T: Equatable>(_ k: KeyPath<ChannelStrip, T>) -> Bool { old.map { $0[keyPath: k] != new[keyPath: k] } ?? true }

        // The console keeps up to 12 characters (ASCII on the X32 screen).
        if changed(\.name) { out.append(OSCMessage("\(p)/config/name", [.string(String(new.name.prefix(12)))])) }
        if changed(\.gainDB) { f(gainAddress(new.id, family: family), gainValue(new.gainDB, family: family)) }
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
    public static func apply(_ m: OSCMessage, to strips: inout [Int: ChannelStrip], family: MixerFamily) -> Int? {
        let parts = m.address.split(separator: "/").map(String.init)
        guard let arg = m.arguments.first else { return nil }
        var num: Double? {
            switch arg { case let .float(v): return Double(v); case let .int(v): return Double(v); default: return nil }
        }
        if parts.count == 3, parts[0] == "headamp", let n = Int(parts[1]), parts[2] == "gain", let v = num {
            let ch = family == .xAir ? n : n + 1
            guard strips[ch] != nil else { return nil }
            strips[ch]!.gainDB = (gainDB(v, family: family) * 2).rounded() / 2
            return ch
        }
        guard parts.count >= 3, parts[0] == "ch", let ch = Int(parts[1]), strips[ch] != nil else { return nil }
        var s = strips[ch]!
        switch Array(parts[2...]) {
        case ["config", "name"]: if case let .string(t) = arg { s.name = t }
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
}
