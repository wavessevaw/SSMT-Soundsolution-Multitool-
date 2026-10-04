import XCTest
@testable import SSMTCore

/// Mixer + engine driven together, as the app does (render blocks, engine ticks between them).
private final class ShowRig {
    let sr = 48000.0
    let mixer: ShowMixer
    let engine: ShowEngine
    var clips: [String: AudioClip] = [:]
    var ops: [MixerOp] = []
    let channels = 4
    var out: [[Float]]

    init(_ doc: ShowDocument) {
        let m = ShowMixer(sampleRate: 48000, maxOutputs: 8, maxVoices: 16)
        mixer = m
        out = Array(repeating: [], count: 4)
        var opsRef: [MixerOp] = []
        _ = opsRef
        engine = ShowEngine(document: doc, sampleRate: 48000, lookahead: 256, send: { _ in }, clipProvider: { _ in nil })
        engine.send = { [unowned self] op in self.ops.append(op); m.send(op) }
        engine.clipProvider = { [unowned self] cue in self.clips[cue.audio?.file ?? ""] }
        opsRef = []
    }

    var now: Int64 { Int64(mixer.framesRendered.value) }

    /// Renders `frames` frames in blocks of 256 and appends them to `out`.
    func run(_ frames: Int) {
        var left = frames
        let block = 256
        let bufs = (0..<channels).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: block) }
        defer { bufs.forEach { $0.deallocate() } }
        while left > 0 {
            let n = min(block, left)
            engine.advance(to: now)
            bufs.withUnsafeBufferPointer { mixer.render($0.baseAddress!, channelCount: channels, frames: n) }
            for c in 0..<channels { out[c] += Array(UnsafeBufferPointer(start: bufs[c], count: n)) }
            mixer.collectGarbage()
            left -= n
        }
    }

    func runSeconds(_ s: Double) { run(Int(s * sr)) }
}

private func constClip(_ value: Float, frames: Int, channels: Int = 2) -> AudioClip {
    AudioClip(sampleRate: 48000, channels: Array(repeating: Array(repeating: value, count: frames), count: channels))
}

private func audioCue(_ file: String, _ number: String, plays: Int = 1) -> Cue {
    var c = Cue.audio(file: file, number: number)
    c.audio?.plays = plays
    return c
}

final class ShowTests: XCTestCase {
    // MARK: Mixer

    func testMixerStartsOnExactFrameAndEndsAtRegionEnd() {
        let m = ShowMixer(sampleRate: 48000, maxOutputs: 4, maxVoices: 4)
        let clip = constClip(0.5, frames: 300)
        let setup = VoiceSetup(regionStart: 0, regionLength: 300, plays: 1, rate: 1, levelDB: 0,
                               outputLevelsDB: [0, 0], crosspointsDB: [[0, showSilenceDB], [showSilenceDB, 0]])
        m.send(.start(UUID(), clip: clip, setup: setup, at: 100))
        let bufs = (0..<2).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: 512) }
        defer { bufs.forEach { $0.deallocate() } }
        bufs.withUnsafeBufferPointer { m.render($0.baseAddress!, channelCount: 2, frames: 512) }
        XCTAssertEqual(bufs[0][99], 0)
        XCTAssertEqual(bufs[0][100], 0.5, accuracy: 1e-6)
        XCTAssertEqual(bufs[1][399], 0.5, accuracy: 1e-6)
        XCTAssertEqual(bufs[0][400], 0)
        XCTAssertEqual(m.framesRendered.value, 512)
    }

    func testMixerLoopsAndDevampEndsAfterCurrentIteration() {
        let m = ShowMixer(sampleRate: 48000, maxOutputs: 2, maxVoices: 4)
        let id = UUID()
        let clip = constClip(1, frames: 100, channels: 1)
        let setup = VoiceSetup(regionStart: 0, regionLength: 100, plays: 0, rate: 1, levelDB: 0,
                               outputLevelsDB: [0], crosspointsDB: [[0]])
        m.send(.start(id, clip: clip, setup: setup, at: 0))
        m.send(.devamp(id, at: 250)) // in iteration 3 → ends at 300
        let buf = UnsafeMutablePointer<Float>.allocate(capacity: 600)
        defer { buf.deallocate() }
        var ptrs = [buf]
        ptrs.withUnsafeMutableBufferPointer { p in
            p.withMemoryRebound(to: UnsafeMutablePointer<Float>.self) { m.render(UnsafePointer($0.baseAddress!), channelCount: 1, frames: 600) }
        }
        _ = ptrs
        XCTAssertEqual(buf[299], 1, accuracy: 1e-6)
        XCTAssertEqual(buf[300], 0)
    }

    func testFadeCurvesReachTargets() {
        var r = LevelRamp(0)
        r.set(to: showSilenceDB, at: 0, frames: 1000, curve: .linearGain)
        XCTAssertEqual(r.gain(at: 500), 0.5, accuracy: 1e-9)
        XCTAssertEqual(r.gain(at: 1000), 0)
        r = LevelRamp(-20)
        r.set(to: 0, at: 0, frames: 1000, curve: .linearDB)
        XCTAssertEqual(r.dB(at: 500), -10, accuracy: 1e-6)
        XCTAssertEqual(r.gain(at: 2000), 1, accuracy: 1e-9)
        XCTAssertEqual(FadeCurve.sCurve.shape(0.5), 0.5, accuracy: 1e-12)
    }

    // MARK: Engine

    func testGoHonoursPreWaitAndMovesPlayhead() {
        var doc = ShowDocument()
        var a = audioCue("a", "1"); a.preWait = 0.5
        let b = audioCue("a", "2")
        doc.lists[0].cues = [a, b]
        let rig = ShowRig(doc)
        rig.clips["a"] = constClip(0.25, frames: 4800)
        XCTAssertEqual(rig.engine.playhead, a.id)
        rig.engine.go(now: rig.now)
        XCTAssertEqual(rig.engine.playhead, b.id)
        rig.runSeconds(1)
        guard case let .start(id, _, _, at)? = rig.ops.first else { return XCTFail("no start") }
        XCTAssertEqual(id, a.id)
        XCTAssertEqual(at, 256 + 24000)
        XCTAssertEqual(rig.out[0][Int(at) - 1], 0)
        XCTAssertEqual(rig.out[0][Int(at)], 0.25, accuracy: 1e-6)
    }

    func testAutoContinueChainIsSkippedByPlayhead() {
        var doc = ShowDocument()
        var a = audioCue("a", "1"); a.continueMode = .autoContinue; a.postWait = 0.1
        var b = audioCue("a", "2"); b.continueMode = .autoFollow
        let c = audioCue("a", "3")
        let d = audioCue("a", "4")
        doc.lists[0].cues = [a, b, c, d]
        let rig = ShowRig(doc)
        rig.clips["a"] = constClip(0.1, frames: 4800) // 0.1 s
        rig.engine.go(now: rig.now)
        XCTAssertEqual(rig.engine.playhead, d.id, "playhead skips the continue chain")
        rig.runSeconds(1)
        let starts = rig.ops.compactMap { op -> (UUID, Int64)? in
            if case let .start(id, _, _, at) = op { return (id, at) } else { return nil }
        }
        XCTAssertEqual(starts.map(\.0), [a.id, b.id, c.id])
        XCTAssertEqual(starts[1].1 - starts[0].1, 4800, "auto-continue after post-wait")
        XCTAssertEqual(starts[2].1 - starts[1].1, 4800, "auto-follow at the end of the audio")
        XCTAssertFalse(rig.engine.isActive)
    }

    func testDoubleGoGuard() {
        var doc = ShowDocument()
        doc.lists[0].cues = [audioCue("a", "1"), audioCue("a", "2")]
        let rig = ShowRig(doc)
        rig.clips["a"] = constClip(0.1, frames: 48000)
        XCTAssertTrue(rig.engine.go(now: 0))
        XCTAssertFalse(rig.engine.go(now: 100))
        XCTAssertTrue(rig.engine.go(now: 48000))
    }

    func testGroupModes() {
        var doc = ShowDocument()
        var g = Cue(kind: .group)
        g.groupMode = .simultaneous
        var k1 = audioCue("a", ""); k1.preWait = 0.1
        let k2 = audioCue("b", "")
        g.children = [k1, k2]
        var p = Cue(kind: .group)
        p.groupMode = .playlist
        p.children = [audioCue("a", ""), audioCue("b", "")]
        doc.lists[0].cues = [g, p]
        let rig = ShowRig(doc)
        rig.clips["a"] = constClip(0.1, frames: 4800)
        rig.clips["b"] = constClip(0.1, frames: 2400)
        rig.engine.go(now: 0)
        rig.runSeconds(0.5)
        var starts = rig.ops.compactMap { op -> (UUID, Int64)? in
            if case let .start(id, _, _, at) = op { return (id, at) } else { return nil }
        }
        XCTAssertEqual(Set(starts.map(\.0)), [k1.id, k2.id])
        XCTAssertEqual(starts.first { $0.0 == k1.id }!.1 - starts.first { $0.0 == k2.id }!.1, 4800)
        XCTAssertFalse(rig.engine.isActive, "group ends with its last child")
        rig.ops.removeAll()
        rig.engine.go(now: rig.now)
        rig.runSeconds(0.5)
        starts = rig.ops.compactMap { op -> (UUID, Int64)? in
            if case let .start(id, _, _, at) = op { return (id, at) } else { return nil }
        }
        XCTAssertEqual(starts.map(\.0), p.children.map(\.id))
        XCTAssertEqual(starts[1].1 - starts[0].1, 4800, "playlist: next child at the end of the previous")
    }

    func testFadeCueFadesAndStops() {
        var doc = ShowDocument()
        let a = audioCue("a", "1", plays: 0)
        var f = Cue(kind: .fade, number: "2")
        f.target = a.id
        f.fade?.duration = 0.5
        f.fade?.curve = .linearGain
        doc.lists[0].cues = [a, f]
        let rig = ShowRig(doc)
        rig.clips["a"] = constClip(1, frames: 4800)
        rig.engine.go(now: 0)
        rig.runSeconds(0.5)
        rig.engine.go(now: rig.now)
        let fadeStart = Int(rig.now) + 256
        rig.runSeconds(1)
        XCTAssertEqual(rig.out[0][fadeStart + 12000], 0.5, accuracy: 0.01)
        XCTAssertEqual(rig.out[0][fadeStart + 24100], 0)
        XCTAssertFalse(rig.engine.isActive, "stop when done ends the looping cue")
    }

    func testDevampPredictionMatchesAudio() {
        var doc = ShowDocument()
        var a = audioCue("a", "1", plays: 0)
        a.audio?.rate = 1.5
        var d = Cue(kind: .devamp, number: "2")
        d.target = a.id
        d.devampStartsNext = true
        let after = audioCue("b", "3")
        doc.lists[0].cues = [a, d, after]
        let rig = ShowRig(doc)
        rig.clips["a"] = constClip(1, frames: 1000, channels: 1)
        rig.clips["b"] = constClip(0.5, frames: 1000, channels: 1)
        rig.engine.go(now: 0)
        rig.run(20000)
        rig.engine.go(now: rig.now)
        rig.run(4000)
        let lastLoud = rig.out[0].lastIndex { abs($0 - 1) < 1e-6 }!
        let next = rig.ops.compactMap { op -> Int64? in
            if case let .start(id, _, _, at) = op, id == after.id { return at } else { return nil }
        }.first!
        XCTAssertEqual(Int(next), lastLoud + 1, "next cue starts on the first frame after the loop")
    }

    func testPauseResumeShiftsEnd() {
        var doc = ShowDocument()
        var a = audioCue("a", "1"); a.continueMode = .autoFollow
        let b = audioCue("a", "2")
        doc.lists[0].cues = [a, b]
        let rig = ShowRig(doc)
        rig.clips["a"] = constClip(0.1, frames: 4800)
        rig.engine.go(now: 0)
        rig.run(2048)
        rig.engine.pause(a.id, now: rig.now)
        rig.run(4800)
        XCTAssertTrue(rig.engine.snapshot(now: rig.now).running.first?.paused == true)
        rig.engine.resume(a.id, now: rig.now)
        rig.runSeconds(0.5)
        let starts = rig.ops.compactMap { op -> Int64? in
            if case let .start(_, _, _, at) = op { return at } else { return nil }
        }
        XCTAssertEqual(starts.count, 2)
        XCTAssertEqual(starts[1] - starts[0], 4800 + 4800, "end moved by the pause length")
    }

    func testPanicFadesThenCuts() {
        var doc = ShowDocument()
        doc.lists[0].cues = [audioCue("a", "1", plays: 0)]
        let rig = ShowRig(doc)
        rig.clips["a"] = constClip(1, frames: 4800)
        rig.engine.go(now: 0)
        rig.runSeconds(0.1)
        rig.engine.panic(now: rig.now)
        rig.runSeconds(0.2)
        XCTAssertTrue(rig.engine.isActive, "first panic fades")
        rig.engine.panic(now: rig.now)
        XCTAssertFalse(rig.engine.isActive, "second panic cuts")
        rig.run(512)
        XCTAssertEqual(rig.out[0].last, 0)
    }

    func testControlCues() {
        var doc = ShowDocument()
        let a = audioCue("a", "1", plays: 0)
        var stop = Cue(kind: .stop, number: "2"); stop.target = a.id
        var dis = Cue(kind: .disarm, number: "3"); dis.target = a.id
        var goTo = Cue(kind: .goTo, number: "4"); goTo.target = a.id
        doc.lists[0].cues = [a, stop, dis, goTo]
        let rig = ShowRig(doc)
        rig.clips["a"] = constClip(1, frames: 4800)
        var changed = false
        rig.engine.documentChanged = { _ in changed = true }
        rig.engine.go(now: 0); rig.run(20000)
        rig.engine.go(now: rig.now); rig.run(20000)
        XCTAssertFalse(rig.engine.isActive)
        rig.engine.go(now: rig.now); rig.run(20000)
        XCTAssertTrue(changed)
        XCTAssertEqual(rig.engine.document.cue(a.id)?.armed, false)
        rig.engine.go(now: rig.now); rig.run(20000)
        XCTAssertEqual(rig.engine.playhead, a.id)
        rig.engine.go(now: rig.now); rig.run(20000)
        XCTAssertEqual(rig.ops.filter { if case .start = $0 { return true } else { return false } }.count, 1,
                       "disarmed cue does not play")
    }

    func testMissingFileIsReportedAndChainContinues() {
        var doc = ShowDocument()
        var a = audioCue("missing", "1"); a.continueMode = .autoFollow
        let b = audioCue("a", "2")
        doc.lists[0].cues = [a, b]
        let rig = ShowRig(doc)
        rig.clips["a"] = constClip(0.1, frames: 480)
        rig.engine.go(now: 0)
        rig.run(2048)
        XCTAssertEqual(rig.engine.problems[a.id], "error.show.missingFile")
        XCTAssertEqual(rig.ops.count, 1)
    }

    func testPlayheadFollowsAddedAndDeletedCues() {
        var doc = ShowDocument()
        doc.lists[0].cues = []
        let rig = ShowRig(doc)
        XCTAssertNil(rig.engine.playhead, "empty list: end of list")
        let a = audioCue("a", "1"), b = audioCue("b", "2"), c = audioCue("c", "3")
        doc.lists[0].cues = [a]
        rig.engine.document = doc
        XCTAssertEqual(rig.engine.playhead, a.id, "a cue added to an empty list is ready for GO")
        rig.clips["a"] = constClip(0.1, frames: 480)
        XCTAssertTrue(rig.engine.go(now: 0))
        XCTAssertNil(rig.engine.playhead, "after the last cue: end of list")
        doc.lists[0].cues = [a, b, c]
        rig.engine.document = doc
        XCTAssertEqual(rig.engine.playhead, b.id, "cues added after the end: the first new one is next")
        doc.lists[0].cues = [a, c]
        rig.engine.document = doc
        XCTAssertEqual(rig.engine.playhead, c.id, "the cue on the playhead deleted: the next one")
        rig.engine.setPlayhead(a.id)
        doc.lists[0].cues = [a, b, c]
        rig.engine.document = doc
        XCTAssertEqual(rig.engine.playhead, a.id, "an existing playhead stays")
    }

    func testFileStillBeingPreparedPlaysWhenReady() {
        var doc = ShowDocument()
        var a = audioCue("a", "1"); a.continueMode = .autoFollow
        let b = audioCue("b", "2")
        doc.lists[0].cues = [a, b]
        let rig = ShowRig(doc)
        rig.engine.clipPending = { _ in true }
        rig.clips["b"] = constClip(0.1, frames: 480)
        rig.engine.go(now: 0)
        rig.run(4800)
        XCTAssertEqual(rig.engine.problems[a.id], "error.show.notReady")
        XCTAssertTrue(rig.ops.isEmpty, "nothing plays while the file is decoded, the chain waits")
        rig.clips["a"] = constClip(0.5, frames: 4800)
        rig.run(4800 * 3)
        XCTAssertNil(rig.engine.problems[a.id])
        XCTAssertTrue(rig.out[0].contains { abs($0 - 0.5) < 1e-6 }, "the cue played once its file was ready")
        XCTAssertTrue(rig.out[0].contains { abs($0 - 0.1) < 1e-6 }, "auto-follow continued after it")
    }

    func testFileReadyButUnplayableEndsTheCueAndTheChainGoesOn() {
        var doc = ShowDocument()
        var a = audioCue("a", "1"); a.continueMode = .autoFollow
        let b = audioCue("b", "2")
        doc.lists[0].cues = [a, b]
        let rig = ShowRig(doc)
        rig.engine.clipPending = { _ in true }
        rig.clips["b"] = constClip(0.1, frames: 480)
        rig.engine.go(now: 0)
        rig.run(2400)
        rig.clips["a"] = AudioClip(sampleRate: 48000, channels: [[]])   // decoded, but empty
        rig.run(4800 * 2)
        XCTAssertEqual(rig.engine.problems[a.id], "error.show.missingFile")
        XCTAssertTrue(rig.out[0].contains { abs($0 - 0.1) < 1e-6 }, "the chain went on to the next cue")
    }

    func testFileThatNeverBecomesReadyIsReportedAfterTimeout() {
        var doc = ShowDocument()
        let a = audioCue("a", "1")
        doc.lists[0].cues = [a]
        let rig = ShowRig(doc)
        rig.engine.clipPending = { _ in true }
        rig.engine.clipWaitSeconds = 0.2
        rig.engine.go(now: 0)
        rig.runSeconds(0.5)
        XCTAssertEqual(rig.engine.problems[a.id], "error.show.missingFile")
        XCTAssertFalse(rig.engine.isActive)
    }

    // MARK: Editing

    func testEditingOperations() {
        var doc = ShowDocument()
        let l = doc.lists[0].id
        let a = audioCue("a", "1"), b = audioCue("b", "2"), c = audioCue("c", "3")
        var f = Cue(kind: .fade); f.target = b.id
        doc.insert([a, b, c, f], after: nil, list: l)
        let g = doc.group([c.id, a.id], list: l)!
        XCTAssertEqual(doc.lists[0].cues.map(\.id), [g, b.id, f.id])
        XCTAssertEqual(doc.cue(g)?.children.map(\.id), [a.id, c.id])
        let copies = doc.duplicate([g], list: l)
        XCTAssertEqual(doc.lists[0].cues.count, 4)
        XCTAssertNotEqual(doc.cue(copies[0])?.children.first?.id, a.id)
        doc.ungroup(g, list: l)
        XCTAssertEqual(doc.lists[0].cues.prefix(2).map(\.id), [a.id, c.id])
        doc.delete([b.id])
        XCTAssertNil(doc.cue(f.id)?.target, "targets of deleted cues are cleared")
        doc.move(f.id, by: -1, list: l)
        doc.move([f.id], before: a.id, list: l)
        XCTAssertEqual(doc.lists[0].cues.first?.id, f.id)
        doc.renumber(list: l, start: 10, step: 10)
        XCTAssertEqual(doc.cue(f.id)?.number, "10")
        XCTAssertEqual(doc.cue(a.id)?.number, "20")
    }

    func testIssuesAndCodable() throws {
        var doc = ShowDocument(name: "Test")
        var a = audioCue("a.wav", "1"); a.hotkey = "q"
        var b = audioCue("b.wav", "1"); b.hotkey = "Q"
        let s = Cue(kind: .stop)
        b.audio?.end = 0
        doc.lists[0].cues = [a, b, s, Cue(kind: .group)]
        let issues = doc.issues { $0.audio?.file == "a.wav" }
        XCTAssertTrue(issues.contains(.missingFile(b.id)))
        XCTAssertTrue(issues.contains(.missingTarget(s.id)))
        XCTAssertTrue(issues.contains(.duplicateNumber("1")))
        XCTAssertTrue(issues.contains(.duplicateHotkey("q")))
        XCTAssertTrue(issues.contains(.invalidRegion(b.id)))
        let back = try ShowDocument.decode(doc.encoded())
        XCTAssertEqual(back, doc)
        // Older / partial files decode with defaults.
        let minimal = #"{"lists":[{"id":"\#(UUID())","name":"L","cues":[{"id":"\#(UUID())","kind":"memo"}]}]}"#
        let m = try ShowDocument.decode(Data(minimal.utf8))
        XCTAssertEqual(m.lists[0].cues[0].armed, true)
    }

    // MARK: Pads and timeline

    func testPadModes() {
        var doc = ShowDocument()
        var toggle = audioCue("a", "", plays: 0); toggle.padMode = .toggle
        var hold = audioCue("a", "", plays: 0); hold.padMode = .hold
        var restart = audioCue("a", "", plays: 0); restart.padMode = .restart
        doc.lists[1].cues = [toggle, hold, restart]
        XCTAssertTrue(doc.lists[1].isBank)
        let rig = ShowRig(doc)
        rig.clips["a"] = constClip(0.1, frames: 4800)
        XCTAssertNotEqual(rig.engine.playhead, toggle.id, "pads are never on the GO playhead")
        rig.engine.pad(toggle.id, pressed: true, now: rig.now); rig.run(2000)
        XCTAssertTrue(rig.engine.isRunning(toggle.id))
        rig.engine.pad(toggle.id, pressed: false, now: rig.now); rig.run(2000)
        XCTAssertTrue(rig.engine.isRunning(toggle.id), "release does nothing in toggle mode")
        rig.engine.pad(toggle.id, pressed: true, now: rig.now); rig.run(4000)
        XCTAssertFalse(rig.engine.isRunning(toggle.id))
        rig.engine.pad(hold.id, pressed: true, now: rig.now); rig.run(2000)
        XCTAssertTrue(rig.engine.isRunning(hold.id))
        rig.engine.pad(hold.id, pressed: false, now: rig.now); rig.run(4000)
        XCTAssertFalse(rig.engine.isRunning(hold.id))
        rig.engine.pad(restart.id, pressed: true, now: rig.now); rig.run(2000)
        rig.engine.pad(restart.id, pressed: true, now: rig.now); rig.run(2000)
        XCTAssertTrue(rig.engine.isRunning(restart.id))
        XCTAssertEqual(rig.ops.filter { if case let .start(id, _, _, _) = $0 { return id == restart.id } else { return false } }.count, 2)
    }

    func testTimelinePlan() {
        var doc = ShowDocument()
        var a = audioCue("a", "1"); a.continueMode = .autoContinue; a.postWait = 2
        var f = Cue(kind: .fade, number: "2"); f.target = a.id; f.fade?.duration = 3; f.continueMode = .autoFollow
        var g = Cue(kind: .group, number: "3"); g.groupMode = .simultaneous
        var k1 = audioCue("b", ""); k1.preWait = 1
        let k2 = audioCue("loop", "", plays: 0)
        g.children = [k1, k2]
        let after = audioCue("a", "4")
        doc.lists[0].cues = [a, f, g, after]
        let lengths = ["a": 10.0, "b": 4.0, "loop": 6.0]
        let clips = ShowTimeline.plan(doc, from: a.id) { lengths[$0.audio?.file ?? ""] }
        func clip(_ id: UUID) -> TimelineClip? { clips.first { $0.cueID == id } }
        XCTAssertEqual(clip(a.id)?.start, 0)
        XCTAssertEqual(clip(a.id)?.duration, 10)
        XCTAssertEqual(clip(f.id)?.start, 2)
        XCTAssertEqual(clip(f.id)?.lane, ShowTimeline.controlLane)
        XCTAssertEqual(clip(k1.id)?.start, 5 + 1, "group starts when the fade ends; child pre-wait")
        XCTAssertNil(clip(k2.id)?.duration, "loop is open-ended")
        XCTAssertNil(clip(after.id), "group waits for GO")
        let lanes = Set(clips.filter { $0.style == .audio }.map(\.lane))
        XCTAssertEqual(lanes.count, 3, "three overlapping audio clips need three tracks")
        let inGroup = ShowTimeline.planGroup(doc, group: g.id) { lengths[$0.audio?.file ?? ""] }
        XCTAssertEqual(inGroup.first { $0.cueID == k1.id }?.start, 1)
        let multitrack = ShowTimeline.planGroup(doc, group: g.id, fileLength: { lengths[$0.audio?.file ?? ""] }, lanePerCue: true)
        XCTAssertEqual(multitrack.first { $0.cueID == k1.id }?.lane, 0, "multitrack: one track per cue, in group order")
        XCTAssertEqual(multitrack.first { $0.cueID == k2.id }?.lane, 1)
    }

    // MARK: Inner loop (intro → loop → outro)

    func testInnerLoopPlaysIntroLoopOutro() {
        let m = ShowMixer(sampleRate: 48000, maxOutputs: 2, maxVoices: 4)
        let ramp = (0..<1000).map { Float($0) / 1000 }
        let clip = AudioClip(sampleRate: 48000, channels: [ramp])
        var a = AudioCueParams(file: "x")
        a.loopStart = 200.0 / 48000
        a.loopEnd = 400.0 / 48000
        a.plays = 2
        let map = a.playMap(fileLength: clip.duration, scale: 48000)
        XCTAssertEqual(map.total ?? 0, 1200, accuracy: 0.5)
        m.send(.start(UUID(), clip: clip, setup: VoiceSetup(map: map, rate: 1, levelDB: 0, outputLevelsDB: [0],
                                                             crosspointsDB: [[0]]), at: 0))
        let buf = UnsafeMutablePointer<Float>.allocate(capacity: 1400)
        defer { buf.deallocate() }
        var ptrs = [buf]
        ptrs.withUnsafeMutableBufferPointer { p in
            p.withMemoryRebound(to: UnsafeMutablePointer<Float>.self) { m.render(UnsafePointer($0.baseAddress!), channelCount: 1, frames: 1400) }
        }
        _ = ptrs
        XCTAssertEqual(buf[150], 0.150, accuracy: 1e-4, "intro")
        XCTAssertEqual(buf[450], 0.250, accuracy: 1e-4, "second pass of the loop")
        XCTAssertEqual(buf[650], 0.450, accuracy: 1e-4, "outro")
        XCTAssertEqual(buf[1250], 0, "ended")
    }

    func testDevampLeavesInnerLoopIntoOutro() {
        var doc = ShowDocument()
        var a = audioCue("a", "1", plays: 0)
        a.audio?.loopStart = 1000.0 / 48000
        a.audio?.loopEnd = 2000.0 / 48000
        var d = Cue(kind: .devamp, number: "2"); d.target = a.id
        doc.lists[0].cues = [a, d]
        let rig = ShowRig(doc)
        rig.clips["a"] = AudioClip(sampleRate: 48000, channels: [(0..<3000).map { $0 < 2000 ? 1 : 0.5 }])
        rig.engine.go(now: 0)
        rig.run(20000)                       // still looping
        XCTAssertTrue(rig.engine.isActive)
        rig.engine.go(now: rig.now)
        rig.run(4000)
        XCTAssertFalse(rig.engine.isActive, "outro played, cue ended")
        XCTAssertTrue(rig.out[0].contains { abs($0 - 0.5) < 1e-6 }, "outro (after the loop) was heard")
        let snapEnd = rig.out[0].lastIndex { abs($0 - 0.5) < 1e-6 }!
        XCTAssertEqual(rig.out[0][snapEnd + 1], 0)
    }

    func testTimelineDurationWithInnerLoop() {
        var c = audioCue("a", "1", plays: 3)
        c.audio?.loopStart = 2
        c.audio?.loopEnd = 4
        XCTAssertEqual(ShowTimeline.audioDuration(c, fileLength: 10) ?? 0, 2 + 2 * 3 + 6, accuracy: 1e-9)
        c.audio?.plays = 0
        XCTAssertNil(ShowTimeline.audioDuration(c, fileLength: 10))
    }

    // MARK: OSC

    func testOSCEncodingMatchesSpec() {
        // "/a" ",if" 1 0.5 → known bytes.
        let d = OSCMessage("/a", [.int(1), .float(0.5)]).encoded()
        XCTAssertEqual([UInt8](d), [0x2f, 0x61, 0, 0, 0x2c, 0x69, 0x66, 0, 0, 0, 0, 1, 0x3f, 0, 0, 0])
        let s = OSCMessage("/eos/cmd", [.string("Go#"), .bool(true)])
        XCTAssertEqual(OSCMessage.decode(s.encoded()), [s])
        XCTAssertEqual(OSCMessage.decode(OSCMessage("/go").encoded()), [OSCMessage("/go")])
        XCTAssertNil(OSCMessage.decode(Data([1, 2, 3])))
    }

    func testOSCPresetsBuildMessages() {
        let resolume = OSCDevice(name: "R", kind: .resolume)
        XCTAssertEqual(resolume.port, 7000)
        let clip = OSCPreset.presets(for: .resolume).first { $0.id == "resolume.clip" }!
        XCTAssertEqual(clip.message(["layer": "2", "clip": "5"], device: resolume),
                       OSCMessage("/composition/layers/2/clips/5/connect", [.int(1)]))
        let x32 = OSCDevice(name: "X", kind: .x32)
        let fader = OSCPreset.presets(for: .x32).first { $0.id == "x32.fader" }!
        XCTAssertEqual(fader.message(["channel": "7", "value": "0.5"], device: x32), OSCMessage("/ch/07/mix/fader", [.float(0.5)]))
        var ma = OSCDevice(name: "MA", kind: .grandMA3)
        ma.prefix = "stage"
        let go = OSCPreset.presets(for: .grandMA3).first { $0.id == "ma3.cue" }!
        XCTAssertEqual(go.message(["sequence": "3", "cue": "12"], device: ma), OSCMessage("/stage/cmd", [.string("Goto Sequence 3 Cue 12")]))
    }

    func testNetworkCueSendsAndChecksDevice() {
        var doc = ShowDocument()
        let dev = OSCDevice(name: "Resolume", kind: .resolume)
        doc.devices = [dev]
        var a = Cue(kind: .network, number: "1")
        a.osc?.device = dev.id
        a.osc?.address = "/composition/columns/2/connect"
        a.osc?.arguments = [.int(1)]
        a.continueMode = .autoContinue
        var b = Cue(kind: .network, number: "2")
        b.osc?.address = "/x"
        doc.lists[0].cues = [a, b]
        let rig = ShowRig(doc)
        var sent: [(String, OSCMessage)] = []
        rig.engine.oscSend = { d, m in sent.append((d.name, m)) }
        rig.engine.go(now: 0)
        rig.run(1000)
        XCTAssertEqual(sent.map(\.0), ["Resolume"])
        XCTAssertEqual(sent.first?.1, OSCMessage("/composition/columns/2/connect", [.int(1)]))
        XCTAssertEqual(rig.engine.problems[b.id], "error.show.noDevice")
        XCTAssertTrue(doc.issues { _ in true }.contains(.missingDevice(b.id)))
        XCTAssertEqual(try ShowDocument.decode(doc.encoded()), doc)
    }

    func testSubnetCheck() {
        let ifs = [(address: "192.168.1.20", mask: "255.255.255.0")]
        XCTAssertEqual(IPv4.reachableDirectly("192.168.1.55", interfaces: ifs), true)
        XCTAssertEqual(IPv4.reachableDirectly("192.168.2.55", interfaces: ifs), false)
        XCTAssertEqual(IPv4.reachableDirectly("127.0.0.1", interfaces: ifs), true)
        XCTAssertNil(IPv4.reachableDirectly("resolume.local", interfaces: ifs))
    }

    // MARK: QLab import

    func testQLabImportFromOSCReplies() throws {
        let json = """
        {"status":"ok","data":[
          {"uniqueID":"L1","type":"Cue List","listName":"Main Cue List","cues":[
            {"uniqueID":"A","number":"1","name":"Preshow","type":"Audio","colorName":"blue","armed":true,"cues":[]},
            {"uniqueID":"F","number":"2","name":"","type":"Fade","colorName":"none","armed":true,"cues":[]},
            {"uniqueID":"G","number":"3","name":"Scene","type":"Group","colorName":"none","armed":true,"cues":[
              {"uniqueID":"V","number":"3.1","name":"Projection","type":"Video","colorName":"none","armed":true,"cues":[]}
            ]},
            {"uniqueID":"S","number":"4","name":"","type":"Stop","colorName":"none","armed":false,"cues":[]}
          ]},
          {"uniqueID":"C1","type":"Cart","listName":"Effects","cues":[
            {"uniqueID":"B","number":"","name":"Bell","type":"Audio","colorName":"none","armed":true,"cues":[]}
          ]}
        ]}
        """
        let data = try XCTUnwrap(QLabImport.replyData(json) as? [[String: Any]])
        var lists = data.map(QLabImport.item(fromJSON:))
        // valuesForKeys replies merged per cue.
        func values(_ id: String) -> [String: Any] {
            switch id {
            case "A": return ["fileTarget": "/Sounds/Preshow.wav", "infiniteLoop": true, "continueMode": 1, "postWait": 2.5, "startTime": 1.0]
            case "F": return ["duration": 4.0, "cueTargetID": "A", "stopTargetWhenDone": true]
            case "G": return ["mode": 3, "preWait": 1.0]
            case "S": return ["cueTargetID": "G"]
            default: return [:]
            }
        }
        func fill(_ q: inout QLabImport.Item) {
            QLabImport.merge(values: values(q.uniqueID), into: &q)
            for i in q.children.indices { fill(&q.children[i]) }
        }
        for i in lists.indices { fill(&lists[i]) }
        let (doc, report) = QLabImport.makeShow(name: "Gala", lists: lists)
        XCTAssertEqual(report.lists, 1)
        XCTAssertEqual(report.banks, 1)
        XCTAssertEqual(report.unsupported, ["Video": 1])
        XCTAssertEqual(report.lostTargets, 0)
        let main = doc.cueLists[0]
        XCTAssertEqual(main.name, "Main Cue List")
        let a = main.cues[0]
        XCTAssertEqual(a.kind, .audio)
        XCTAssertEqual(a.audio?.file, "/Sounds/Preshow.wav")
        XCTAssertEqual(a.audio?.plays, 0)
        XCTAssertEqual(a.audio?.start, 1)
        XCTAssertEqual(a.continueMode, .autoContinue)
        XCTAssertEqual(a.color, "blue")
        let f = main.cues[1]
        XCTAssertEqual(f.target, a.id)
        XCTAssertEqual(f.fade?.duration, 4)
        XCTAssertEqual(f.fade?.level, showSilenceDB)
        XCTAssertEqual(main.cues[2].groupMode, .simultaneous)
        XCTAssertEqual(main.cues[2].children.first?.kind, .memo, "unsupported type kept as a memo")
        XCTAssertEqual(main.cues[3].target, main.cues[2].id)
        XCTAssertFalse(main.cues[3].armed)
        XCTAssertEqual(doc.banks.first?.cues.first?.name, "Bell")
    }

    func testQLabFileArchiveIsRead() throws {
        // A keyed archive as written by NSKeyedArchiver (UIDs as CF$UID dictionaries in XML form).
        func uid(_ i: Int) -> [String: Any] { ["CF$UID": i] }
        let objects: [Any] = [
            "$null",
            ["NS.keys": [uid(2)], "NS.objects": [uid(3)], "$class": uid(9)],          // 1: root {cueLists: [...]}
            "cueLists",                                                                  // 2
            ["NS.objects": [uid(4)], "$class": uid(9)],                                  // 3: [list]
            ["NS.keys": [uid(5), uid(6), uid(7)], "NS.objects": [uid(8), uid(10), uid(11)], "$class": uid(9)], // 4: list
            "type", "name", "cues",                                                      // 5, 6, 7
            "Cue List",                                                                  // 8
            ["$classname": "NSDictionary"],                                              // 9
            "Act 1",                                                                     // 10
            ["NS.objects": [uid(12)], "$class": uid(9)],                                 // 11: [cue]
            ["NS.keys": [uid(5), uid(13), uid(14), uid(15)], "NS.objects": [uid(16), uid(17), uid(18), uid(19)], "$class": uid(9)], // 12
            "number", "uniqueID", "path",                                                // 13, 14, 15
            "Audio", "1", "X1", "Music/Overture.wav",                                    // 16…19
        ]
        let archive: [String: Any] = ["$archiver": "NSKeyedArchiver", "$version": 100000, "$top": ["root": uid(1)], "$objects": objects]
        let data = try PropertyListSerialization.data(fromPropertyList: archive, format: .xml, options: 0)
        let lists = try XCTUnwrap(QLabImport.lists(fromFile: data))
        XCTAssertEqual(lists.first?.name, "Act 1")
        XCTAssertEqual(lists.first?.children.first?.type, "Audio")
        XCTAssertEqual(lists.first?.children.first?.fileTarget, "Music/Overture.wav")
        XCTAssertNil(QLabImport.lists(fromFile: Data("not a workspace".utf8)))
    }

    // MARK: Reliability

    func testMappedClipPlaysLikeOwnedClip() throws {
        let samples = (0..<4800).map { Float(sin(Double($0) * 0.01)) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ssmt-mapped-\(UUID()).raw")
        let raw = samples + samples.map { -$0 }
        try raw.withUnsafeBytes { Data($0) }.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let mapped = try XCTUnwrap(AudioClip(sampleRate: 48000, channelCount: 2,
                                             mapped: try NSData(contentsOf: url, options: .alwaysMapped)))
        XCTAssertTrue(mapped.isMapped)
        XCTAssertEqual(mapped.frames, 4800)
        XCTAssertEqual(mapped.channel(1)[100], -samples[100])
        mapped.prefetch(from: 0, count: 4800)
        XCTAssertNil(AudioClip(sampleRate: 48000, channelCount: 3, mapped: NSData(data: Data(count: 10))))
    }

    /// Thousands of random operations (GO, stops, pauses, pads, panic, edits while playing):
    /// nothing may crash, and a hard panic always leaves silence and no running cues.
    func testRandomOperationsNeverBreakTheEngine() {
        var doc = ShowDocument()
        var cues: [Cue] = []
        for i in 0..<30 {
            var c: Cue
            switch i % 7 {
            case 0: c = audioCue("a", "\(i)", plays: 0)
            case 1: c = Cue(kind: .fade, number: "\(i)"); c.fade?.duration = 0.2
            case 2: c = Cue(kind: .group, number: "\(i)"); c.groupMode = GroupMode.allCases[i % 4]; c.children = [audioCue("b", ""), audioCue("a", "")]
            case 3: c = Cue(kind: .wait, number: "\(i)"); c.duration = 0.1
            case 4: c = Cue(kind: .devamp, number: "\(i)")
            case 5: c = Cue(kind: .stop, number: "\(i)")
            default: c = audioCue("b", "\(i)")
            }
            c.continueMode = ContinueMode.allCases[i % 3]
            c.preWait = Double(i % 3) * 0.05
            cues.append(c)
        }
        for i in cues.indices where cues[i].kind.needsTarget { cues[i].target = cues[(i + 3) % cues.count].id }
        doc.lists[0].cues = cues
        doc.lists[1].cues = [audioCue("a", ""), audioCue("b", "")]
        doc.doubleGoGuard = 0
        let rig = ShowRig(doc)
        rig.clips["a"] = constClip(0.1, frames: 2400)
        rig.clips["b"] = constClip(0.1, frames: 900, channels: 1)
        var rng = SystemRandomNumberGenerator()
        rig.engine.random = { Double.random(in: 0..<1, using: &rng) }
        let pads = doc.lists[1].cues.map(\.id)
        for step in 0..<3000 {
            let all = rig.engine.document.allCues.map(\.id)
            switch Int.random(in: 0..<10, using: &rng) {
            case 0, 1, 2: rig.engine.go(now: rig.now)
            case 3: if let id = all.randomElement(using: &rng) { rig.engine.stop(id, now: rig.now, fade: 0.05) }
            case 4: if let id = all.randomElement(using: &rng) { rig.engine.pause(id, now: rig.now) }
            case 5: if let id = all.randomElement(using: &rng) { rig.engine.resume(id, now: rig.now) }
            case 6: rig.engine.pad(pads.randomElement(using: &rng)!, pressed: Bool.random(using: &rng), now: rig.now)
            case 7: rig.engine.setPlayhead(rig.engine.document.lists[0].cues.randomElement(using: &rng)?.id)
            case 8:
                // Edit while playing: delete or re-add cues.
                var d = rig.engine.document
                if step % 2 == 0, let id = all.randomElement(using: &rng) { d.delete([id]) } else { d.lists[0].cues.append(audioCue("a", "x")) }
                rig.engine.document = d
            default: rig.engine.panic(now: rig.now)
            }
            rig.run(Int.random(in: 64...2048, using: &rng))
            rig.engine.prefetch(now: rig.now)
            _ = rig.engine.snapshot(now: rig.now)
        }
        rig.engine.panic(now: rig.now, hard: true)
        rig.run(4096)
        XCTAssertFalse(rig.engine.isActive)
        XCTAssertTrue(rig.out[0].suffix(1024).allSatisfy { $0 == 0 }, "silence after a hard panic")
        XCTAssertEqual(rig.mixer.droppedCommands.value, 0)
    }

    /// 64 stereo voices with fades must render far faster than real time.
    func testMixerHandlesManyVoicesQuickly() {
        let m = ShowMixer(sampleRate: 48000, maxOutputs: 16, maxVoices: 128)
        let clip = constClip(0.01, frames: 48000 * 10)
        for i in 0..<64 {
            var xp = [[Double]](repeating: [Double](repeating: showSilenceDB, count: 16), count: 2)
            xp[0][i % 16] = 0; xp[1][(i + 1) % 16] = 0
            let setup = VoiceSetup(regionStart: 1000, regionLength: 48000 * 9, plays: 0, rate: i % 2 == 0 ? 1 : 0.97, levelDB: -6,
                                   outputLevelsDB: [Double](repeating: 0, count: 16), crosspointsDB: xp, fadeInFrames: 4800, fadeOutFrames: 0)
            m.send(.start(UUID(), clip: clip, setup: setup, at: 0))
        }
        let bufs = (0..<16).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: 512) }
        defer { bufs.forEach { $0.deallocate() } }
        let blocks = 48000 * 5 / 512 // 5 s of audio
        let t0 = Date()
        for _ in 0..<blocks {
            bufs.withUnsafeBufferPointer { m.render($0.baseAddress!, channelCount: 16, frames: 512) }
        }
        let elapsed = Date().timeIntervalSince(t0)
        XCTAssertLessThan(elapsed, 2.5, "64 voices: \(elapsed) s to render 5 s of audio")
        m.collectGarbage()
    }
}

final class ShowMediaTests: XCTestCase {
    func testCopiesKeepDifferentFilesWithTheSameNameApart() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let a = root.appendingPathComponent("a/Intro.wav"), b = root.appendingPathComponent("b/Intro.wav")
        try fm.createDirectory(at: a.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: b.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3, 4]).write(to: a)
        try Data([9, 9, 9, 9]).write(to: b)                 // same name, same size, other contents
        let media = root.appendingPathComponent("Show Audio")
        let first = ShowMedia.copy([a, b], into: media)
        XCTAssertEqual(first.copied.map(\.lastPathComponent), ["Intro.wav", "Intro 2.wav"])
        XCTAssertEqual(try Data(contentsOf: first.copied[1]), Data([9, 9, 9, 9]))
        let again = ShowMedia.copy([a, b, first.copied[0]], into: media)
        XCTAssertEqual(again.copied.map(\.lastPathComponent), ["Intro.wav", "Intro 2.wav", "Intro.wav"], "saving again reuses the copies")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: media.path).count, 2)
        XCTAssertEqual(ShowMedia.copy([root.appendingPathComponent("none.wav")], into: media).errors.count, 1)
    }
}
