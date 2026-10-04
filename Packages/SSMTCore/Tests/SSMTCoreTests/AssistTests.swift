import XCTest
@testable import SSMTCore

final class AssistTests: XCTestCase {
    // MARK: console protocol

    func testX32FaderLawRoundTrip() {
        for db in [-80.0, -50, -30, -20, -10, -5, 0, 5, 10] {
            XCTAssertEqual(X32Codec.faderDB(X32Codec.faderPosition(db)), db, accuracy: 0.01, "\(db)")
        }
        XCTAssertEqual(X32Codec.faderDB(0.75), 0, accuracy: 1e-9)   // unity on X32
        XCTAssertEqual(X32Codec.faderDB(0), -144)
    }

    func testX32MessagesRoundTripThroughParser() {
        var s = ChannelStrip(id: 7, name: "Vox Lead", gainDB: 32.5, highPassOn: true, highPassHz: 110, faderDB: -7.5)
        s.eq[1] = StripEQBand(type: .peaking, frequency: 315, gainDB: -4.5, q: 2)
        s.eq[3] = StripEQBand(type: .highShelf, frequency: 8000, gainDB: 2)
        s.compressor = StripCompressor(enabled: true, thresholdDB: -22, ratio: 3, attackMS: 6, releaseMS: 150, kneeDB: 2, makeupDB: 3)
        let msgs = X32Codec.messages(from: nil, to: s, family: .x32)
        XCTAssertTrue(msgs.contains { $0.address == "/ch/07/eq/2/f" })
        XCTAssertTrue(msgs.contains { $0.address == "/headamp/006/gain" })
        var strips = [7: ChannelStrip(id: 7)]
        for m in msgs {
            // Through the wire format and back.
            let decoded = OSCMessage.decode(m.encoded())!.first!
            X32Codec.apply(decoded, to: &strips, family: .x32)
        }
        let r = strips[7]!
        XCTAssertEqual(r.gainDB, 32.5, accuracy: 0.01)
        XCTAssertEqual(r.highPassHz, 110, accuracy: 0.5)
        XCTAssertEqual(r.eq[1].frequency, 315, accuracy: 0.5)
        XCTAssertEqual(r.eq[1].gainDB, -4.5, accuracy: 0.01)
        XCTAssertEqual(r.eq[1].q, 2, accuracy: 0.01)
        XCTAssertEqual(r.eq[3].type, .highShelf)
        XCTAssertEqual(r.compressor.thresholdDB, -22, accuracy: 0.01)
        XCTAssertEqual(r.compressor.ratio, 3)
        XCTAssertEqual(r.compressor.releaseMS, 150, accuracy: 0.5)
        XCTAssertEqual(r.faderDB, -7.5, accuracy: 0.01)
        // Only what changed is sent next time.
        var s2 = s
        s2.eq[1].gainDB = -3
        XCTAssertEqual(X32Codec.messages(from: s, to: s2, family: .x32).map(\.address), ["/ch/07/eq/2/g"])
    }

    func testOSCBlobRoundTrip() {
        let m = OSCMessage("/meters/1", [.blob(Data([1, 2, 3, 4, 5]))])
        XCTAssertEqual(OSCMessage.decode(m.encoded()), [m])
    }

    // MARK: classification

    func testNamesAreRecognised() {
        // "name=kind" pairs (a plain string list keeps the type checker fast).
        let cases = [
            "Kick In=kick", "KICK OUT=kick", "Бочка=kick", "SN Top=snare", "Малый=snare", "OH L=overhead", "Tom 2=tom", "HH=hiHat",
            "Bass DI=bassGuitar", "Бас-гитара=bassGuitar", "Vox 1=maleVocal", "Вокал=maleVocal", "BV 2=backingVocal",
            "Бэк=backingVocal", "Choir L=choir", "Хор 3=choir", "Violin 1=violin", "Vn2=violin", "Скрипка 2=violin",
            "Альт=viola", "Viola=viola", "Cello=cello", "Виолончель=cello", "Контрабас=doubleBass", "Flute=flute",
            "Кларнет=clarinet", "Alto Sax=saxophone", "Tpt 1=trumpet", "Тромбон=trombone", "Horn=frenchHorn",
            "Timpani=percussion", "Piano L=piano", "Keys=keys", "Ac Gtr=acousticGuitar", "Гитара=electricGuitar",
            "MC=speech", "Ведущий=speech", "Playback L=playback",
        ].map { pair -> (String, SourceKind) in
            let p = pair.split(separator: "=").map(String.init)
            return (p[0], SourceKind(rawValue: p[1])!)
        }
        for (name, kind) in cases { XCTAssertEqual(SourceClassifier.kind(forName: name), kind, name) }
        XCTAssertNil(SourceClassifier.kind(forName: "Ch 12"))
        // In a choir, "Bass" and "Alto" are sections.
        XCTAssertEqual(SourceClassifier.kind(forName: "Bass", choirContext: true), .choir)
        XCTAssertEqual(SourceClassifier.kind(forName: "Alto 2", choirContext: true), .choir)
    }

    func testOrchestraAndChoirSelection() {
        let names = ["Kick In", "Vox", "Violin 1", "Violin 2", "Viola", "Cello", "Flute", "Choir S", "Choir A", "Choir T", "Bass",
                     "Snare Top", "OH L", "Bass DI", "Gtr", "Keys", "MC", "Playback L"]
        let strips = names.enumerated().map { ChannelStrip(id: $0.offset + 1, name: $0.element) }
        // Every musical instrument is part of the orchestra: drums and band too; voices, choir, speech, playback not.
        XCTAssertEqual(AssistGroupSelection.orchestra.channels(in: strips), [1, 3, 4, 5, 6, 7, 12, 13, 14, 15, 16])
        XCTAssertEqual(AssistGroupSelection.choir.channels(in: strips), [8, 9, 10, 11])
        XCTAssertEqual(AssistGroupSelection.range(10, 8).channels(in: strips), [8, 9, 10])
    }

    // MARK: analysis

    func testFeaturesOfAPitchedTone() {
        let fs = 48000.0
        let x: [Float] = (0..<96000).map { (i: Int) -> Float in
            let w: Double = 2 * Double.pi * 220 * Double(i) / fs
            let v: Double = sin(w) + 0.5 * sin(2 * w) + 0.25 * sin(3 * w)
            return Float(0.3 * v)
        }
        let f = FeatureExtractor(sampleRate: fs).analyze(x)
        XCTAssertEqual(f.pitchHz, 220, accuracy: 3)
        XCTAssertGreaterThan(f.harmonicity, 0.8)
        XCTAssertLessThan(f.crestDB, 6)
        XCTAssertEqual(f.bandsDB.indices.max { f.bandsDB[$0] < f.bandsDB[$1] }, ThirdOctave.index(of: 220))
    }

    func testSoundClassifierSeparatesKickVoiceAndViolin() {
        let console = SimulatedConsole.demo()
        let ex = FeatureExtractor()
        let r = console.render(seconds: 2, channels: [1, 7, 9])
        XCTAssertEqual(SourceClassifier.kind(forSound: ex.analyze(r.taps[1]!)).kind, .kick)
        XCTAssertEqual(SourceClassifier.kind(forSound: ex.analyze(r.taps[7]!)).kind.family, .vocals)
        XCTAssertEqual(SourceClassifier.kind(forSound: ex.analyze(r.taps[9]!)).kind, .violin)
    }

    // MARK: tuning

    func testIdealEQCutsAMuddyResonance() {
        let p = ToneProfile.profile(for: .maleVocal, character: .musical)
        // A flat-on-target vocal with +6 dB at 315 Hz.
        let bands = ThirdOctave.centers.map { p.targetDB(at: $0) + StripEQBand(frequency: 315, gainDB: 6, q: 1.2).responseDB(at: $0) - 20 }
        let eq = ChannelTuning.idealEQ(bands: bands, profile: p, character: .musical, highPassHz: 90, current: ChannelStrip.flatEQ, reserved: [])
        let cut = eq.bands.map { $0.responseDB(at: 315) }.reduce(0, +)
        XCTAssertLessThan(cut, -2.5)
        XCTAssertLessThan(eq.residualDB, 1.5)
    }

    func testSingleChannelConvergesOnSimulatedVocal() {
        let console = SimulatedConsole.demo()
        let session = AssistSession(strips: Array(console.strips.values), character: .musical)
        session.startChannel(7)   // "Vox Lead": muddy and harsh mic, gain far too low
        var steps = 0
        while session.isRunning && steps < 30 {
            let r = console.render(seconds: 2, channels: [7])
            for s in session.tick(taps: r.taps, mic: nil) { console.setStrip(s) }
            steps += 1
        }
        XCTAssertFalse(session.isRunning, "did not finish in \(steps) steps")
        let s = console.strips[7]!
        XCTAssertTrue(session.log.contains { if case .done = $0.note { return true }; return false })
        XCTAssertTrue(session.log.contains { if case .gain = $0.note { return true }; return false })
        XCTAssertTrue(s.highPassOn)
        XCTAssertTrue(s.compressor.enabled)
        // Loud passages land near the target level.
        let f = FeatureExtractor().analyze(console.render(seconds: 2, channels: [7]).taps[7]!)
        XCTAssertEqual(f.level95DB, -14, accuracy: 3)
        // The mud the mic added at 315 Hz is reduced by the EQ.
        XCTAssertLessThan(s.filterResponseDB(at: 315), -2)
        // Undo puts the original strip back.
        let back = session.undo()
        XCTAssertEqual(back.first { $0.id == 7 }?.gainDB, 20)
    }

    func testFeedbackDetectorFindsAGrowingTone() {
        let fs = 48000.0
        let d = FeedbackDetector(sampleRate: fs)
        var found: [FeedbackDetector.Event] = []
        var phase = 0.0
        for block in 0..<12 {
            let a = 0.001 * pow(1.6, Double(block))
            let x: [Float] = (0..<4800).map { _ in
                phase += 2 * .pi * 2500 / fs
                return Float(a * sin(phase) + 0.001 * Double.random(in: -1...1))
            }
            found += d.process(x)
        }
        XCTAssertTrue(found.contains { abs($0.frequency - 2500) < 10 }, "\(found)")
    }

    func testChoirGroupTunesBalancesAndRingsOut() {
        let console = SimulatedConsole.demo()
        // Only the choir is up (keeps the test quick; the rest of the stage is silent).
        for (ch, s) in console.strips where !(13...16).contains(ch) { var m = s; m.muted = true; console.setStrip(m) }
        let session = AssistSession(strips: Array(console.strips.values), character: .musical)
        let members = session.startGroup(.choir)
        XCTAssertEqual(members, [13, 14, 15, 16])
        var steps = 0
        while session.isRunning && steps < 80 {
            let r = console.render(seconds: 2, channels: members)
            for s in session.tick(taps: r.taps, mic: r.mic) { console.setStrip(s) }
            steps += 1
        }
        XCTAssertEqual(session.group?.phase, .done, "stuck in \(String(describing: session.group?.phase)) after \(steps) steps")
        // Every member was tuned and balanced; the ring-out brought the group up from the safe level.
        for ch in members {
            XCTAssertTrue(console.strips[ch]!.compressor.enabled || console.strips[ch]!.highPassOn, "\(ch)")
            XCTAssertTrue(session.log.contains { $0.channel == ch && { if case .fader = $0 { return true }; return false }($0.note) }, "\(ch)")
        }
        XCTAssertGreaterThan(session.group!.groupLevelDB, session.group!.safeFaderDB)
        // The choir mics are coupled to the room: the ring-out met feedback and notched it.
        XCTAssertTrue(session.log.contains { if case .feedback = $0.note { return true }; return false })
        XCTAssertFalse(session.group!.notches.isEmpty)
    }
}

final class ConsoleDiscoveryTests: XCTestCase {
    func testParsesX32AndXAirAnswers() {
        let x32 = OSCMessage("/xinfo", [.string("192.168.1.64"), .string("X32-02-4A-53"), .string("X32"), .string("4.06")])
        let d = ConsoleDiscovery.parse(x32, sender: "192.168.1.64", family: .x32)
        XCTAssertEqual(d, DiscoveredConsole(family: .x32, ip: "192.168.1.64", name: "X32-02-4A-53", model: "X32", firmware: "4.06"))
        let xr = OSCMessage("/xinfo", [.string(""), .string("XR18-5E-91-6A"), .string("XR18"), .string("1.17")])
        let e = ConsoleDiscovery.parse(xr, sender: "10.0.0.7", family: .x32)
        XCTAssertEqual(e?.family, .xAir, "the model decides the family")
        XCTAssertEqual(e?.ip, "10.0.0.7", "empty IP: the sender's address")
        XCTAssertNil(ConsoleDiscovery.parse(OSCMessage("/info", [.string("a")]), sender: "1.1.1.1", family: .x32))
        XCTAssertEqual(ConsoleDiscovery.request.encoded().count, 12, "/xinfo + type tag")
    }
}
