import Foundation

/// A console parameter as the console sends it: a number (normalized 0…1 for most controls, an index for switches
/// and choices) or a text (names).
public enum ParamValue: Codable, Equatable, Sendable {
    case number(Double)
    case text(String)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode(Double.self) { self = .number(d) } else { self = .text(try c.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case let .number(d): try c.encode(d)
        case let .text(s): try c.encode(s)
        }
    }

    public var number: Double? { if case let .number(d) = self { return d } else { return nil } }
    public var text: String? { if case let .text(s) = self { return s } else { return nil } }
}

/// What the meters showed during one second of a recording.
public struct LearnMeters: Codable, Equatable, Sendable {
    /// Channel levels, the peak of the second, dBFS (index 0 = channel 1).
    public var levels: [Double] = []
    /// Gate and compressor gain reduction per channel, the most of the second, dB (0 = none).
    public var gate: [Double] = []
    public var dyn: [Double] = []
    /// Output levels, peak of the second, dBFS. X32: buses 1–16, matrices 1–6, main L, main R, mono.
    /// X Air: buses 1–6, FX sends 1–4, main L, main R (and what follows).
    public var outs: [Double] = []
    /// Compressor gain reduction of the outputs, dB. X32: buses 1–16, matrices 1–6, main LR, mono. X Air: buses, main.
    public var outDyn: [Double] = []
    /// The console RTA (of whatever source the engineer chose on it), mean of the second, in one-third octaves
    /// (`ThirdOctave.centers`), dB.
    public var rta: [Double] = []

    public init() {}
}

/// Everything learning mode collects from a console besides the typed channel strips: every parameter the console
/// reports (by OSC address) and its meters, folded per second. Read-only: it only produces queries and meter requests.
public struct ConsoleCapture: Sendable {
    public let family: MixerFamily
    /// The last value of every parameter heard, by address.
    public private(set) var params: [String: ParamValue] = [:]
    let tree: [String]
    var cursor = 0
    /// Addresses asked per second on the first pass through the tree, then on later passes (a refresh).
    public var firstPassRate = 150
    public var refreshRate = 25
    public private(set) var passes = 0

    var levels: [Int: Double] = [:]
    var gate: [Int: Double] = [:]
    var dyn: [Int: Double] = [:]
    var outs: [Int: Double] = [:]
    var outDyn: [Int: Double] = [:]
    var rtaPower: [Double] = []
    var rtaFrames = 0

    public init(family: MixerFamily) {
        self.family = family
        tree = ConsoleTree.addresses(family)
    }

    /// Number of parameter addresses of the console.
    public var treeSize: Int { tree.count }

    /// Meter streams learning mode subscribes to (repeat within 10 s): channels with their gain reduction, outputs,
    /// the RTA and, on X Air, the gain-reduction bank.
    public static func meterRequests(family: MixerFamily) -> [OSCMessage] {
        var r = [ConsoleMeters.Bank.channels, .buses, .rta].map { ConsoleMeters.request($0, family: family) }
        if family == .xAir { r.append(OSCMessage("/meters", [.string("/meters/6")])) }
        return r
    }

    /// The next addresses to ask (one second's worth); the tree is walked again and again.
    public mutating func sweep() -> [OSCMessage] {
        guard !tree.isEmpty else { return [] }
        let n = min(tree.count, passes == 0 ? firstPassRate : refreshRate)
        var out: [OSCMessage] = []
        out.reserveCapacity(n)
        for _ in 0..<n {
            out.append(OSCMessage(tree[cursor]))
            cursor += 1
            if cursor == tree.count { cursor = 0; passes += 1 }
        }
        return out
    }

    /// Takes a message from the console: meters go into the second's window, a parameter into `params`.
    /// Returns false for anything else (identification, empty messages).
    @discardableResult
    public mutating func take(_ m: OSCMessage) -> Bool {
        if m.address.hasPrefix("/meters/") { return takeMeters(m) }
        if m.address == "/info" || m.address == "/xinfo" || m.address == "/status" || m.address.hasPrefix("/meters") { return false }
        guard let a = m.arguments.first else { return false }
        switch a {
        case let .float(f) where f.isFinite: params[m.address] = .number((Double(f) * 10000).rounded() / 10000)
        case let .int(i): params[m.address] = .number(Double(i))
        case let .string(s): params[m.address] = .text(s)
        case let .bool(b): params[m.address] = .number(b ? 1 : 0)
        default: return false
        }
        return true
    }

    /// The simulator has no OSC: its strips and buses are turned into the messages that would set them.
    public mutating func absorb(strips: [Int: ChannelStrip], buses: [Int: BusStrip]) {
        for s in strips.values {
            for m in X32Codec.messages(from: nil, to: s, family: .x32, routing: .localInputs) { take(m) }
        }
        for b in buses.values {
            for m in X32Codec.busMessages(from: nil, to: b, family: .x32) { take(m) }
        }
    }

    static func le32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }

    /// Meter blobs (layouts: ASSUMPTIONS A106). X32 `/meters/1`: 96 floats — 32 channel levels, 32 gate and 32
    /// compressor gain reductions; `/meters/2`: 49 floats — 25 output levels, then their 24 gain reductions;
    /// `/meters/15`: RTA. X Air: `/meters/1` channels, `/meters/5` outputs, `/meters/6` gain reductions (16 gate,
    /// 16 compressor, then outputs), `/meters/4` RTA, all as 16-bit 1/256 dB.
    mutating func takeMeters(_ m: OSCMessage) -> Bool {
        guard case let .blob(data)? = m.arguments.first else { return false }
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return false }
        let count = Int(Self.le32(bytes, 0))
        let body = Array(bytes.dropFirst(4))
        let shorts: [Double] = stride(from: 0, to: body.count - 1, by: 2).map {
            Double(Int16(bitPattern: UInt16(body[$0]) | UInt16(body[$0 + 1]) << 8)) / 256
        }
        let floats: [Double] = stride(from: 0, to: body.count - 3, by: 4).prefix(count).map {
            Decibel.fromAmplitude(Double(max(Float(bitPattern: Self.le32(body, $0)), 0)))
        }
        func peak(_ into: inout [Int: Double], _ values: ArraySlice<Double>) {
            for (k, v) in values.enumerated() where v.isFinite { into[k + 1] = max(into[k + 1] ?? -200, v) }
        }
        /// Gain reduction is kept as the most reduction (lowest gain) of the second.
        func least(_ into: inout [Int: Double], _ values: ArraySlice<Double>) {
            for (k, v) in values.enumerated() where v.isFinite { into[k + 1] = min(into[k + 1] ?? 0, min(0, v)) }
        }
        let path = String(m.address.dropFirst("/meters/".count))
        switch (family == .xAir, path) {
        case (false, "1"):
            peak(&levels, floats.prefix(32))
            if floats.count >= 96 { least(&gate, floats[32..<64]); least(&dyn, floats[64..<96]) }
        case (false, "2"):
            peak(&outs, floats.prefix(25))
            if floats.count > 25 { least(&outDyn, floats.dropFirst(25)) }
        case (false, "15"): addRTA(Array(shorts.prefix(100)))
        case (true, "1"): peak(&levels, shorts.prefix(16))
        case (true, "5"): peak(&outs, shorts[...])
        case (true, "6"):
            least(&gate, shorts.prefix(16))
            if shorts.count > 16 { least(&dyn, shorts.dropFirst(16).prefix(16)) }
            if shorts.count > 32 { least(&outDyn, shorts.dropFirst(32)) }
        case (true, "4"): addRTA(Array(shorts.prefix(100)))
        default: return false
        }
        return true
    }

    mutating func addRTA(_ bands: [Double]) {
        guard !bands.isEmpty else { return }
        let b = ConsoleMeters.thirdOctaves(fromRTA: bands)
        if rtaPower.count != b.count { rtaPower = [Double](repeating: 0, count: b.count); rtaFrames = 0 }
        for k in b.indices { rtaPower[k] += pow(10, b[k] / 10) }
        rtaFrames += 1
    }

    static func array(_ m: [Int: Double], rounding step: Double = 0.5) -> [Double] {
        guard let n = m.keys.max(), n > 0 else { return [] }
        return (1...n).map { k in
            guard let v = m[k], v.isFinite else { return -120 }
            return (max(-120, min(20, v)) / step).rounded() * step
        }
    }

    /// The meters of the second that just ended; starts the next one.
    public mutating func takeSecond() -> LearnMeters {
        var s = LearnMeters()
        s.levels = Self.array(levels)
        s.gate = Self.array(gate)
        s.dyn = Self.array(dyn)
        s.outs = Self.array(outs)
        s.outDyn = Self.array(outDyn)
        if rtaFrames > 0 {
            s.rta = rtaPower.map { (max(-120, Decibel.fromPower($0 / Double(rtaFrames) + 1e-15)) * 2).rounded() / 2 }
        }
        levels = [:]; gate = [:]; dyn = [:]; outs = [:]; outDyn = [:]
        rtaPower = []; rtaFrames = 0
        return s
    }
}
