import Foundation
import SSMTCore

// SSMT engine for the Windows app. Reads one JSON command per line on stdin, writes one JSON event per line on
// stdout. Packets for the console go out as "send" events (the interface owns the UDP socket) and the console's
// packets come back as "osc" commands. With a real console the engine is read-only: every packet passes through
// `ConsoleReadOnly`, and soundcheck commands are taken in the simulator only.

let engineVersion = "1.5.1"

// MARK: - I/O

enum Out {
    static func emit(_ event: String, _ fields: [String: Any] = [:]) {
        var obj = fields
        obj["event"] = event
        guard JSONSerialization.isValidJSONObject(obj),
              var data = try? JSONSerialization.data(withJSONObject: obj, options: []) else { return }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }

    /// A Codable value as a JSON object for `emit`.
    static func json<T: Encodable>(_ v: T) -> Any {
        guard let d = try? JSONEncoder().encode(v), let o = try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]) else { return NSNull() }
        return o
    }
}

/// Lines read from stdin on a background thread, taken by the main loop.
final class Inbox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private var ended = false

    func push(_ s: String) { lock.lock(); lines.append(s); lock.unlock() }
    func end() { lock.lock(); ended = true; lock.unlock() }
    func drain() -> (lines: [String], ended: Bool) {
        lock.lock(); defer { lock.unlock() }
        let l = lines
        lines = []
        return (l, ended)
    }
}

// MARK: - Engine

final class Engine {
    var dataDir: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/SSMT")
    var learnDir: URL { dataDir.appendingPathComponent("Learning", isDirectory: true) }

    var family: MixerFamily?
    var host = ""
    var status = "disconnected"
    var model = ""
    var routingPreset = X32InputRouting.Preset.local
    var routing = X32InputRouting.localInputs
    var character = MixCharacter.musical

    var strips: [Int: ChannelStrip] = [:]
    var buses: [Int: BusStrip] = [:]
    var channelLevels: [Int: Double] = [:]
    var busLevels: [Int: Double] = [:]
    var heard: Set<String> = []
    var lastHeard = Date.distantPast
    var connectedAt = Date()

    var sim: SimulatedConsole?
    var session: AssistSession?
    var references: [Int: [Double]] = [:]

    var recorder: LearningRecorder?
    /// Every parameter and meter of the console while connected (read-only).
    var capture: ConsoleCapture?
    /// Console parameters in the last frame.
    var learnParams = 0
    var recordFile: FileHandle?
    var recordURL: URL?
    var learnStartedAt = Date()

    var stateDirty = false
    var nextState = Date()
    var nextMeters = Date()
    var nextRenew = Date.distantFuture
    var nextJobStep = Date.distantFuture
    var nextLearnFrame = Date.distantFuture
    var nextSimLevels = Date.distantFuture
    var askAgain: [Date] = []
    var lastAlive = false

    var isReal: Bool { family == .x32 || family == .xAir }

    // MARK: commands

    func handle(_ line: String) {
        guard let d = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let cmd = obj["cmd"] as? String else { return }
        func str(_ k: String) -> String? { obj[k] as? String }
        func int(_ k: String) -> Int? { (obj[k] as? NSNumber)?.intValue }
        switch cmd {
        case "hello":
            if let dir = str("dataDir"), !dir.isEmpty { dataDir = URL(fileURLWithPath: dir, isDirectory: true) }
            Out.emit("hello", ["version": engineVersion, "dataDir": dataDir.path])
            emitRecordings()
        case "connect":
            connect(family: MixerFamily(rawValue: str("family") ?? "") ?? .simulator, host: str("host") ?? "")
        case "disconnect":
            disconnect()
        case "osc":
            if let b = str("data"), let data = Data(base64Encoded: b), let msgs = OSCMessage.decode(data) { msgs.forEach(received) }
        case "discovered":
            if let b = str("data"), let data = Data(base64Encoded: b), let msgs = OSCMessage.decode(data) {
                let fam: MixerFamily = int("port") == 10024 ? .xAir : .x32
                for m in msgs {
                    if let c = ConsoleDiscovery.parse(m, sender: str("sender") ?? "", family: fam) {
                        Out.emit("found", ["family": c.family.rawValue, "ip": c.ip, "name": c.name, "model": c.model, "firmware": c.firmware])
                    }
                }
            }
        case "routing":
            routingPreset = X32InputRouting.Preset(rawValue: str("preset") ?? "") ?? .local
            routing = X32InputRouting.preset(routingPreset) ?? X32InputRouting()
            if isReal { sendToConsole(ConsoleReadOnly.connectRequests(family: family!, routing: routing)) }
        case "character":
            character = MixCharacter(rawValue: str("value") ?? "") ?? .musical
            session?.character = character
        case "tune":
            guard let session, sim != nil, let ch = int("channel") else { return refuse(cmd) }
            session.startChannel(ch)
            beginJob()
        case "tuneGroup":
            guard let session, sim != nil else { return refuse(cmd) }
            let sel: AssistGroupSelection
            switch str("group") {
            case "choir": sel = .choir
            case "range": sel = .range(int("from") ?? 1, int("to") ?? 8)
            default: sel = .orchestra
            }
            if session.startGroup(sel).isEmpty { Out.emit("message", ["key": "nothingFound"]) } else { beginJob() }
        case "polarity":
            guard let session, sim != nil else { return refuse(cmd) }
            if session.startPolarity().isEmpty { Out.emit("message", ["key": "nothingFound"]) } else { beginJob() }
        case "stopJob":
            session?.stop()
            nextJobStep = .distantFuture
            stateDirty = true
        case "undo":
            guard let session, let sim else { return refuse(cmd) }
            for s in session.undo() { strips[s.id] = s; sim.setStrip(s) }
            nextJobStep = .distantFuture
            stateDirty = true
        case "learnStart":
            learnStart(title: str("title") ?? "")
        case "learnStop":
            learnStop()
        case "recordings":
            emitRecordings()
        case "state":
            emitState()
            emitLearn()
        case "deleteRecording":
            if let f = str("file"), !f.contains("/"), !f.contains("\\") {
                try? FileManager.default.removeItem(at: learnDir.appendingPathComponent(f))
            }
            emitRecordings()
        case "patterns":
            let p = patterns()
            Out.emit("patterns", ["patterns": Out.json(p), "summary": p.summary(russian: str("lang") != "en")])
        case "prompt":
            let p = patterns()
            Out.emit("prompt", ["id": str("id") ?? "", "text": p.prompt(question: str("question") ?? "", russian: str("lang") != "en")])
        default:
            Out.emit("error", ["key": "unknownCommand", "detail": cmd])
        }
    }

    func refuse(_ cmd: String) { Out.emit("message", ["key": "simulatorOnly", "detail": cmd]) }

    // MARK: connection

    func connect(family f: MixerFamily, host h: String) {
        disconnect()
        family = f
        host = h
        connectedAt = Date()
        switch f {
        case .simulator:
            let c = SimulatedConsole.demo()
            sim = c
            strips = c.strips
            buses = c.buses
            model = "SSMT simulator"
            status = "connected"
            session = AssistSession(strips: strips.values.sorted { $0.id < $1.id }, character: character)
            nextSimLevels = Date()
        case .x32, .xAir:
            status = "connecting"
            model = ""
            strips = Dictionary(uniqueKeysWithValues: (1...f.channelCount).map { ($0, ChannelStrip(id: $0)) })
            buses = Dictionary(uniqueKeysWithValues: (1...X32Codec.busCount(f)).map { ($0, BusStrip(id: $0)) })
            routing = X32InputRouting.preset(routingPreset) ?? X32InputRouting()
            heard = []
            capture = ConsoleCapture(family: f)
            Out.emit("link", ["host": h, "port": Int(f.defaultPort)])
            sendToConsole(ConsoleReadOnly.connectRequests(family: f, routing: routing))
            nextRenew = Date().addingTimeInterval(8)
            askAgain = [2.5, 5, 9].map { Date().addingTimeInterval($0) }
        default:
            status = "failed"
            Out.emit("message", ["key": "notSupported"])
        }
        stateDirty = true
    }

    func disconnect() {
        if recorder != nil { learnStop() }
        if isReal { Out.emit("unlink") }
        family = nil
        capture = nil
        sim = nil
        session = nil
        strips = [:]
        buses = [:]
        channelLevels = [:]
        busLevels = [:]
        status = "disconnected"
        nextRenew = .distantFuture
        nextJobStep = .distantFuture
        nextSimLevels = .distantFuture
        askAgain = []
        stateDirty = true
    }

    /// Packets for the console. Read-only: anything that would set a value is dropped here.
    func sendToConsole(_ msgs: [OSCMessage]) {
        let allowed = ConsoleReadOnly.filter(msgs)
        guard !allowed.isEmpty else { return }
        Out.emit("send", ["packets": allowed.map { $0.encoded().base64EncodedString() }])
    }

    func received(_ m: OSCMessage) {
        guard let family, isReal else { return }
        lastHeard = Date()
        if !m.arguments.isEmpty { heard.insert(m.address) }
        capture?.take(m)
        if m.address == "/info" || m.address == "/xinfo" {
            let parts = m.arguments.compactMap { a -> String? in if case let .string(s) = a { return s } else { return nil } }
            model = parts.dropFirst().joined(separator: " · ")
            status = "connected"
            stateDirty = true
            return
        }
        if status != "connected" { status = "connected"; stateDirty = true }
        if family != .xAir, X32InputRouting.blockAddresses.contains(m.address) || m.address.hasSuffix("/config/source") {
            if routingPreset == .auto, routing.apply(m) {
                sendToConsole((1...family.channelCount).compactMap { X32Codec.gainAddress($0, family: family, routing: routing) }.map { OSCMessage($0) })
            }
            return
        }
        if let (bank, values) = ConsoleMeters.decode(m, family: family) {
            switch bank {
            case .channels: for (i, v) in values.enumerated() { channelLevels[i + 1] = v }
            case .buses: for (i, v) in values.prefix(X32Codec.busCount(family)).enumerated() { busLevels[i + 1] = v }
            case .rta: break
            }
            return
        }
        if X32Codec.apply(m, to: &strips, family: family, routing: routing) != nil || X32Codec.apply(m, toBuses: &buses) != nil {
            stateDirty = true
        }
    }

    func askMissing() {
        guard let family, isReal else { return }
        var missing: [String] = []
        if family != .xAir {
            missing += X32InputRouting.blockAddresses.filter { !heard.contains($0) }
            missing += (1...family.channelCount).map { X32Codec.channelPath($0) + "/config/source" }.filter { !heard.contains($0) }
        }
        missing += (1...family.channelCount).flatMap { X32Codec.queryAddresses($0, family: family, routing: routing) }.filter { !heard.contains($0) }
        missing += (1...X32Codec.busCount(family)).flatMap { X32Codec.busQueryAddresses($0, family: family) }.filter { !heard.contains($0) }
        sendToConsole(missing.map { OSCMessage($0) })
    }

    // MARK: soundcheck (simulator only)

    func beginJob() {
        session?.measurementMic = MeasurementMic()
        nextJobStep = Date()
        stateDirty = true
    }

    func jobStep() {
        guard let session, let sim, session.isRunning else { nextJobStep = .distantFuture; stateDirty = true; return }
        let r = sim.render(seconds: 2, channels: session.listening, tap: .preEQ)
        let ex = FeatureExtractor()
        var feats: [Int: SignalFeatures] = [:]
        for (ch, x) in r.taps { feats[ch] = ex.analyze(x) }
        for (ch, f) in feats where f.hasSignal { channelLevels[ch] = f.rmsDB }
        let changed = session.tick(features: feats, mic: r.mic)
        for s in changed { strips[s.id] = s; sim.setStrip(s) }
        if !session.isRunning { nextJobStep = .distantFuture }
        emitLog()
        stateDirty = true
    }

    /// Simulated channel meters for learning on the simulator: half a second of each audible channel.
    func simLevels() {
        guard let sim else { return }
        let chans = strips.values.filter { !$0.muted && $0.faderDB > -90 }.map(\.id)
        guard !chans.isEmpty else { return }
        let r = sim.render(seconds: 0.25, channels: chans, tap: .preEQ)
        for (ch, x) in r.taps {
            let p = x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, x.count))
            channelLevels[ch] = Decibel.fromPower(p + 1e-15)
        }
    }

    func emitLog() {
        guard let session else { return }
        let entries: [[String: Any]] = session.log.suffix(200).map { ["step": $0.step, "channel": $0.channel, "note": Out.json($0.note)] }
        Out.emit("log", ["entries": entries])
    }

    func tuningState(_ ch: Int) -> String? {
        guard let session else { return nil }
        if let t = session.single, t.channel == ch { return t.state.rawValue }
        return session.group?.tunings[ch]?.state.rawValue
    }

    // MARK: learning

    func learnStart(title: String) {
        guard let family, status == "connected" || sim != nil else { return Out.emit("message", ["key": "connectFirst"]) }
        if recorder != nil { learnStop() }
        let header = LearnHeader(title: title.isEmpty ? "Event" : title, console: family.rawValue, model: model,
                                 app: "SSMT \(engineVersion) Windows")
        do {
            try FileManager.default.createDirectory(at: learnDir, withIntermediateDirectories: true)
            let url = learnDir.appendingPathComponent(LearningRecorder.fileName(for: header))
            let rec = LearningRecorder(header: header)
            guard FileManager.default.createFile(atPath: url.path, contents: rec.headerLine()) else {
                return Out.emit("error", ["key": "cannotWrite", "detail": url.path])
            }
            recordFile = try FileHandle(forWritingTo: url)
            recordFile?.seekToEndOfFile()
            recordURL = url
            recorder = rec
            _ = capture?.takeSecond()   // the first second's meters start now
            learnStartedAt = Date()
            nextLearnFrame = Date()
        } catch {
            Out.emit("error", ["key": "cannotWrite", "detail": "\(error)"])
        }
        emitLearn()
    }

    func learnFrame() {
        guard var rec = recorder else { return }
        let t = Date().timeIntervalSince(learnStartedAt)
        var params: [String: ParamValue]?
        var meters: LearnMeters?
        if sim != nil {
            var c = ConsoleCapture(family: .simulator)
            c.absorb(strips: strips, buses: buses)
            params = c.params
        } else if var c = capture {
            // Every parameter is asked again in turn (a few a second), so the recording has the whole console.
            sendToConsole(c.sweep())
            meters = c.takeSecond()
            params = c.params
            capture = c
        }
        learnParams = params?.count ?? 0
        let line = rec.record(t: t, strips: strips, buses: buses, channelLevels: channelLevels, busLevels: busLevels,
                              params: params, meters: meters)
        recorder = rec
        recordFile?.write(line)
        emitLearn()
    }

    func learnStop() {
        try? recordFile?.close()
        recordFile = nil
        recorder = nil
        recordURL = nil
        nextLearnFrame = .distantFuture
        emitLearn()
        emitRecordings()
    }

    func emitLearn() {
        var f: [String: Any] = ["recording": recorder != nil]
        if let r = recorder {
            f["seconds"] = Date().timeIntervalSince(learnStartedAt)
            f["frames"] = r.frames
            f["changes"] = r.changes
            f["params"] = learnParams
            f["title"] = r.header.title
            f["file"] = recordURL?.lastPathComponent ?? ""
        }
        Out.emit("learn", f)
    }

    func loadRecordings() -> [(file: String, rec: LearnRecording)] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: learnDir, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "ssmtlearn" }.compactMap { u in
            guard let d = try? Data(contentsOf: u), let r = LearnRecording.parse(d) else { return nil }
            return (u.lastPathComponent, r)
        }.sorted { $0.rec.header.startedAt > $1.rec.header.startedAt }
    }

    func emitRecordings() {
        let list: [[String: Any]] = loadRecordings().map {
            ["file": $0.file, "title": $0.rec.header.title, "startedAt": $0.rec.header.startedAt, "duration": $0.rec.duration,
             "console": $0.rec.header.console, "model": $0.rec.header.model,
             "event": $0.rec.duration >= PatternLearner.minEventSeconds]
        }
        Out.emit("recordings", ["items": list, "target": LearnedPatterns.targetEvents, "dir": learnDir.path])
    }

    func patterns() -> LearnedPatterns { PatternLearner.learn(loadRecordings().map(\.rec)) }

    // MARK: clock

    func tick() {
        let now = Date()
        if now >= nextRenew, let family, isReal {
            sendToConsole(ConsoleReadOnly.renewals(family: family))
            nextRenew = now.addingTimeInterval(8)
        }
        if let first = askAgain.first, now >= first {
            askAgain.removeFirst()
            askMissing()
            if askAgain.isEmpty, isReal, status == "connecting", now.timeIntervalSince(connectedAt) > 3 { status = "failed"; stateDirty = true }
        }
        if now >= nextJobStep {
            nextJobStep = now.addingTimeInterval(2)
            jobStep()
        }
        if now >= nextSimLevels, sim != nil {
            nextSimLevels = now.addingTimeInterval(recorder != nil ? 1 : 2)
            if session?.isRunning != true { simLevels() }
        }
        if now >= nextLearnFrame {
            nextLearnFrame = nextLearnFrame.addingTimeInterval(1)
            if nextLearnFrame < now { nextLearnFrame = now.addingTimeInterval(1) }
            learnFrame()
        }
        let alive = sim != nil || (isReal && now.timeIntervalSince(lastHeard) < 4)
        if alive != lastAlive { lastAlive = alive; stateDirty = true }
        if now >= nextMeters, family != nil {
            nextMeters = now.addingTimeInterval(0.1)
            Out.emit("meters", ["channels": levelsArray(channelLevels, strips.keys.max() ?? 0),
                                "buses": levelsArray(busLevels, buses.keys.max() ?? 0)])
        }
        if stateDirty && now >= nextState {
            stateDirty = false
            nextState = now.addingTimeInterval(0.2)
            emitState()
        }
    }

    func levelsArray(_ m: [Int: Double], _ n: Int) -> [Double] {
        n > 0 ? (1...n).map { v -> Double in let x = m[v] ?? -120; return x.isFinite ? (max(-120, min(20, x)) * 10).rounded() / 10 : -120 } : []
    }

    func emitState() {
        var states: [String: String] = [:]
        var kinds: [String: String] = [:]
        for ch in strips.keys {
            if let s = tuningState(ch) { states["\(ch)"] = s }
            if let k = SourceClassifier.kind(forName: strips[ch]?.name ?? "") { kinds["\(ch)"] = k.rawValue }
        }
        var job = "none"
        if let s = session, s.isRunning {
            switch s.job {
            case .none: job = "none"
            case let .channel(ch): job = "channel:\(ch)"
            case .group: job = "group:" + (s.group?.phase.rawValue ?? "")
            case .polarity: job = "polarity"
            }
        }
        Out.emit("state", [
            "family": family?.rawValue ?? "", "host": host, "status": status, "model": model, "alive": lastAlive,
            "readOnly": isReal, "routing": routingPreset.rawValue, "character": character.rawValue, "job": job,
            "strips": Out.json(strips.values.sorted { $0.id < $1.id }), "buses": Out.json(buses.values.sorted { $0.id < $1.id }),
            "states": states, "kinds": kinds,
        ])
    }
}

// MARK: - main loop

let inbox = Inbox()
let reader = Thread {
    while let line = readLine(strippingNewline: true) { inbox.push(line) }
    inbox.end()
}
reader.start()

let engine = Engine()
Out.emit("ready", ["version": engineVersion])
while true {
    let (lines, ended) = inbox.drain()
    for l in lines { engine.handle(l) }
    if ended {
        engine.disconnect()
        exit(0)
    }
    engine.tick()
    Thread.sleep(forTimeInterval: 0.02)
}
