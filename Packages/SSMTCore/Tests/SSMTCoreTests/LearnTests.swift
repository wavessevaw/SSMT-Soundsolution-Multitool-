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
}
