import Foundation

/// How the console test talks to a console: the real one over UDP (app) or the emulator (tests).
public protocol ConsoleTransport: AnyObject {
    func send(_ messages: [OSCMessage])
    /// Sends each address without arguments (a query) and returns the replies that arrived within `timeout` s.
    func query(_ addresses: [String], timeout: Double) async -> [OSCMessage]
    /// Waits for any message whose address starts with `prefix`.
    func waitFor(prefix: String, timeout: Double) async -> OSCMessage?
}

/// Console test with simulation on a real console: the assistant's whole cycle runs on the console with made-up
/// musicians, and every value it writes is read back. Steps:
///  1. the console answers (/info);  2. backup of the channels and monitor buses used;  3. names and a neutral
///  start written and read back;  4. soundcheck of all channels at once (gain, filters, EQ, compressor, faders);
///  5. polarity check;  6. one-button groups find their channels by the new names;  7. show guard on a monitor
///  loop;  8. meter streams (channels, buses, RTA);  9. the console put back exactly as it was.
public final class ConsoleTestRunner {
    public let scenario: AssistScenario
    public let family: MixerFamily
    public let first: Int
    public let transport: ConsoleTransport
    /// Mute the main output for the duration (nothing can reach the PA).
    public var muteMain = true
    /// Seconds of simulated audio per assistant step (2 in the app; shorter in tests).
    public var windowSeconds = 2.0
    public var maxSteps = 40
    public private(set) var checks: [ConsoleTestCheck] = []
    public var onProgress: (([ConsoleTestCheck]) -> Void)?
    public var character: MixCharacter = .musical

    var backup: [Int: ChannelStrip] = [:]
    var busBackup: [Int: BusStrip] = [:]
    var sent: [Int: ChannelStrip] = [:]
    var sim: SimulatedConsole
    /// Which head amp feeds each channel, read from the console before any gain is touched.
    var routing = X32InputRouting()

    public init(scenario: AssistScenario, family: MixerFamily, firstChannel: Int = 1, transport: ConsoleTransport) {
        self.scenario = scenario
        self.family = family
        first = firstChannel
        self.transport = transport
        sim = SimulatedConsole.scenario(scenario, first: firstChannel)
    }

    var channels: [Int] { (0..<scenario.channels.count).map { first + $0 } }

    func report(_ id: String, _ status: ConsoleTestCheck.Status, _ detail: String = "") {
        if let i = checks.firstIndex(where: { $0.id == id }) { checks[i] = ConsoleTestCheck(id: id, status: status, detail: detail) }
        else { checks.append(ConsoleTestCheck(id: id, status: status, detail: detail)) }
        onProgress?(checks)
    }

    var mainOnAddress: String { family == .xAir ? "/lr/mix/on" : "/main/st/mix/on" }

    /// Reads strips back from the console (the routing first, so the gains are read from the right preamps).
    func readStrips(_ chans: [Int]) async -> [Int: ChannelStrip] {
        routing = await ConsoleBackup.readRouting(transport, channels: chans, family: family, into: routing)
        var map = Dictionary(uniqueKeysWithValues: chans.map { ($0, ChannelStrip(id: $0)) })
        let replies = await transport.query(chans.flatMap { X32Codec.queryAddresses($0, family: family, routing: routing) }, timeout: 1.5)
        for m in replies { X32Codec.apply(m, to: &map, family: family, routing: routing) }
        return map
    }

    func readBuses(_ ids: [Int]) async -> [Int: BusStrip] {
        var map = Dictionary(uniqueKeysWithValues: ids.map { ($0, BusStrip(id: $0)) })
        let replies = await transport.query(ids.flatMap { X32Codec.busQueryAddresses($0, family: family) }, timeout: 1.5)
        for m in replies { X32Codec.apply(m, toBuses: &map) }
        return map
    }

    /// Sends strips (only what changed against what was sent before).
    func write(_ strips: [ChannelStrip]) {
        for s in strips {
            transport.send(X32Codec.messages(from: sent[s.id], to: s, family: family, routing: routing))
            sent[s.id] = s
            sim.setStrip(s)
        }
    }

    /// Reads everything sent back and reports the mismatches.
    func verify(_ id: String, okDetail: String) async {
        let read = await readStrips(channels)
        var bad: [ConsoleReadback.Mismatch] = []
        for ch in channels { if let s = sent[ch], let r = read[ch] { bad += ConsoleReadback.compare(sent: s, read: r) } }
        if bad.isEmpty { report(id, .ok, okDetail) }
        else {
            let list = bad.prefix(6).map { "ch\($0.channel) \($0.parameter): \($0.sent) → \($0.read)" }.joined(separator: "; ")
            report(id, .failed, "\(bad.count): " + list)
        }
    }

    public func run() async -> [ConsoleTestCheck] {
        checks = []
        // 1. Connection.
        report("connect", .running)
        transport.send([X32Codec.info, X32Codec.subscribe(family: family)])
        guard let info = await transport.waitFor(prefix: "/info", timeout: 3) else {
            report("connect", .failed, "no answer to /info")
            return checks
        }
        report("connect", .ok, info.arguments.compactMap { if case let .string(s) = $0 { return s } else { return nil } }.joined(separator: " · "))

        // 2. Backup.
        report("backup", .running)
        backup = await readStrips(channels)
        busBackup = await readBuses(Array(1...4))
        let gotNames = backup.values.filter { !$0.name.isEmpty || $0.gainDB != 20 }.count
        report("backup", gotNames > 0 || !backup.isEmpty ? .ok : .warning, "\(backup.count) ch, \(busBackup.count) bus")
        if muteMain { transport.send([OSCMessage(mainOnAddress, [.int(0)])]) }

        // 3. Names and a neutral start.
        report("names", .running)
        var start: [ChannelStrip] = []
        for (i, e) in scenario.channels.enumerated() {
            var s = ChannelStrip(id: first + i, name: e.name, gainDB: 20, faderDB: -10)
            s.eq = ChannelStrip.flatEQ
            start.append(s)
        }
        sent = backup
        write(start)
        for b in 1...4 { transport.send(X32Codec.busMessages(from: nil, to: BusStrip(id: b, name: "", faderDB: -3), family: family)) }
        await verify("names", okDetail: scenario.channels.map(\.name).joined(separator: ", "))

        // 4. Soundcheck: all channels at once.
        report("tuning", .running)
        let session = AssistSession(strips: channels.compactMap { sent[$0] }, character: character)
        session.startGroup(.range(first, first + scenario.channels.count - 1))
        var steps = 0
        while session.isRunning && steps < maxSteps {
            let r = sim.render(seconds: windowSeconds, channels: session.listening)
            write(session.tick(taps: r.taps, mic: r.mic))
            steps += 1
        }
        let tuned = session.group?.doneMembers ?? 0
        let gains = session.log.filter { if case .gain = $0.note { return true }; return false }.count
        let eqs = session.log.filter { if case .eqBand = $0.note { return true }; return false }.count
        let comps = session.log.filter { if case .compressor = $0.note { return true }; return false }.count
        await verify("tuning", okDetail: "\(tuned)/\(scenario.channels.count) ready in \(steps) steps · gain \(gains) · EQ \(eqs) · comp \(comps)")

        // 5. Polarity.
        report("polarity", .running)
        let pairs = PolarityPairs.find(in: channels.compactMap { sent[$0] })
        if pairs.isEmpty {
            report("polarity", .warning, "no pairs in this scenario")
        } else {
            for p in pairs {
                // Only the pair plays (a line check), the rest of the stage is quiet.
                let quiet = channels.filter { $0 != p.reference && $0 != p.test }
                for ch in quiet { if var s = sim.strips[ch] { s.muted = true; sim.setStrip(s) } }
                let ps = AssistSession(strips: channels.compactMap { sent[$0] }, character: character)
                ps.startPolarity([p])
                var n = 0
                while ps.isRunning && n < 40 {
                    let r = sim.render(seconds: 1, channels: [p.reference, p.test])
                    write(ps.tick(taps: r.taps, mic: r.mic))
                    n += 1
                }
                for ch in quiet { if var s = sim.strips[ch] { s.muted = sent[ch]?.muted ?? false; sim.setStrip(s) } }
            }
            let inverted = pairs.filter { sent[$0.test]?.polarityInverted == true }.map { sent[$0.test]!.name }
            await verify("polarity", okDetail: "\(pairs.count) pairs · inverted: " + (inverted.isEmpty ? "—" : inverted.joined(separator: ", ")))
        }

        // 6. One-button groups find their channels by the names written.
        let strips = channels.compactMap { sent[$0] }
        let orch = AssistGroupSelection.orchestra.channels(in: strips).count
        let choir = AssistGroupSelection.choir.channels(in: strips).count
        report("groups", .ok, "orchestra \(orch) · choir \(choir)")

        // 7. Show guard: the engineer pushes the choir wedges into a loop.
        report("guard", .running)
        let buses = Dictionary(uniqueKeysWithValues: (1...4).map { ($0, BusStrip(id: $0, name: "Mon \($0)", faderDB: -3)) })
        for b in buses.values { transport.send([OSCMessage(X32Codec.busPath(b.id, family: family) + "/config/name", [.string(b.name)])]) }
        let guardian = ShowGuard(strips: strips, buses: Array(buses.values), character: character)
        var pushed = buses[2]!
        pushed.faderDB = 1
        transport.send(X32Codec.busMessages(from: buses[2], to: pushed, family: family))
        sim.setBus(pushed)
        guardian.consoleChanged(bus: pushed, time: -40)
        var dipped = false, restored = false
        let playing = channels.prefix(6)
        for t in 0..<45 {
            let r = sim.render(seconds: 0.25, channels: Array(playing))
            let ex = FeatureExtractor()
            let feats = r.taps.mapValues { ex.analyze($0.count >= 4096 ? $0 : $0 + [Float](repeating: 0, count: 4096 - $0.count)) }
            let res = guardian.step(time: Double(t), channels: feats, busLevels: sim.busLevels(channelRMS: feats.mapValues(\.rmsDB)))
            for b in res.buses {
                transport.send(X32Codec.busMessages(from: sim.buses[b.id], to: b, family: family))
                sim.setBus(b)
            }
            if res.actions.contains(where: { if case .monitorDip = $0 { return true }; return false }) {
                dipped = true
                let back = await readBuses([2])
                if abs((back[2]?.faderDB ?? 99) - (sim.buses[2]?.faderDB ?? 0)) > 0.3 { report("guard", .failed, "bus fader not read back") }
            }
            if res.actions.contains(where: { if case .monitorHeld = $0 { return true }; if case .monitorRestored = $0 { return true }; return false }) { restored = true }
        }
        let finalBus = await readBuses([2])
        if checks.first(where: { $0.id == "guard" })?.status != .failed {
            report("guard", dipped ? .ok : .failed, String(format: "Mon 2: loop at +1 dB → %@ · now %.1f dB", dipped ? (restored ? "dipped and brought back" : "dipped") : "not caught", finalBus[2]?.faderDB ?? .nan))
        }

        // 8. Meter streams.
        report("meters", .running)
        var got: [String] = []
        for bank in [ConsoleMeters.Bank.channels, .buses, .rta] {
            let req = ConsoleMeters.request(bank, family: family)
            transport.send([req])
            if case let .string(path)? = req.arguments.first, let m = await transport.waitFor(prefix: path, timeout: 1.5),
               let (_, values) = ConsoleMeters.decode(m, family: family) {
                got.append("\(bank.rawValue) \(values.count)")
            }
        }
        report("meters", got.count == 3 ? .ok : (got.isEmpty ? .failed : .warning), got.isEmpty ? "no meter blobs" : got.joined(separator: " · "))

        // 9. Put the console back exactly as it was.
        report("restore", .running)
        for ch in channels { if let b = backup[ch] { transport.send(X32Codec.messages(from: nil, to: b, family: family, routing: routing)) } }
        for (_, b) in busBackup { transport.send(X32Codec.busMessages(from: nil, to: b, family: family) + [OSCMessage(X32Codec.busPath(b.id, family: family) + "/config/name", [.string(b.name)])]) }
        if muteMain { transport.send([OSCMessage(mainOnAddress, [.int(1)])]) }
        sent = backup
        await verify("restore", okDetail: "\(channels.count) channels and 4 buses as before the test")
        return checks
    }
}

/// A software X32 / X Air for tests: stores every value in the console's own steps and answers queries,
/// /info and meter requests the way the real console does.
public final class ConsoleEmulator: ConsoleTransport {
    public let family: MixerFamily
    public private(set) var values: [String: OSCArgument] = [:]
    public private(set) var received: [OSCMessage] = []
    var outbox: [OSCMessage] = []

    public init(family: MixerFamily = .x32) {
        self.family = family
        // Factory routing: local inputs on channels 1…32 (X Air: channel n = head amp n).
        let routing = X32InputRouting.localInputs
        if family != .xAir {
            for (i, a) in X32InputRouting.blockAddresses.enumerated() { values[a] = .int(Int32(i)) }
        }
        for ch in 1...family.channelCount {
            let p = X32Codec.channelPath(ch)
            values["\(p)/config/name"] = .string("")
            values["\(p)/dyn/mode"] = .int(0)
            if family != .xAir { values["\(p)/config/source"] = .int(Int32(ch)) }
            if let control = routing.gainControl(ch, family: family), let a = X32Codec.gainAddress(ch, family: family, routing: routing) {
                values[a] = .float(Float(X32Codec.gainValue(20, control: control)))
            }
        }
    }

    static func steps(_ address: String) -> Double? {
        let table: [(String, Double)] = [("/fader", 1023), ("/f", 200), ("/q", 71), ("/g", 120), ("/gain", 144), ("/hpf", 100),
                                         ("/thr", 120), ("/mgain", 48), ("/attack", 120), ("/release", 100), ("/knee", 5)]
        return table.first { address.hasSuffix($0.0) }?.1
    }

    func handle(_ m: OSCMessage) {
        received.append(m)
        switch m.address {
        case "/info": outbox.append(OSCMessage("/info", [.string("V2.07"), .string("osc-server"), .string(family == .xAir ? "XR18" : "X32"), .string("4.06")]))
        case "/xremote": break
        case "/meters":
            guard case let .string(path)? = m.arguments.first else { return }
            let count: Int = path == "/meters/15" || path == "/meters/4" ? 50 : (path == "/meters/2" ? 49 : 96)
            var d = Data()
            withUnsafeBytes(of: UInt32(count).littleEndian) { d.append(contentsOf: $0) }
            d.append(Data(repeating: 0, count: count * 4))
            outbox.append(OSCMessage(path, [.blob(d)]))
        default:
            if let v = m.arguments.first {
                if case let .float(f) = v, let n = Self.steps(m.address) { values[m.address] = .float(Float((Double(f) * n).rounded() / n)) }
                else if case let .string(s) = v { values[m.address] = .string(String(s.prefix(12))) }
                else { values[m.address] = v }
            } else if let v = values[m.address] {
                outbox.append(OSCMessage(m.address, [v]))
            }
        }
    }

    public func send(_ messages: [OSCMessage]) {
        // Through the wire format, as a real console would see it.
        for m in messages { if let d = OSCMessage.decode(m.encoded()) { d.forEach(handle) } }
    }

    public func query(_ addresses: [String], timeout: Double) async -> [OSCMessage] {
        outbox.removeAll()
        send(addresses.map { OSCMessage($0) })
        defer { outbox.removeAll() }
        return outbox
    }

    public func waitFor(prefix: String, timeout: Double) async -> OSCMessage? {
        defer { outbox.removeAll() }
        return outbox.first { $0.address.hasPrefix(prefix) }
    }
}

/// Reading a console's channels and monitor buses before the assistant plays on it, and putting them back.
public enum ConsoleBackup {
    /// X32 / M32: the input routing and the channels' sources (X Air needs none).
    public static func readRouting(_ t: ConsoleTransport, channels: [Int], family: MixerFamily,
                                   into routing: X32InputRouting = X32InputRouting()) async -> X32InputRouting {
        guard family != .xAir else { return routing }
        var r = routing
        let asks = X32InputRouting.blockAddresses + channels.map { X32Codec.channelPath($0) + "/config/source" }
        for m in await t.query(asks, timeout: 1.5) { r.apply(m) }
        return r
    }

    public static func read(_ t: ConsoleTransport, channels: [Int], buses: [Int], family: MixerFamily,
                            routing: X32InputRouting) async -> ([Int: ChannelStrip], [Int: BusStrip]) {
        var strips = Dictionary(uniqueKeysWithValues: channels.map { ($0, ChannelStrip(id: $0)) })
        for m in await t.query(channels.flatMap { X32Codec.queryAddresses($0, family: family, routing: routing) }, timeout: 1.5) {
            X32Codec.apply(m, to: &strips, family: family, routing: routing)
        }
        var bs = Dictionary(uniqueKeysWithValues: buses.map { ($0, BusStrip(id: $0)) })
        for m in await t.query(buses.flatMap { X32Codec.busQueryAddresses($0, family: family) }, timeout: 1.5) {
            X32Codec.apply(m, toBuses: &bs)
        }
        return (strips, bs)
    }

    public static func restore(_ t: ConsoleTransport, strips: [Int: ChannelStrip], buses: [Int: BusStrip], family: MixerFamily,
                               routing: X32InputRouting) {
        for s in strips.values.sorted(by: { $0.id < $1.id }) { t.send(X32Codec.messages(from: nil, to: s, family: family, routing: routing)) }
        for b in buses.values.sorted(by: { $0.id < $1.id }) {
            t.send(X32Codec.busMessages(from: nil, to: b, family: family)
                   + [OSCMessage(X32Codec.busPath(b.id, family: family) + "/config/name", [.string(b.name)])])
        }
    }
}
