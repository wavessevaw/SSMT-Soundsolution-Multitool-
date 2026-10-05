import XCTest
@testable import SSMTCore

final class LearnTests: XCTestCase {
    // MARK: read-only link

    func testReadOnlyLetsQueriesAndMetersThroughOnly() {
        XCTAssertTrue(ConsoleReadOnly.allows(OSCMessage("/ch/01/mix/fader")))
        XCTAssertTrue(ConsoleReadOnly.allows(X32Codec.subscribe(family: .x32)))
        XCTAssertTrue(ConsoleReadOnly.allows(ConsoleMeters.request(.channels, family: .x32)))
        XCTAssertFalse(ConsoleReadOnly.allows(OSCMessage("/ch/01/mix/fader", [.float(0.75)])))
        XCTAssertFalse(ConsoleReadOnly.allows(OSCMessage("/main/st/mix/on", [.int(0)])))
        XCTAssertFalse(ConsoleReadOnly.allows(OSCMessage("/meters", [.int(1)])))
        // Everything the assistant would write to a strip is dropped.
        var s = ChannelStrip(id: 3, name: "Vox", gainDB: 30, faderDB: -5)
        s.eq[2].gainDB = 3
        let writes = X32Codec.messages(from: nil, to: s, family: .x32, routing: .localInputs)
        XCTAssertFalse(writes.isEmpty)
        XCTAssertTrue(ConsoleReadOnly.filter(writes).isEmpty)
        // What learning mode sends when it connects is all read-only.
        for fam in [MixerFamily.x32, .xAir] {
            let reqs = ConsoleReadOnly.connectRequests(family: fam, routing: .localInputs)
            XCTAssertEqual(ConsoleReadOnly.filter(reqs).count, reqs.count, "\(fam)")
            XCTAssertTrue(reqs.contains { $0.address == "/ch/01/mix/fader" })
        }
    }

    // MARK: recorder

    func testRecorderStoresChangesAndReplaysTheConsole() {
        var rec = LearningRecorder(header: LearnHeader(title: "Test", console: "x32"))
        rec.keyInterval = 60
        var strips = [1: ChannelStrip(id: 1, name: "Kick", gainDB: 30, faderDB: -10), 2: ChannelStrip(id: 2, name: "Vox", faderDB: -5)]
        let buses = [1: BusStrip(id: 1, name: "Mon 1", faderDB: -3)]
        var data = rec.headerLine()
        for t in 0..<120 {
            if t == 30 { strips[2]!.faderDB = -2 }
            if t == 31 { strips[2]!.faderDB = -2.04 }   // jitter below the rounding step: not a change
            data += rec.record(t: Double(t), strips: strips, buses: buses, channelLevels: [1: -20, 2: -18.26], busLevels: [1: -30])
        }
        XCTAssertEqual(rec.frames, 120)
        XCTAssertEqual(rec.changes, 1)
        let back = LearnRecording.parse(data)!
        XCTAssertEqual(back.header.title, "Test")
        XCTAssertEqual(back.frames.count, 120)
        XCTAssertEqual(back.frames[0].key, true)
        XCTAssertNil(back.frames[1].strips)
        XCTAssertEqual(back.frames[30].strips?.map(\.id), [2])
        XCTAssertEqual(back.frames[60].key, true)
        XCTAssertEqual(back.frames[0].levels, [-20, -18.5])
        var at45: [Int: ChannelStrip] = [:]
        back.replay { f, s, _ in if f.t == 45 { at45 = s } }
        XCTAssertEqual(at45[2]?.faderDB ?? 0, -2, accuracy: 0.01)
        XCTAssertEqual(at45[1]?.name, "Kick")
        // A line cut short at the end is skipped.
        var cut = data
        cut.append(contentsOf: Array("{\"t\":120,\"lev".utf8))
        XCTAssertEqual(LearnRecording.parse(cut)?.frames.count, 120)
    }

    func testFileNameKeepsTitleReadable() {
        let h = LearnHeader(title: "Мюзикл / Акт 1", startedAt: 0, console: "x32")
        let n = LearningRecorder.fileName(for: h)
        XCTAssertTrue(n.hasSuffix("_Мюзикл---Акт-1.ssmtlearn"), n)
        XCTAssertFalse(n.contains("/"))
    }

    // MARK: patterns

    /// One made-up event: a vocal ridden on the fader with a high-pass and a compressor, a kick left alone.
    private func event(seconds: Int, vocalFader: Double) -> LearnRecording {
        var rec = LearningRecorder(header: LearnHeader(title: "Show", console: "x32"))
        var vox = ChannelStrip(id: 1, name: "Vox Lead", gainDB: 34, highPassOn: true, highPassHz: 120, faderDB: vocalFader)
        vox.eq[2] = StripEQBand(type: .peaking, frequency: 3000, gainDB: 2.5, q: 1.4)
        vox.compressor = StripCompressor(enabled: true, thresholdDB: -20, ratio: 3)
        let kick = ChannelStrip(id: 2, name: "Kick In", gainDB: 25, faderDB: -6)
        var frames: [LearnFrame] = []
        for t in 0..<seconds {
            // The engineer rides the vocal every 10 s.
            var v = vox
            v.faderDB = vocalFader + (t / 10 % 2 == 0 ? 0 : 1.5)
            frames.append(rec.makeFrame(t: Double(t), strips: [1: v, 2: kick], buses: [:], channelLevels: [1: -18, 2: -12], busLevels: [:]))
        }
        return LearnRecording(header: rec.header, frames: frames)
    }

    func testLearnerFindsPerSourceHabits() {
        let recs = [event(seconds: 600, vocalFader: -6), event(seconds: 600, vocalFader: -4), event(seconds: 100, vocalFader: -5)]
        let p = PatternLearner.learn(recs)
        XCTAssertEqual(p.events, 2)   // the 100 s recording is a test, not an event
        XCTAssertEqual(p.progress, 0.1, accuracy: 1e-9)
        XCTAssertFalse(p.ready)
        let vox = p.sources.first { $0.kind.family == .vocals }
        XCTAssertNotNil(vox, "\(p.sources.map(\.kind))")
        guard let vox else { return }
        XCTAssertEqual(vox.channels, 3)
        XCTAssertEqual(vox.gainDB ?? 0, 34, accuracy: 0.01)
        XCTAssertEqual(vox.highPassShare, 1, accuracy: 1e-9)
        XCTAssertEqual(vox.highPassHz ?? 0, 120, accuracy: 0.5)
        XCTAssertEqual(vox.compressorShare, 1, accuracy: 1e-9)
        XCTAssertEqual(vox.ratio ?? 0, 3, accuracy: 0.01)
        XCTAssertEqual(vox.eq.first { $0.band == 3 }?.gainDB ?? 0, 2.5, accuracy: 0.01)
        XCTAssertEqual(vox.ridesPerMinute, 6, accuracy: 0.3)
        let kick = p.sources.first { $0.kind == .kick }
        XCTAssertEqual(kick?.ridesPerMinute ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(kick?.compressorShare ?? -1, 0, accuracy: 1e-9)
        let ru = p.summary(russian: true)
        XCTAssertTrue(ru.contains("2 из 20"), ru)
        XCTAssertTrue(ru.contains("Бочка"), ru)
        XCTAssertTrue(p.prompt(question: "Какой гейн на вокале?", russian: true).hasSuffix("Вопрос: Какой гейн на вокале?"))
    }

    func testLearnerWithNoRecordings() {
        let p = PatternLearner.learn([])
        XCTAssertEqual(p.events, 0)
        XCTAssertTrue(p.sources.isEmpty)
        XCTAssertTrue(p.summary(russian: false).contains("0 of 20"))
    }

    // MARK: every console parameter

    static func blob(floats: [Float]) -> OSCArgument {
        var d = Data()
        var n = UInt32(floats.count).littleEndian
        d.append(Data(bytes: &n, count: 4))
        for f in floats { var b = f.bitPattern.littleEndian; d.append(Data(bytes: &b, count: 4)) }
        return .blob(d)
    }

    static func blob(shorts: [Double]) -> OSCArgument {
        var d = Data()
        var n = UInt32(shorts.count).littleEndian
        d.append(Data(bytes: &n, count: 4))
        for v in shorts { var b = UInt16(bitPattern: Int16((v * 256).rounded())).littleEndian; d.append(Data(bytes: &b, count: 2)) }
        return .blob(d)
    }

    func testTreeCoversTheWholeConsoleAndOnlyReads() {
        let x = ConsoleTree.addresses(.x32)
        XCTAssertGreaterThan(x.count, 6000)
        XCTAssertEqual(Set(x).count, x.count, "no address twice")
        for a in ["/ch/01/mix/fader", "/ch/32/dyn/thr", "/ch/05/gate/range", "/ch/07/mix/03/level", "/bus/16/eq/6/g",
                  "/mtx/06/mix/fader", "/main/st/dyn/ratio", "/dca/8/fader", "/fx/1/par/64", "/headamp/127/phantom",
                  "/auxin/08/mix/fader", "/fxrtn/01/mix/01/level"] {
            XCTAssertTrue(x.contains(a), a)
        }
        let xa = ConsoleTree.addresses(.xAir)
        for a in ["/ch/16/dyn/thr", "/bus/6/eq/6/f", "/lr/mix/fader", "/rtn/aux/mix/fader", "/headamp/24/gain"] {
            XCTAssertTrue(xa.contains(a), a)
        }
        var c = ConsoleCapture(family: .x32)
        var asked: [OSCMessage] = []
        for _ in 0..<60 { asked += c.sweep() }
        XCTAssertEqual(c.passes, 1, "the first pass takes under a minute")
        XCTAssertEqual(ConsoleReadOnly.filter(asked).count, asked.count)
        XCTAssertEqual(c.sweep().count, c.refreshRate)
        for fam in [MixerFamily.x32, .xAir] {
            let reqs = ConsoleReadOnly.renewals(family: fam)
            XCTAssertEqual(ConsoleReadOnly.filter(reqs).count, reqs.count)
            XCTAssertTrue(reqs.contains(ConsoleMeters.request(.rta, family: fam)))
        }
    }

    func testCaptureKeepsParametersAndFoldsMetersPerSecond() {
        var c = ConsoleCapture(family: .x32)
        XCTAssertTrue(c.take(OSCMessage("/ch/01/mix/03/level", [.float(0.62519)])))
        XCTAssertTrue(c.take(OSCMessage("/ch/01/config/name", [.string("Kick")])))
        XCTAssertTrue(c.take(OSCMessage("/ch/01/gate/on", [.int(1)])))
        XCTAssertFalse(c.take(OSCMessage("/info", [.string("V2.07")])))
        XCTAssertFalse(c.take(OSCMessage("/ch/01/mix/fader")))
        XCTAssertEqual(c.params["/ch/01/mix/03/level"], .number(0.6252))
        XCTAssertEqual(c.params["/ch/01/config/name"], .text("Kick"))
        XCTAssertEqual(c.params["/ch/01/gate/on"], .number(1))
        // /meters/1: 32 levels, 32 gate, 32 compressor gain (1 = no reduction).
        var m1 = [Float](repeating: 0, count: 96)
        m1[0] = 0.5; m1[32] = 1; m1[64] = 0.5
        XCTAssertTrue(c.take(OSCMessage("/meters/1", [Self.blob(floats: m1)])))
        m1[0] = 0.25; m1[64] = 0.25
        c.take(OSCMessage("/meters/1", [Self.blob(floats: m1)]))
        var m2 = [Float](repeating: 0, count: 49)
        m2[0] = 1; m2[25] = 0.5
        c.take(OSCMessage("/meters/2", [Self.blob(floats: m2)]))
        c.take(OSCMessage("/meters/15", [Self.blob(shorts: [Double](repeating: -30, count: 100))]))
        let s = c.takeSecond()
        XCTAssertEqual(s.levels.first ?? 0, -6, accuracy: 0.5, "peak of the second")
        XCTAssertEqual(s.dyn.first ?? 0, -12, accuracy: 0.5, "most reduction of the second")
        XCTAssertEqual(s.gate.first ?? -1, 0, accuracy: 0.01)
        XCTAssertEqual(s.outs.count, 25)
        XCTAssertEqual(s.outs.first ?? -1, 0, accuracy: 0.01)
        XCTAssertEqual(s.outDyn.first ?? 0, -6, accuracy: 0.5)
        XCTAssertEqual(s.rta.count, ThirdOctave.centers.count)
        XCTAssertTrue(c.takeSecond().rta.isEmpty, "the window starts again")
        // X Air gain reduction bank.
        var a = ConsoleCapture(family: .xAir)
        a.take(OSCMessage("/meters/6", [Self.blob(shorts: [-3] + [Double](repeating: 0, count: 15) + [-8])]))
        let sa = a.takeSecond()
        XCTAssertEqual(sa.gate.first ?? 0, -3, accuracy: 0.01)
        XCTAssertEqual(sa.dyn.first ?? 0, -8, accuracy: 0.01)
    }

    func testRecorderWritesParametersAndMeters() {
        var rec = LearningRecorder(header: LearnHeader(title: "All", console: "x32"))
        rec.paramKeyInterval = 100
        var c = ConsoleCapture(family: .x32)
        let strips = [1: ChannelStrip(id: 1, name: "Kick", gainDB: 30, faderDB: -10)]
        c.absorb(strips: strips, buses: [1: BusStrip(id: 1, name: "Mon", faderDB: -3)])
        XCTAssertNotNil(c.params["/ch/01/mix/fader"])
        XCTAssertNotNil(c.params["/bus/01/mix/fader"])
        var data = rec.headerLine()
        for t in 0..<150 {
            if t == 20 { c.take(OSCMessage("/ch/01/mix/05/level", [.float(0.5)])) }       // heard for the first time
            if t == 40 { c.take(OSCMessage("/ch/01/mix/05/level", [.float(0.7)])) }       // an edit
            var m = LearnMeters()
            m.levels = [-12]
            m.dyn = [-4]
            data += rec.record(t: Double(t), strips: strips, buses: [:], channelLevels: [1: -30], busLevels: [:],
                               params: c.params, meters: m)
        }
        XCTAssertEqual(rec.changes, 1)
        let r = LearnRecording.parse(data)!
        XCTAssertEqual(r.header.format, 2)
        XCTAssertEqual(r.frames[0].pkey, true)
        XCTAssertNil(r.frames[1].p, "nothing changed")
        XCTAssertEqual(r.frames[20].p, ["/ch/01/mix/05/level": .number(0.5)])
        XCTAssertEqual(r.frames[40].p, ["/ch/01/mix/05/level": .number(0.7)])
        XCTAssertEqual(r.frames[100].pkey, true)
        XCTAssertEqual(r.frames[5].levels, [-12], "meter peaks replace the last level")
        XCTAssertEqual(r.frames[5].m?.dyn, [-4])
        var last: [String: ParamValue] = [:]
        r.replayParams { f, p in if f.t == 45 { last = p } }
        XCTAssertEqual(last["/ch/01/mix/05/level"], .number(0.7))
        XCTAssertEqual(last["/ch/01/config/name"], .text("Kick"))
        // A recording of the first format still reads.
        let old = Data(#"{"app":"","console":"x32","format":1,"id":"a","model":"","startedAt":0,"title":"Old"}"#.utf8)
            + Data("\n".utf8) + Data(#"{"busLevels":[],"levels":[-20],"t":0}"#.utf8)
        let o = LearnRecording.parse(old)
        XCTAssertEqual(o?.frames.count, 1)
        XCTAssertNil(o?.frames.first?.p)
    }
}
