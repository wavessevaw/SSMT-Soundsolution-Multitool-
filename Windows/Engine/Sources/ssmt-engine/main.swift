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
    var tap = TapPoint.preEQ
    /// Snapshot tests: the simulator shown as a real (read-only) console.
    var previewReadOnly = false
    /// Snapshot tests: recordings as if read from disk (AssistStore.showRecordings).
    var previewRecordings: [(file: String, rec: LearnRecording)]?
    /// Last analysis per channel (soundcheck and show guard), as AssistStore.features.
    var features: [Int: SignalFeatures] = [:]
    var groupPhase: GroupPhase?
    var micLevel: Double?
    var micCalibrated = false
    /// Why the console did not connect ("noAnswer", "not supported yet").
    var failure = ""
    /// Channel levels of the simulator for learning (AssistStore.simLevels), apart from the live meters.
    var simLearnLevels: [Int: Double] = [:]

    // Show guard and show simulation (AssistStore, simulator only: a real console is read-only).
    var guardian: ShowGuard?
    var guarding = false
    var guardStart = Date()
    var guardTime: Double = 0
    var guardSteps = 0
    var guardElapsed: Double = 0
    var guardLog: [(time: Double, action: GuardAction)] = []
    var corrections: [ShowGuard.Correction] = []
    var nextGuardStep = Date.distantFuture
    let hallDetector = FeedbackDetector()
    let stageDetector = FeedbackDetector()
    var rehearsal: ShowRehearsal?
    var rehearsalScene: ShowRehearsal.Scene?
    var rehearsalLog: [(time: Double, event: ShowRehearsal.Event)] = []
    var nextRehearsalStep = Date.distantFuture

    // Console test and fader wave.
    let testBox = TestBox()
    var testing = false
    var testChecks: [ConsoleTestCheck] = []
    var waving = false
    var waveCycle = 4.0
    var waveStart = Date()
    var waveBackup: [Int: Double] = [:]
    var nextWaveTick = Date.distantFuture

    // What the link to a real console brings, per second (AssistStore.LinkStats).
    var frameCount = (ch: 0, bus: 0, rta: 0)
    var linkStats: [String: Any] = [:]
    var nextLinkStats = Date.distantFuture

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
    var askAgain: [Date] = []
    var lastAlive = false

    var isReal: Bool { family == .x32 || family == .xAir }
    /// A real console is read-only in this version: soundcheck, show guard and console test are simulator only.
    var readOnly: Bool { isReal || previewReadOnly }

    /// The program's other functions (Modules/).
    lazy var modules: [EngineModule] = makeModules()

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
            guardian?.character = character
            stateDirty = true
        case "tap":
            tap = TapPoint(rawValue: str("value") ?? "") ?? .preEQ
            session?.tap = tap
            stateDirty = true
        case "tune":
            guard let session, sim != nil, !readOnly, let ch = int("channel") else { return refuse(cmd) }
            session.startChannel(ch)
            beginJob()
        case "tuneGroup":
            guard let session, sim != nil, !readOnly else { return refuse(cmd) }
            let sel: AssistGroupSelection
            switch str("group") {
            case "choir": sel = .choir
            case "range": sel = .range(int("from") ?? 1, int("to") ?? 8)
            default: sel = .orchestra
            }
            if session.startGroup(sel).isEmpty { Out.emit("message", ["key": "nothingFound"]); return }
            if sel == .orchestra { ProfileModule.shared?.record("foh.orchestra") }
            if sel == .choir { ProfileModule.shared?.record("foh.choir") }
            beginJob()
        case "polarity":
            guard let session, sim != nil, !readOnly else { return refuse(cmd) }
            if session.startPolarity().isEmpty { Out.emit("message", ["key": "nothingFound"]) } else { beginJob() }
        case "stopJob":
            stopJob()
        case "undo":
            guard let session, let sim else { return refuse(cmd) }
            ProfileModule.shared?.record("foh.revert")
            for s in session.undo() { trackStrip(s); strips[s.id] = s; sim.setStrip(s) }
            stopJob()
        case "runNow":
            // Steps at once instead of every 2 s (simulator demo, snapshot tests); the clock stops, as on the Mac.
            nextJobStep = .distantFuture
            for _ in 0..<max(0, int("steps") ?? 1) { jobStep() }
        default:
            if handleLearn(cmd, obj) || handleAssist(cmd, obj) { return }
            let c = Command(name: cmd, fields: obj)
            if !modules.contains(where: { $0.handle(c, engine: self) }) {
                Out.emit("error", ["key": "unknownCommand", "detail": cmd])
            }
        }
    }

    /// Learning commands (recordings, patterns, the language model's prompt). False when not one of them.
    func handleLearn(_ cmd: String, _ obj: [String: Any]) -> Bool {
        func str(_ k: String) -> String? { obj[k] as? String }
        switch cmd {
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
        case "exportDataset":
            exportDataset()
        case "patterns":
            let p = patterns()
            Out.emit("patterns", ["patterns": Out.json(p), "summary": p.summary(russian: str("lang") != "en")])
        case "prompt":
            let p = patterns()
            Out.emit("prompt", ["id": str("id") ?? "", "text": p.prompt(question: str("question") ?? "", russian: str("lang") != "en")])
        default:
            return false
        }
        return true
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
            model = "SSMT simulator · \(c.strips.count) ch"
            status = "connected"
            lastAlive = true
            ProfileModule.shared?.record("foh.simulator")
        case .x32, .xAir:
            status = "connecting"
            model = ""
            linkStats = [:]
            frameCount = (0, 0, 0)
            nextLinkStats = Date().addingTimeInterval(1)
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
            failure = "not supported yet"
        }
        // As on the Mac, every console gets a session (the kind of each channel is read from it).
        session = AssistSession(strips: strips.values.sorted { $0.id < $1.id }, character: character, tap: tap)
        session?.measurementMic = MeasurementMic()
        stateDirty = true
    }

    func disconnect() {
        if recorder != nil { learnStop() }
        stopWave()
        stopRehearsal()
        stopJob()
        stopGuard()
        if isReal { Out.emit("unlink") }
        family = nil
        failure = ""
        features = [:]
        micLevel = nil
        nextLinkStats = .distantFuture
        linkStats = [:]
        capture = nil
        sim = nil
        session = nil
        strips = [:]
        buses = [:]
        channelLevels = [:]
        busLevels = [:]
        status = "disconnected"
        lastAlive = false
        nextRenew = .distantFuture
        nextJobStep = .distantFuture
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
        if !lastAlive && status == "connected" { lastAlive = true; stateDirty = true }
        if !m.arguments.isEmpty { heard.insert(m.address) }
        capture?.take(m)
        if m.address == "/info" || m.address == "/xinfo" {
            let parts = m.arguments.compactMap { a -> String? in if case let .string(s) = a { return s } else { return nil } }
            model = parts.dropFirst().joined(separator: " · ")
            if status == "connecting" { ProfileModule.shared?.record("foh.connect") }
            status = "connected"
            failure = ""
            stateDirty = true
            return
        }
        if status != "connected" {
            if status == "connecting" { ProfileModule.shared?.record("foh.connect") }
            status = "connected"; failure = ""; stateDirty = true
        }
        if family != .xAir, X32InputRouting.blockAddresses.contains(m.address) || m.address.hasSuffix("/config/source") {
            if routingPreset == .auto, routing.apply(m) {
                sendToConsole((1...family.channelCount).compactMap { X32Codec.gainAddress($0, family: family, routing: routing) }.map { OSCMessage($0) })
            }
            return
        }
        if let (bank, values) = ConsoleMeters.decode(m, family: family) {
            switch bank {
            case .channels: frameCount.ch += 1
            case .buses: frameCount.bus += 1
            case .rta: frameCount.rta += 1
            }
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

    /// AssistStore.begin: the first step comes after one window (2 s).
    func beginJob() {
        session?.measurementMic = MeasurementMic()
        nextJobStep = Date().addingTimeInterval(2)
        stateDirty = true
    }

    func stopJob() {
        session?.stop()
        nextJobStep = .distantFuture
        groupPhase = nil
        stateDirty = true
    }

    /// AssistStore.step: features of the listened channels for the last window, the hall mic, the console updated.
    func jobStep() {
        guard let session, let sim, session.isRunning else { nextJobStep = .distantFuture; stateDirty = true; return }
        let r = sim.render(seconds: 2, channels: session.listening, tap: tap)
        let ex = FeatureExtractor()
        var feats: [Int: SignalFeatures] = [:]
        for (ch, x) in r.taps { feats[ch] = ex.analyze(x) }
        hallLevel(r.mic, sampleRate: sim.sampleRate)
        let changed = session.tick(features: feats, mic: r.mic)
        for s in changed { trackStrip(s); strips[s.id] = s; sim.setStrip(s) }
        features.merge(session.features) { $1 }
        for (ch, f) in feats where f.hasSignal { channelLevels[ch] = f.rmsDB }
        groupPhase = session.group?.phase
        // A channel that is ready becomes the show guard's tonal reference.
        for ch in session.listening where references[ch] == nil {
            let done = session.single?.channel == ch ? session.single?.state == .done : session.group?.tunings[ch]?.state == .done
            if done, let f = session.features[ch], f.bandsDB.contains(where: { $0 > -119 }) { references[ch] = f.bandsDB }
        }
        if !session.isRunning {
            nextJobStep = .distantFuture
            // A finished soundcheck job.
            ProfileModule.shared?.record("foh.soundcheck")
            if character == .rock { ProfileModule.shared?.record("foh.rock") }
            if character == .classical { ProfileModule.shared?.record("foh.classic") }
        }
        emitLog()
        stateDirty = true
    }

    /// The hall measurement mic's A-weighted level (AssistStore.micLevel).
    func hallLevel(_ mic: [Float], sampleRate: Double) {
        let l = MeasurementMic().levelA(mic, sampleRate: sampleRate)
        micLevel = l.value
        micCalibrated = l.calibrated
    }

    /// Simulated channel levels for learning (AssistStore.learnFrame): a quarter second of each audible channel.
    func simLevels() {
        guard let sim else { return }
        let chans = strips.values.filter { !$0.muted && $0.faderDB > -90 }.map(\.id)
        guard !chans.isEmpty else { return }
        let r = sim.render(seconds: 0.25, channels: chans, tap: .preEQ)
        for (ch, x) in r.taps {
            let p = x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, x.count))
            simLearnLevels[ch] = Decibel.fromPower(p + 1e-15)
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
            // The simulator has no meter stream: a quarter second of each audible channel.
            simLevels()
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
        let line = rec.record(t: t, strips: strips, buses: buses, channelLevels: sim != nil ? simLearnLevels : channelLevels, busLevels: busLevels,
                              params: params, meters: meters, lost: isReal && Date().timeIntervalSince(lastHeard) > 4)
        recorder = rec
        recordFile?.write(line)
        // On disk every 30 s: a crash or a power cut loses at most that.
        if rec.shouldFlush { recordFile?.synchronizeFile() }
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
            f["lost"] = r.lostFrames
            f["params"] = learnParams
            f["title"] = r.header.title
            f["file"] = recordURL?.lastPathComponent ?? ""
        }
        Out.emit("learn", f)
    }

    func loadRecordings() -> [(file: String, rec: LearnRecording)] {
        if let p = previewRecordings { return p }
        let urls = (try? FileManager.default.contentsOfDirectory(at: learnDir, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "ssmtlearn" }.compactMap { u in
            guard let d = try? Data(contentsOf: u), let r = LearnRecording.parse(d) else { return nil }
            return (u.lastPathComponent, r)
        }.sorted { $0.rec.header.startedAt > $1.rec.header.startedAt }
    }

    /// All recordings as one training file (`LearnDataset`), next to them.
    func exportDataset() {
        let recs = loadRecordings().map(\.rec)
        let data = LearnDataset.jsonLines(recs)
        let url = learnDir.appendingPathComponent(LearnDataset.fileName)
        do {
            try FileManager.default.createDirectory(at: learnDir, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            let rows = data.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
            Out.emit("dataset", ["path": url.path, "rows": rows, "recordings": recs.count, "bytes": data.count])
        } catch {
            Out.emit("error", ["key": "cannotWrite", "detail": "\(error)"])
        }
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
        for m in modules { m.tick(now, engine: self) }
        if now >= nextRenew, let family, isReal {
            sendToConsole(ConsoleReadOnly.renewals(family: family))
            nextRenew = now.addingTimeInterval(8)
        }
        if let first = askAgain.first, now >= first {
            askAgain.removeFirst()
            askMissing()
        }
        // No answer within 3 s (AssistStore.connect); the link keeps trying and connects if the console answers later.
        if isReal, status == "connecting", now.timeIntervalSince(connectedAt) > 3 { status = "failed"; failure = "noAnswer"; stateDirty = true }
        if now >= nextJobStep {
            nextJobStep = now.addingTimeInterval(2)
            jobStep()
        }
        tickAssist(now)
        if now >= nextLearnFrame {
            nextLearnFrame = nextLearnFrame.addingTimeInterval(1)
            if nextLearnFrame < now { nextLearnFrame = now.addingTimeInterval(1) }
            learnFrame()
        }
        let alive = sim != nil || (isReal && now.timeIntervalSince(lastHeard) < 4)
        if alive && !lastAlive && status == "connected" { ProfileModule.shared?.record("foh.reconnect") }
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
