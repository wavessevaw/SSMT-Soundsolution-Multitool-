import XCTest
@testable import SSMTCore

final class ShowGuardTests: XCTestCase {
    // MARK: console meters over the network

    func testX32MeterBlobsDecode() {
        var d = Data()
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        le32(96)
        for i in 0..<96 { le32(Float(i == 0 ? 1.0 : (i == 1 ? 0.1 : 0)).bitPattern) }
        let m = OSCMessage("/meters/1", [.blob(d)])
        let (bank, values) = ConsoleMeters.decode(OSCMessage.decode(m.encoded())!.first!, family: .x32)!
        XCTAssertEqual(bank, .channels)
        XCTAssertEqual(values.count, 32)
        XCTAssertEqual(values[0], 0, accuracy: 1e-6)
        XCTAssertEqual(values[1], -20, accuracy: 1e-4)

        var r = Data()
        withUnsafeBytes(of: UInt32(50).littleEndian) { r.append(contentsOf: $0) }
        for k in 0..<100 { withUnsafeBytes(of: Int16(k == 50 ? -10 * 256 : -60 * 256).littleEndian) { r.append(contentsOf: $0) } }
        let (b2, rta) = ConsoleMeters.decode(OSCMessage("/meters/15", [.blob(r)]), family: .x32)!
        XCTAssertEqual(b2, .rta)
        XCTAssertEqual(rta.count, 100)
        XCTAssertEqual(rta[50], -10)
        // Folded into one-third octaves, the peak lands near 20·1000^(50/99) ≈ 657 Hz.
        let third = ConsoleMeters.thirdOctaves(fromRTA: rta)
        XCTAssertEqual(third.indices.max { third[$0] < third[$1] }, ThirdOctave.index(of: 657))
    }

    func testMeterAccumulatorBuildsFeatures() {
        var acc = ConsoleMeterAccumulator()
        acc.rtaChannel = 3
        for k in 0..<40 {
            var levels = [Double](repeating: -90, count: 32)
            levels[2] = k % 10 == 0 ? -10 : -20   // channel 3: steady with accents
            acc.add(channelLevels: levels)
            acc.add(rtaBands: ConsoleMeters.rtaFrequencies.map { $0 < 300 ? -20 : -40 })
        }
        let f = acc.takeWindow()
        XCTAssertTrue(f[3]!.hasSignal)
        XCTAssertFalse(f[1]!.hasSignal)
        XCTAssertEqual(f[3]!.level50DB, -20, accuracy: 0.01)
        XCTAssertEqual(f[3]!.level95DB, -10, accuracy: 0.01)
        XCTAssertGreaterThan(f[3]!.bandsDB[ThirdOctave.index(of: 100)], f[3]!.bandsDB[ThirdOctave.index(of: 2000)] + 10)
    }

    func testBusCodecRoundTrip() {
        let b = BusStrip(id: 3, name: "Mon 3", faderDB: -4.5)
        var buses = [3: BusStrip(id: 3)]
        for m in X32Codec.busMessages(from: nil, to: b, family: .x32) { X32Codec.apply(m, toBuses: &buses) }
        X32Codec.apply(OSCMessage("/bus/03/config/name", [.string("Mon 3")]), toBuses: &buses)
        XCTAssertEqual(buses[3]!.faderDB, -4.5, accuracy: 0.01)
        XCTAssertTrue(buses[3]!.looksLikeMonitor)
        XCTAssertEqual(X32Codec.busPath(3, family: .xAir), "/bus/3")
    }

    // MARK: show guard

    func makeGuard() -> ShowGuard {
        var strips = [ChannelStrip(id: 1, name: "Vox Lead", faderDB: 0)]
        for i in 2...6 { strips.append(ChannelStrip(id: i, name: "Choir \(i - 1)", faderDB: -3)) }
        strips.append(ChannelStrip(id: 7, name: "Kick", faderDB: -5))
        let buses = [BusStrip(id: 1, name: "Mon Vox", faderDB: 0), BusStrip(id: 2, name: "Mon Choir", faderDB: -2), BusStrip(id: 9, name: "FX Rev")]
        return ShowGuard(strips: strips, buses: buses, character: .musical)
    }

    func feature(rms: Double, presence: Double? = nil) -> SignalFeatures {
        var f = SignalFeatures(rmsDB: rms, level50DB: rms, level95DB: rms + 6, activity: 1)
        if let p = presence {
            f.bandsDB = ThirdOctave.centers.map { (1600...5000).contains($0) ? p : rms - 10 }
        }
        return f
    }

    func testMonitorLoopIsDippedThenRestored() {
        let g = makeGuard()
        XCTAssertEqual(g.monitorBuses, [1, 2])
        let inputs = [1: feature(rms: -20)]
        var t = 0.0
        for _ in 0..<4 { _ = g.step(time: t, channels: inputs, busLevels: [2: -25]); t += 1 }
        // The bus jumps 15 dB and holds while the inputs stay the same: a loop.
        _ = g.step(time: t, channels: inputs, busLevels: [2: -10]); t += 1
        let r = g.step(time: t, channels: inputs, busLevels: [2: -10]); t += 1
        XCTAssertTrue(r.actions.contains(.monitorDip(bus: 2, byDB: 3)))
        XCTAssertEqual(g.bus(2)!.faderDB, -5, accuracy: 0.01)
        XCTAssertEqual(r.buses.map(\.id), [2])
        // Quiet again: held for 8 s, then brought back 1 dB per step to where the engineer had it.
        var restored = false
        for _ in 0..<20 {
            let s = g.step(time: t, channels: inputs, busLevels: [2: -28]); t += 1
            if s.actions.contains(.monitorRestored(bus: 2)) { restored = true; break }
        }
        XCTAssertTrue(restored)
        XCTAssertEqual(g.bus(2)!.faderDB, -2, accuracy: 0.01)
        XCTAssertEqual(g.activeCorrections, 0)
    }

    /// Four steps a second (as in the app): a ringing monitor is pulled down within a second of starting to ring,
    /// and pulled again half a second later if it keeps ringing.
    func testRingingMonitorIsCaughtWithinASecond() {
        let g = makeGuard()
        let inputs = [1: feature(rms: -20)]
        var t = 0.0
        while t < 2 { _ = g.step(time: t, channels: inputs, busLevels: [2: -25]); t += 0.25 }
        let onset = t
        var firstDip: Double?
        var dips: [Double] = []
        while t < onset + 2.5 {
            let r = g.step(time: t, channels: inputs, busLevels: [2: -10])   // keeps ringing
            for a in r.actions { if case .monitorDip(bus: 2, _) = a { dips.append(t); if firstDip == nil { firstDip = t } } }
            t += 0.25
        }
        XCTAssertNotNil(firstDip)
        XCTAssertLessThanOrEqual((firstDip ?? 99) - onset, 0.75 + 1e-9, "pulled down within ¾ s")
        XCTAssertGreaterThanOrEqual(dips.count, 2, "pulled again while it keeps ringing")
        if dips.count >= 2 { XCTAssertLessThanOrEqual(dips[1] - dips[0], 0.5 + 1e-9) }
        XCTAssertEqual(g.bus(2)!.faderDB, -2 - 9, accuracy: 0.01, "no deeper than 9 dB")
    }

    func testEngineerTouchWins() {
        let g = makeGuard()
        let inputs = [1: feature(rms: -20)]
        var t = 0.0
        for l in [-25.0, -25, -25, -25, -10, -10] { _ = g.step(time: t, channels: inputs, busLevels: [1: l]); t += 1 }
        XCTAssertEqual(g.bus(1)!.faderDB, -3, accuracy: 0.01)
        // The engineer grabs the monitor fader: the guard lets go and stays away.
        g.consoleChanged(bus: BusStrip(id: 1, name: "Mon Vox", faderDB: -6), time: t)
        XCTAssertEqual(g.bus(1)!.faderDB, -6, accuracy: 0.01)
        XCTAssertTrue(g.log.contains { $0.action == .yielded(channel: nil, bus: 1) })
        // Right after the touch the guard does not fight the engineer's hand…
        for l in [-10.0, -10] { let r = g.step(time: t, channels: inputs, busLevels: [1: l]); t += 1; XCTAssertTrue(r.buses.isEmpty) }
        // …but a monitor still ringing a few seconds later is a safety matter: it is pulled down again.
        var acted = false
        for l in [-25.0, -25, -25, -25, -10, -10] {
            let r = g.step(time: t, channels: inputs, busLevels: [1: l]); t += 1
            if !r.buses.isEmpty { acted = true }
        }
        XCTAssertTrue(acted)
        XCTAssertEqual(g.bus(1)!.faderDB, -9, accuracy: 0.01)
    }

    func testFaderRideKeepsTheGuardsEQ() {
        let g = makeGuard()
        var scene: [Int: SignalFeatures] = [1: feature(rms: -20, presence: -26)]
        for i in 2...6 { scene[i] = feature(rms: -20, presence: -24) }
        for t in 0..<3 { _ = g.step(time: Double(t), channels: scene, busLevels: [:]) }
        XCTAssertLessThan(g.strip(3)!.eq[2].gainDB, 0)
        // The engineer rides the choir fader: the unmasking stays.
        var ride = g.strip(3)!
        ride.faderDB = -6
        g.consoleChanged(ride, time: 3)
        XCTAssertLessThan(g.strip(3)!.eq[2].gainDB, 0)
        XCTAssertEqual(g.strip(3)!.faderDB, -6)
        XCTAssertFalse(g.log.contains { $0.action == .yielded(channel: 3, bus: nil) })
    }

    func testMassSceneUnmasksTheLeadAndReleases() {
        let g = makeGuard()
        var scene: [Int: SignalFeatures] = [1: feature(rms: -20, presence: -26)]
        for i in 2...6 { scene[i] = feature(rms: -20, presence: -24) }
        var t = 0.0
        for _ in 0..<5 { _ = g.step(time: t, channels: scene, busLevels: [:]); t += 1 }
        for i in 2...6 {
            let s = g.strip(i)!
            XCTAssertEqual(s.eq[2].gainDB, -3, accuracy: 0.01, "choir \(i)")   // band nearest 3 kHz, never more than 3 dB
            XCTAssertEqual(s.faderDB, -3)                                        // faders are the engineer's
        }
        XCTAssertEqual(g.strip(1)!.eq[2].gainDB, 0)
        // The scene ends (only the lead sings): released step by step.
        let solo = [1: feature(rms: -20, presence: -26)]
        for _ in 0..<12 { _ = g.step(time: t, channels: solo, busLevels: [:]); t += 1 }
        XCTAssertEqual(g.activeCorrections, 0)
        for i in 2...6 { XCTAssertEqual(g.strip(i)!.eq[2].gainDB, 0) }
    }

    func testHallFeedbackNotchesTheLoudestChannelAtThatFrequency() {
        let g = makeGuard()
        var ch: [Int: SignalFeatures] = [:]
        for i in 1...7 { ch[i] = feature(rms: -30, presence: -40) }
        ch[1]!.bandsDB[ThirdOctave.index(of: 2500)] = -10
        let e = FeedbackDetector.Event(frequency: 2510, prominenceDB: 25, growthDB: 6, levelDB: -20)
        let r = g.step(time: 0, channels: ch, busLevels: [:], hallFeedback: [e])
        XCTAssertEqual(r.actions, [.notch(channel: 1, frequency: 2510, depthDB: -4)])
        let s = g.strip(1)!
        XCTAssertTrue(s.eq.contains { $0.q == 8 && abs($0.frequency - 2510) < 1 && $0.gainDB == -4 })
        // The engineer reworks that channel's EQ: the guard's notch is dropped.
        var mine = s
        mine.eq[0].gainDB = 3
        mine.eq = ChannelStrip.flatEQ
        mine.eq[0].gainDB = 3
        g.consoleChanged(mine, time: 1)
        XCTAssertEqual(g.strip(1)!, mine)
        XCTAssertTrue(g.log.contains { $0.action == .yielded(channel: 1, bus: nil) })
    }

    func testClassicalCharacterLeavesMassScenesAlone() {
        let g = makeGuard()
        g.character = .classical
        var scene: [Int: SignalFeatures] = [1: feature(rms: -20, presence: -26)]
        for i in 2...6 { scene[i] = feature(rms: -20, presence: -24) }
        for t in 0..<5 { XCTAssertTrue(g.step(time: Double(t), channels: scene, busLevels: [:]).strips.isEmpty) }
    }

    func testSimulatedMonitorLoopEndsHeldJustBelowWhereItRang() {
        let sim = SimulatedConsole.demo()
        let g = ShowGuard(strips: Array(sim.strips.values), buses: Array(sim.buses.values), character: .musical)
        XCTAssertEqual(g.monitorBuses, [1, 2, 3, 4])
        let rms: [Int: Double] = [7: -20, 13: -24, 14: -24]
        let feats = rms.mapValues { SignalFeatures(rmsDB: $0, level50DB: $0, level95DB: $0 + 6, activity: 1) }
        var t = 0.0
        func tick() {
            let r = g.step(time: t, channels: feats, busLevels: sim.busLevels(channelRMS: rms))
            for b in r.buses { sim.setBus(b) }
            t += 1
        }
        for _ in 0..<4 { tick() }
        // The engineer pushes the choir wedges to +1 dB: Mon 2 starts ringing.
        var b = sim.buses[2]!
        b.faderDB = 1
        sim.setBus(b)
        g.consoleChanged(bus: b, time: t - 31)   // a while ago: the guard may act
        for _ in 0..<60 { tick() }
        XCTAssertTrue(g.log.contains { if case .monitorDip(bus: 2, _) = $0.action { return true }; return false })
        // It was brought back up, rang again on the way, and now holds just under the ringing point.
        XCTAssertLessThan(sim.buses[2]!.faderDB, 0.01)
        XCTAssertGreaterThanOrEqual(sim.buses[2]!.faderDB, -3)
        XCTAssertTrue(g.log.contains { if case .monitorHeld(bus: 2, _) = $0.action { return true }; return false })
        XCTAssertEqual(sim.buses[1]!.faderDB, -3)   // other monitors untouched
    }
}

final class ShowGuardCorrectionListTests: XCTestCase {
    func testActiveCorrectionsAreListedAndCanBeCancelled() {
        let strips = [ChannelStrip(id: 1, name: "Vox Lead", faderDB: 0)] + (2...6).map { ChannelStrip(id: $0, name: "Choir \($0)", faderDB: -3) }
        let g = ShowGuard(strips: strips, buses: [BusStrip(id: 2, name: "Mon 2", faderDB: -2)], character: .musical)
        func f(_ rms: Double, _ p: Double) -> SignalFeatures {
            var x = SignalFeatures(rmsDB: rms, level50DB: rms, level95DB: rms + 6, activity: 1)
            x.bandsDB = ThirdOctave.centers.map { (1600...5000).contains($0) ? p : rms - 10 }
            return x
        }
        var scene: [Int: SignalFeatures] = [1: f(-20, -26)]
        for i in 2...6 { scene[i] = f(-20, -24) }
        var t = 0.0
        for l in [-25.0, -25, -25, -25, -10, -10] { _ = g.step(time: t, channels: scene, busLevels: [2: l]); t += 1 }
        let list = g.corrections(at: t)
        XCTAssertEqual(list.first?.kind, .monitorDip)
        XCTAssertEqual(list.first?.target, 2)
        XCTAssertEqual(list.filter { $0.kind == .unmask }.count, 5)
        // Cancel the dip: the bus goes back to where the engineer had it and the guard keeps off it.
        let r = g.cancel("monitorDip-2", time: t)
        XCTAssertEqual(r.buses.first?.faderDB ?? 0, -2, accuracy: 0.01)
        XCTAssertFalse(g.corrections(at: t).contains { $0.kind == .monitorDip })
        // Cancel one unmask: that channel's EQ goes back.
        let c = g.cancel("unmask-3", time: t)
        XCTAssertEqual(c.strips.first?.eq[2].gainDB ?? -1, 0, accuracy: 0.01)
        XCTAssertEqual(g.corrections(at: t).filter { $0.kind == .unmask }.count, 4)
    }
}
