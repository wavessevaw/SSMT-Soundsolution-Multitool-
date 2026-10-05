import Foundation
import SSMTCore

// FOH Assist beyond the soundcheck: the show guard, the show simulation, the console test, the fader wave, the
// state the interface draws, and the snapshot-test fixtures. A port of App/SSMT/Assist/AssistStore.swift on top of
// SSMTCore. As on the Mac, a real console is read-only in this version: all of this runs in the simulator only.

/// Progress of the console test, written by the test's task and read by the engine's loop.
final class TestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var checks: [ConsoleTestCheck]?
    private var finished: [ConsoleTestCheck]?

    func progress(_ c: [ConsoleTestCheck]) { lock.lock(); checks = c; lock.unlock() }
    func finish(_ c: [ConsoleTestCheck]) { lock.lock(); finished = c; lock.unlock() }
    /// What arrived since the last call: the latest progress, and the result once the test is over.
    func take() -> (progress: [ConsoleTestCheck]?, result: [ConsoleTestCheck]?) {
        lock.lock(); defer { lock.unlock() }
        let p = checks, r = finished
        checks = nil
        finished = nil
        return (p, r)
    }
}

extension Engine {
    static let guardInterval = 0.25
    static let waveRate = 25.0

    // MARK: commands

    /// FOH Assist commands of the show, the console test and the fixtures. False when not one of them.
    func handleAssist(_ cmd: String, _ obj: [String: Any]) -> Bool {
        func str(_ k: String) -> String? { obj[k] as? String }
        func int(_ k: String) -> Int? { (obj[k] as? NSNumber)?.intValue }
        func double(_ k: String) -> Double? { (obj[k] as? NSNumber)?.doubleValue }
        func bool(_ k: String) -> Bool? { (obj[k] as? NSNumber)?.boolValue }
        switch cmd {
        case "guardStart":
            guard sim != nil, !readOnly else { refuse(cmd); return true }
            startGuard()
        case "guardStop":
            stopGuard()
        case "guardRun":
            // Guard steps at once (simulator demo, snapshot tests); the guard's clock stops, as on the Mac.
            nextGuardStep = .distantFuture
            for _ in 0..<max(0, int("steps") ?? 1) { guardStep() }
        case "setMonitor":
            if let b = int("bus") { if bool("on") == true { guardian?.monitorBuses.insert(b) } else { guardian?.monitorBuses.remove(b) } }
            stateDirty = true
        case "setLead":
            if let ch = int("channel") { if bool("on") == true { guardian?.leads.insert(ch) } else { guardian?.leads.remove(ch) } }
            stateDirty = true
        case "cancelCorrection":
            if let id = str("id") { cancelCorrection(id) }
        case "rehearsalStart":
            guard sim != nil, !readOnly else { refuse(cmd); return true }
            startRehearsal(scenario: str("scenario") ?? "musical", first: int("first") ?? 1, sceneSeconds: double("sceneSeconds") ?? 20)
        case "rehearsalStop":
            stopRehearsal()
        case "testRun":
            guard sim != nil, !readOnly else { refuse(cmd); return true }
            runConsoleTest(scenario: str("scenario") ?? "musical", first: int("first") ?? 1, muteMain: bool("muteMain") ?? true)
        case "waveStart":
            if let c = double("cycle") { waveCycle = c }
            guard sim != nil, !readOnly else { refuse(cmd); return true }
            startWave()
        case "waveStop":
            stopWave()
        case "waveCycle":
            if let c = double("value") { waveCycle = c; stateDirty = true }
        case "curve":
            // EQ + high-pass response of a strip (20 Hz…20 kHz, 241 points on a log scale) and its band dots, for
            // the soundcheck detail panel (EQCurveView).
            guard let ch = int("channel"), let s = strips[ch] else { return true }
            let n = 240
            let db = (0...n).map { i -> Double in Self.r1(s.filterResponseDB(at: 20 * pow(1000.0, Double(i) / Double(n)))) }
            let dots: [[String: Double]] = s.eqOn
                ? s.eq.filter { abs($0.gainDB) >= 0.5 }.map { ["f": $0.frequency, "db": Self.r1(s.filterResponseDB(at: $0.frequency))] }
                : []
            Out.emit("curve", ["channel": ch, "db": db, "dots": dots])
        case "previewReadOnly":
            previewReadOnly = bool("on") ?? false
            stateDirty = true
        case "assistFixture":
            assistFixture(str("name") ?? "")
        default:
            return false
        }
        return true
    }

    // MARK: clock

    func tickAssist(_ now: Date) {
        if now >= nextGuardStep {
            nextGuardStep = nextGuardStep.addingTimeInterval(Self.guardInterval)
            if nextGuardStep < now { nextGuardStep = now.addingTimeInterval(Self.guardInterval) }
            guardStep()
        }
        if now >= nextRehearsalStep {
            nextRehearsalStep = nextRehearsalStep.addingTimeInterval(Self.guardInterval)
            if nextRehearsalStep < now { nextRehearsalStep = now.addingTimeInterval(Self.guardInterval) }
            rehearsalTick()
        }
        if now >= nextWaveTick {
            nextWaveTick = now.addingTimeInterval(1 / Self.waveRate)
            waveTick(now)
        }
        if testing {
            let (p, r) = testBox.take()
            if let p { testChecks = p; stateDirty = true }
            if let r { testChecks = r; testing = false; stateDirty = true }
        }
        if now >= nextLinkStats {
            nextLinkStats = now.addingTimeInterval(1)
            updateLinkStats()
        }
    }

    // MARK: show guard (AssistStore.startGuard / guardStep)

    func startGuard() {
        guard status == "connected" else { return }
        stopJob()
        let g = ShowGuard(strips: strips.values.sorted { $0.id < $1.id }, buses: buses.values.sorted { $0.id < $1.id }, character: character)
        g.references = references
        guardian = g
        guardStart = Date()
        guardElapsed = 0
        corrections = []
        guarding = true
        hallDetector.reset()
        stageDetector.reset()
        guardSteps = 0
        // 4 steps a second: feedback and ringing monitors are caught within a quarter of a second.
        nextGuardStep = Date().addingTimeInterval(Self.guardInterval)
        stateDirty = true
    }

    func stopGuard() {
        nextGuardStep = .distantFuture
        guard let g = guardian else { return }
        let (s, b) = g.releaseAll()
        applyStrips(s)
        applyBuses(b)
        guardian = nil
        guarding = false
        stateDirty = true
    }

    func guardStep() {
        guard let g = guardian, rehearsal == nil, let sim else { return }
        let t = guardTime
        guardTime += Self.guardInterval
        guardSteps += 1
        let playing = strips.values.filter { !$0.muted && $0.faderDB > -60 }.map(\.id).sorted()
        let r = sim.render(seconds: Self.guardInterval, channels: playing, tap: tap)
        let ex = FeatureExtractor()
        var feats: [Int: SignalFeatures] = [:]
        for (ch, x) in r.taps { feats[ch] = ex.analyze(x) }
        hallLevel(r.mic, sampleRate: sim.sampleRate)
        busLevels = sim.busLevels(channelRMS: feats.filter { $0.value.hasSignal }.mapValues(\.rmsDB))
        let hall = hallDetector.process(r.mic)
        let out = g.step(time: t, channels: feats, busLevels: busLevels, hallFeedback: hall, stageFeedback: [])
        applyStrips(out.strips)
        applyBuses(out.buses)
        features.merge(feats) { $1 }
        guardLog = Array(g.log.suffix(200))
        corrections = g.corrections(at: t)
        guardElapsed = t
        for (ch, f) in feats where f.hasSignal { channelLevels[ch] = f.rmsDB }
        stateDirty = true
    }

    /// The engineer cancels one correction of the guard from the list.
    func cancelCorrection(_ id: String) {
        guard let g = guardian else { return }
        let t = rehearsal?.time ?? (sim != nil ? guardTime : Date().timeIntervalSince(guardStart))
        let (s, b) = g.cancel(id, time: t)
        applyStrips(s)
        applyBuses(b)
        corrections = g.corrections(at: t)
        guardLog = Array(g.log.suffix(200))
        stateDirty = true
    }

    func applyStrips(_ changed: [ChannelStrip]) {
        for s in changed { strips[s.id] = s; sim?.setStrip(s) }
        if !changed.isEmpty { stateDirty = true }
    }

    func applyBuses(_ changed: [BusStrip]) {
        for b in changed { buses[b.id] = b; sim?.setBus(b) }
        if !changed.isEmpty { stateDirty = true }
    }

    // MARK: show simulation (AssistStore.startRehearsal)

    func startRehearsal(scenario id: String, first: Int, sceneSeconds: Double) {
        guard rehearsal == nil else { return }
        stopJob()
        stopGuard()
        let scenario = AssistScenario.all.first { $0.id == id } ?? .musical
        let fam = MixerFamily.x32
        let start = min(first, max(1, fam.channelCount - scenario.channels.count + 1))
        let console = SimulatedConsole.scenario(scenario, first: start)
        let r = ShowRehearsal(console: console, character: character, sceneSeconds: sceneSeconds)
        rehearsal = r
        guardian = r.guardian
        guarding = true
        rehearsalLog = []
        guardLog = []
        rehearsalScene = nil
        for s in r.strips.values { strips[s.id] = s }
        for b in r.buses.values { buses[b.id] = b }
        nextRehearsalStep = Date().addingTimeInterval(Self.guardInterval)
        stateDirty = true
    }

    func rehearsalTick() {
        guard let r = rehearsal else { return }
        let out = r.step(dt: Self.guardInterval)
        for s in out.strips { strips[s.id] = s }
        for b in out.buses { buses[b.id] = b }
        rehearsalScene = r.scene
        rehearsalLog = r.events.suffix(80).filter { if case .engineerFader = $0.event { return false }; return true }
        guardLog = Array(r.guardian.log.suffix(200))
        corrections = r.guardian.corrections(at: r.time)
        busLevels = r.lastBusLevels
        channelLevels.merge(r.lastChannelLevels) { $1 }
        guardElapsed = r.time
        stateDirty = true
    }

    func stopRehearsal() {
        guard let r = rehearsal else { return }
        nextRehearsalStep = .distantFuture
        rehearsalScene = nil
        let (s, b) = r.guardian.releaseAll()
        for x in s { strips[x.id] = x }
        for x in b { buses[x.id] = x }
        rehearsal = nil
        guardian = nil
        guarding = false
        stateDirty = true
    }

    // MARK: console test (AssistStore.runConsoleTest; the simulator tests against the built-in X32 emulator)

    func runConsoleTest(scenario id: String, first: Int, muteMain: Bool) {
        guard !testing else { return }
        stopWave()
        stopJob()
        stopGuard()
        let scenario = AssistScenario.all.first { $0.id == id } ?? .musical
        let fam = MixerFamily.x32
        let start = min(first, max(1, fam.channelCount - scenario.channels.count + 1))
        let runner = ConsoleTestRunner(scenario: scenario, family: fam, firstChannel: start, transport: ConsoleEmulator(family: .x32))
        runner.muteMain = muteMain
        runner.character = character
        let box = testBox
        _ = box.take()
        runner.onProgress = { box.progress($0) }
        testChecks = []
        testing = true
        stateDirty = true
        Task.detached {
            let result = await runner.run()
            box.finish(result)
        }
    }

    // MARK: fader wave (AssistStore.startWave)

    var waveChannels: Int { sim != nil ? strips.count : (family?.channelCount ?? 0) }

    func startWave() {
        guard status == "connected", !waving else { return }
        stopJob()
        stopGuard()
        stopRehearsal()
        waveBackup = strips.mapValues(\.faderDB)
        waveStart = Date()
        waving = true
        nextWaveTick = Date()
        stateDirty = true
    }

    func waveTick(_ now: Date) {
        guard waving, let sim else { return }
        let w = FaderWave(cycleSeconds: waveCycle)
        // The simulator's faders follow the wave; the strips on screen keep the engineer's values, as on the Mac.
        for (i, p) in w.positions(at: now.timeIntervalSince(waveStart), channels: waveChannels).enumerated() {
            guard var s = strips[i + 1] else { continue }
            s.faderDB = X32Codec.faderDB(p)
            sim.setStrip(s)
        }
    }

    func stopWave() {
        nextWaveTick = .distantFuture
        guard waving else { return }
        waving = false
        if let sim { for (ch, db) in waveBackup { if var s = strips[ch] { s.faderDB = db; sim.setStrip(s) } } }
        waveBackup = [:]
        stateDirty = true
    }

    // MARK: link diagnostics (AssistStore.updateLinkStats)

    func updateLinkStats() {
        guard let family, isReal else { return }
        let n = family.channelCount
        let expected = (1...n).flatMap { X32Codec.queryAddresses($0, family: family, routing: routing) }
            + (1...X32Codec.busCount(family)).flatMap { X32Codec.busQueryAddresses($0, family: family) }
        let st: [String: Any] = [
            "channelFrames": frameCount.ch, "busFrames": frameCount.bus, "rtaFrames": frameCount.rta,
            "paramsHeard": expected.filter { heard.contains($0) }.count, "paramsExpected": expected.count,
            "gainKnown": routing.knownChannels(n, family: family), "channels": n, "model": model,
        ]
        frameCount = (0, 0, 0)
        linkStats = st
        stateDirty = true
    }

    // MARK: state for the interface

    /// What the channel carries (AssistStore.kind(of:)): the tuning's kind, else read from the name and the sound.
    func kind(_ ch: Int) -> SourceKind? {
        guard let session else { return nil }
        if let t = session.single, t.channel == ch { return t.kind }
        if let t = session.group?.tunings[ch] { return t.kind }
        return SourceClassifier.classify(name: strips[ch]?.name ?? "", features: features[ch]).kind
    }

    static func r1(_ x: Double) -> Double { x.isFinite ? (x * 10).rounded() / 10 : -120 }

    func emitState() {
        var states: [String: String] = [:]
        var kinds: [String: String] = [:]
        for ch in strips.keys {
            if let s = tuningState(ch) { states["\(ch)"] = s }
            if let k = kind(ch) { kinds["\(ch)"] = k.rawValue }
        }
        var feats: [String: Any] = [:]
        for (ch, f) in features { feats["\(ch)"] = ["bands": f.bandsDB.map(Self.r1), "signal": f.hasSignal] }
        var job = "none"
        let running = session?.isRunning ?? false
        if let s = session, running {
            switch s.job {
            case .none: job = "none"
            case let .channel(ch): job = "channel:\(ch)"
            case .group: job = "group"
            case .polarity: job = "polarity"
            }
        }
        let corr: [[String: Any]] = corrections.map { c in
            var o: [String: Any] = ["id": c.id, "kind": c.kind.rawValue, "target": c.target, "amountDB": c.amountDB]
            if let f = c.frequency { o["frequency"] = f }
            if let r = c.restoreInSeconds { o["restoreIn"] = r }
            return o
        }
        let glog: [[String: Any]] = guardLog.map { ["t": $0.time, "a": Out.json($0.action)] }
        let rlog: [[String: Any]] = rehearsalLog.map { e in
            switch e.event {
            case let .scene(sc): return ["t": e.time, "scene": sc.rawValue]
            case let .engineerFader(ch, db): return ["t": e.time, "fader": ch, "db": db]
            case let .engineerBus(b, db): return ["t": e.time, "bus": b, "db": db]
            }
        }
        let monitors: [Int] = guardian.map { Array($0.monitorBuses).sorted() } ?? buses.values.filter(\.looksLikeMonitor).map(\.id).sorted()
        var connection = ""
        switch status {
        case "connected": connection = model.isEmpty ? host : model
        case "failed": connection = failure
        default: connection = ""
        }
        var f: [String: Any] = [
            "family": family?.rawValue ?? "", "host": host, "status": status, "failure": failure, "connection": connection,
            "model": model, "alive": lastAlive, "readOnly": readOnly, "routing": routingPreset.rawValue,
            "character": character.rawValue, "tap": tap.rawValue, "job": job, "running": running,
            "strips": Out.json(strips.values.sorted { $0.id < $1.id }), "buses": Out.json(buses.values.sorted { $0.id < $1.id }),
            "states": states, "kinds": kinds, "features": feats,
            "guarding": guarding, "rehearsing": rehearsal != nil, "guardElapsed": guardElapsed,
            "corrections": corr, "guardLog": glog, "rehearsalLog": rlog,
            "guardian": guardian != nil, "monitorBuses": monitors, "leads": guardian.map { Array($0.leads).sorted() } ?? [Int](),
            "testing": testing, "testChecks": testChecks.map { ["id": $0.id, "status": $0.status.rawValue, "detail": $0.detail] },
            "waving": waving, "waveChannels": waveChannels, "waveCycle": waveCycle,
            "linkStats": linkStats, "micCalibrated": micCalibrated, "thirdOctaves": ThirdOctave.centers,
        ]
        if let p = groupPhase { f["groupPhase"] = p.rawValue }
        if let sc = rehearsalScene { f["rehearsalScene"] = sc.rawValue }
        if let l = micLevel, l.isFinite { f["micLevel"] = l }
        Out.emit("state", f)
    }

    // MARK: fixtures (App/Tests/Snapshots/SnapshotTests.swift, testAssistWorkspace)

    func assistFixture(_ name: String) {
        switch name {
        case "discovered":
            // Consoles as if found on the network (AssistStore.showDiscovered).
            for c in [DiscoveredConsole(family: .x32, ip: "192.168.1.64", name: "X32-02-4A-53", model: "X32", firmware: "4.06"),
                      DiscoveredConsole(family: .x32, ip: "192.168.1.71", name: "M32R-11-0C-2B", model: "M32R", firmware: "4.06")] {
                Out.emit("found", ["family": c.family.rawValue, "ip": c.ip, "name": c.name, "model": c.model, "firmware": c.firmware])
            }
        case "sampleRecordings":
            // Three made-up events: a ridden vocal with a filter and a compressor, a kick, a bass.
            previewRecordings = Self.sampleRecordings()
            emitRecordings()
        default:
            Out.emit("error", ["key": "unknownFixture", "detail": name])
        }
    }

    static func sampleRecordings() -> [(file: String, rec: LearnRecording)] {
        var out: [(file: String, rec: LearnRecording)] = []
        for (n, title) in ["Мюзикл «Чикаго»", "Концерт группы", "Корпоратив"].enumerated() {
            var rec = LearningRecorder(header: LearnHeader(title: title, startedAt: 1_790_000_000 + Double(n) * 86400, console: "x32", model: "X32 · 4.06"))
            var vox = ChannelStrip(id: 1, name: "Vox Lead", gainDB: 34 + Double(n), highPassOn: true, highPassHz: 120, faderDB: -4)
            vox.eq[2] = StripEQBand(type: .peaking, frequency: 3000, gainDB: 2.5, q: 1.4)
            vox.compressor = StripCompressor(enabled: true, thresholdDB: -20, ratio: 3)
            let kick = ChannelStrip(id: 2, name: "Kick In", gainDB: 25, highPassOn: true, highPassHz: 40, faderDB: -6)
            let bass = ChannelStrip(id: 3, name: "Bass DI", gainDB: 18, faderDB: -8)
            var frames: [LearnFrame] = []
            for t in 0..<400 {
                var v = vox
                v.faderDB = -4 + (t / 10 % 2 == 0 ? 0 : 1.5)
                frames.append(rec.makeFrame(t: Double(t), strips: [1: v, 2: kick, 3: bass], buses: [:],
                                            channelLevels: [1: -18, 2: -12, 3: -15], busLevels: [:]))
            }
            out.append((file: "\(n).ssmtlearn", rec: LearnRecording(header: rec.header, frames: frames)))
        }
        return out
    }
}
