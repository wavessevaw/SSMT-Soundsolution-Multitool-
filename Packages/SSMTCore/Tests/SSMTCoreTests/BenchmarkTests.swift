import XCTest
@testable import SSMTCore

/// Timings of the hot paths, run only with SSMT_BENCH=1 (release build) — they print, they do not assert.
final class BenchmarkTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SSMT_BENCH"] == "1", "benchmarks: set SSMT_BENCH=1")
    }

    func time(_ name: String, repeat n: Int = 1, _ body: () -> Void) {
        let t0 = Date()
        for _ in 0..<n { body() }
        let dt = Date().timeIntervalSince(t0) / Double(n)
        print(String(format: "BENCH %-40@ %10.3f ms", name as NSString, dt * 1000))
    }

    func testShowGuardStep() {
        var strips: [ChannelStrip] = []
        for i in 1...32 { strips.append(ChannelStrip(id: i, name: i <= 8 ? "Choir \(i)" : "Ch \(i)", faderDB: -5)) }
        let buses = (1...16).map { BusStrip(id: $0, name: "Mon \($0)", faderDB: 0) }
        let g = ShowGuard(strips: strips, buses: buses, character: .musical)
        var feats: [Int: SignalFeatures] = [:]
        for i in 1...32 {
            var f = SignalFeatures(rmsDB: -20, level50DB: -20, level95DB: -14, activity: 1)
            f.bandsDB = ThirdOctave.centers.map { _ in -30 + Double.random(in: -3...3) }
            feats[i] = f
        }
        var t = 0.0
        time("ShowGuard.step (32 ch, 16 buses)", repeat: 2000) {
            _ = g.step(time: t, channels: feats, busLevels: [1: -20, 2: -18])
            t += 0.25
        }
    }

    func testMixer64Voices() {
        let m = ShowMixer(sampleRate: 48000, maxOutputs: 16, maxVoices: 128)
        let clip = AudioClip(sampleRate: 48000, channels: [[Float](repeating: 0.01, count: 48000 * 10), [Float](repeating: 0.01, count: 48000 * 10)])
        for i in 0..<64 {
            var xp = [[Double]](repeating: [Double](repeating: showSilenceDB, count: 16), count: 2)
            xp[0][i % 16] = 0; xp[1][(i + 1) % 16] = 0
            let setup = VoiceSetup(regionStart: 1000, regionLength: 48000 * 9, plays: 0, rate: i % 2 == 0 ? 1 : 0.97, levelDB: -6,
                                   outputLevelsDB: [Double](repeating: 0, count: 16), crosspointsDB: xp, fadeInFrames: 4800, fadeOutFrames: 0)
            m.send(.start(UUID(), clip: clip, setup: setup, at: 0))
        }
        let bufs = (0..<16).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: 512) }
        defer { bufs.forEach { $0.deallocate() } }
        time("ShowMixer.render 512 frames, 64 voices", repeat: 2000) {
            bufs.withUnsafeBufferPointer { m.render($0.baseAddress!, channelCount: 16, frames: 512) }
        }
    }

    func testProgressEvaluate() {
        var p = PlayerProgress()
        p.record("qtrl.go", count: 10)
        let now = Date()
        time("PlayerProgress.recordClick+evaluate", repeat: 20_000) {
            p.recordClick(at: now)
            _ = p.evaluate(at: now)
        }
    }

    func testHandbookSearch() {
        time("Handbook.search (2 words)", repeat: 500) { _ = Handbook.search("xlr пин", russian: true) }
        time("AudioCalculator.search", repeat: 2000) { _ = AudioCalculator.search("задержка", russian: true) }
        time("All calculators, default values", repeat: 500) { for c in AudioCalculator.all { _ = c.results([:]) } }
    }

    func testShowEngineDocumentEdit() {
        var doc = ShowDocument(name: "big")
        let l = doc.lists[0].id
        var cues: [Cue] = []
        for i in 0..<800 {
            var c = Cue(kind: .audio, number: "\(i)", name: "Cue \(i)")
            if i % 20 == 0 { c = Cue(kind: .group, number: "\(i)", name: "G \(i)"); c.children = (0..<10).map { Cue(kind: .audio, name: "c\($0)") } }
            cues.append(c)
        }
        _ = doc.insert(cues, after: nil, list: l)
        let engine = ShowEngine(document: doc, sampleRate: 48000, lookahead: 256, send: { _ in }, clipProvider: { _ in nil })
        var d2 = doc
        time("ShowEngine.document = (1000 cues)", repeat: 200) {
            d2.lists[0].cues[0].name += "x"
            engine.document = d2
        }
        time("ShowDocument.allCues (1000 cues)", repeat: 500) { _ = doc.allCues.count }
        time("ShowDocument == (1000 cues)", repeat: 500) { _ = doc == d2 }
    }

    func testConsoleMeters() {
        var acc = ConsoleMeterAccumulator()
        acc.rtaChannel = 3
        let levels = [Double](repeating: -20, count: 32)
        let rta = (0..<100).map { _ in Double.random(in: -60 ... -20) }
        time("ConsoleMeterAccumulator 40 frames + window", repeat: 500) {
            for _ in 0..<40 { acc.add(channelLevels: levels); acc.add(rtaBands: rta) }
            _ = acc.takeWindow()
        }
    }
}
