import Foundation

/// A made-up show played on the console: who plays in each scene, and a virtual engineer who rides the faders
/// the way a person would — bringing channels up, riding the lead, pushing a monitor, pulling unused channels.
/// The show guard runs alongside, exactly as in a real show.
///
/// Scenes (each `sceneSeconds` long, then the show starts over):
///  1. intro — band only, the engineer brings the band up;
///  2. verse — the lead singer joins; the engineer rides the lead (±1.5 dB);
///  3. chorus — everyone: backing vocals, choir and strings over the lead (a mass scene);
///  4. monitor push — the engineer pushes the choir wedges (Mon 2) into a loop;
///  5. ballad — the lead alone with keys, leaning into the mic (proximity boom);
///  6. hot vocal — the engineer pushes the lead too far: feedback in the hall;
///  7. outro — the engineer fades everything out.
public final class ShowRehearsal {
    public enum Scene: String, CaseIterable, Sendable { case intro, verse, chorus, monitorPush, ballad, hotVocal, outro }

    /// What happened in a step, for the log next to the guard's own actions.
    public enum Event: Equatable, Sendable {
        case scene(Scene)
        case engineerFader(channel: Int, toDB: Double)
        case engineerBus(bus: Int, toDB: Double)
    }

    public let console: SimulatedConsole
    public let guardian: ShowGuard
    public var sceneSeconds: Double
    public private(set) var time = 0.0
    public private(set) var scene: Scene = .intro
    public private(set) var events: [(time: Double, event: Event)] = []
    /// Strips and buses as they are on the console.
    public private(set) var strips: [Int: ChannelStrip]
    public private(set) var buses: [Int: BusStrip]

    let lead: Int?
    let rhythm: [Int], backing: [Int], ensemble: [Int], keys: [Int]
    var faderTarget: [Int: Double] = [:]
    var lastGuardTime = -1.0
    var hotTarget: Double?
    /// Monitor bus and channel levels of the last guard step (for the meters on screen).
    public private(set) var lastBusLevels: [Int: Double] = [:]
    public private(set) var lastChannelLevels: [Int: Double] = [:]
    let extractor: FeatureExtractor
    let detector: FeedbackDetector
    let busOriginal: Double
    /// Fader moves are sent once they differ by at least this (the console's own step near unity).
    let faderStep = 0.25

    public init(console: SimulatedConsole, character: MixCharacter = .musical, sceneSeconds: Double = 20) {
        self.console = console
        self.sceneSeconds = sceneSeconds
        strips = console.strips
        buses = console.buses
        busOriginal = console.buses[2]?.faderDB ?? -3
        extractor = FeatureExtractor(sampleRate: console.sampleRate)
        detector = FeedbackDetector(sampleRate: console.sampleRate)
        let kinds = console.sources.mapValues(\.kind)
        let ids = console.strips.keys.sorted()
        let leadID = ids.first { [.maleVocal, .femaleVocal, .speech].contains(kinds[$0] ?? .unknown) }
        lead = leadID
        rhythm = ids.filter { [.drums, .band].contains(kinds[$0]?.family ?? .other) && kinds[$0] != .keys && kinds[$0] != .piano }
        keys = ids.filter { kinds[$0] == .keys || kinds[$0] == .piano }
        backing = ids.filter { kinds[$0] == .backingVocal || (kinds[$0]?.family == .vocals && $0 != leadID) }
        ensemble = ids.filter { kinds[$0] == .choir || (kinds[$0]?.isOrchestral ?? false) }
        // Everything starts down; the engineer brings it up.
        for id in ids { strips[id]?.faderDB = -90; console.setStrip(strips[id]!) }
        guardian = ShowGuard(strips: Array(strips.values), buses: Array(buses.values), character: character)
    }

    /// The loudness each role sits at in this mix (dB on the fader).
    func role(_ ch: Int) -> Double {
        if ch == lead { return -5 }
        let k = console.sources[ch]?.kind
        if k == .kick { return -8 }
        if backing.contains(ch) { return -12 }
        if ensemble.contains(ch) { return -11 }
        return -10
    }

    /// Lowest lead fader at which the hall starts to howl in the simulator (for the "hot vocal" scene).
    func leadFeedbackFader() -> Double {
        guard let l = lead, let s = strips[l], let src = console.sources[l] else { return 0 }
        return console.roomModes.map { fr, modeDB in -(s.gainDB - 20 + src.couplingDB + modeDB + s.filterResponseDB(at: fr)) }.min() ?? 0
    }

    func playing(_ sc: Scene) -> Set<Int> {
        let l = lead.map { [$0] } ?? []
        switch sc {
        case .intro: return Set(rhythm + keys)
        case .verse: return Set(rhythm + keys + l)
        case .chorus, .monitorPush: return Set(rhythm + keys + l + backing + ensemble)
        case .ballad, .hotVocal: return Set(keys + l)
        case .outro: return Set(rhythm + keys + l + backing + ensemble)
        }
    }

    func enter(_ sc: Scene) -> [BusStrip] {
        scene = sc
        events.append((time, .scene(sc)))
        let on = playing(sc)
        console.silent = Set(strips.keys).subtracting(on)
        console.proximityDB = [:]
        for id in strips.keys { faderTarget[id] = on.contains(id) ? role(id) : -90 }
        if sc == .outro { for id in strips.keys { faderTarget[id] = -90 } }
        var busChanges: [BusStrip] = []
        if sc == .monitorPush, var b = buses[2] {
            // The choir asks for more in their wedges; the engineer pushes past where it rings.
            b.faderDB = (console.loopAtDB[2] ?? 0) + 2
            busChanges.append(b)
        }
        if sc == .ballad, let b = buses[2], abs(b.faderDB - busOriginal) > 0.1 {
            // After the song the engineer sets the wedges back to where they were.
            var r = b
            r.faderDB = busOriginal
            busChanges.append(r)
        }
        hotTarget = sc == .hotVocal ? leadFeedbackFader() + 3 : nil
        if sc == .verse, let l = lead {
            // The soundcheck reference of the lead's tone, taken from a clean window.
            let r = console.render(seconds: 1, channels: [l])
            if let x = r.taps[l] { guardian.references[l] = extractor.analyze(x).bandsDB }
        }
        return busChanges
    }

    /// Advances the show by `dt` seconds (≈ 0.25 s for smooth fader moves). Returns what to send to the
    /// console: channel strips (engineer's faders and the guard's EQ) and buses (engineer and guard).
    public func step(dt: Double = 0.25) -> (strips: [ChannelStrip], buses: [BusStrip]) {
        var outStrips: [Int: ChannelStrip] = [:]
        var outBuses: [Int: BusStrip] = [:]
        let index = Int(time / sceneSeconds) % Scene.allCases.count
        let sc = Scene.allCases[index]
        if sc != scene || time == 0 {
            for b in enter(sc) {
                buses[b.id] = b
                console.setBus(b)
                guardian.consoleChanged(bus: b, time: time)
                events.append((time, .engineerBus(bus: b.id, toDB: b.faderDB)))
                outBuses[b.id] = b
            }
        }
        let inScene = time.truncatingRemainder(dividingBy: sceneSeconds)
        // Scene details over time.
        if let l = lead {
            if scene == .verse || scene == .chorus { faderTarget[l] = role(l) + (scene == .chorus ? 1 : 0) + 1.5 * sin(2 * .pi * time / 7) }
            if scene == .ballad && inScene > 3 { console.proximityDB[l] = 8 }
            // The engineer pushes once, 3 dB past where the hall rings (decided when the scene starts).
            if scene == .hotVocal && inScene > 2 { faderTarget[l] = hotTarget ?? role(l) }
        }

        // The engineer's hands: faders glide to their targets (12 dB/s; from off they jump to -40 first).
        for (id, target) in faderTarget {
            guard var s = strips[id] else { continue }
            var f = s.faderDB
            if target > -90 && f <= -90 { f = -40 }
            let delta = target - f
            f += max(-12 * dt, min(12 * dt, delta))
            if target <= -90 && f < -60 { f = -90 }
            if abs(f - s.faderDB) >= faderStep || (f <= -90 && s.faderDB > -90) {
                s.faderDB = (f * 4).rounded() / 4
                strips[id] = s
                console.setStrip(s)
                guardian.consoleChanged(s, time: time)
                outStrips[id] = s
                if abs(s.faderDB - target) < 0.3 || s.faderDB <= -90 { events.append((time, .engineerFader(channel: id, toDB: s.faderDB))) }
            }
        }

        // The guard listens 4 times a second, as in the app.
        if time - lastGuardTime >= 0.25 - 1e-9 {
            lastGuardTime = time
            let on = strips.keys.filter { !(console.silent.contains($0)) && (strips[$0]?.faderDB ?? -90) > -90 }
            let r = console.render(seconds: 0.25, channels: on.sorted())
            let feats = r.taps.mapValues { extractor.analyze($0) }
            let levels = console.busLevels(channelRMS: feats.filter { $0.value.hasSignal }.mapValues(\.rmsDB))
            lastBusLevels = levels
            lastChannelLevels = feats.filter { $0.value.hasSignal }.mapValues(\.rmsDB)
            let hall = detector.process(r.mic)
            let g = guardian.step(time: time, channels: feats, busLevels: levels, hallFeedback: hall)
            for s in g.strips {
                strips[s.id] = s
                console.setStrip(s)
                outStrips[s.id] = s
            }
            for b in g.buses {
                buses[b.id] = b
                console.setBus(b)
                outBuses[b.id] = b
            }
        }
        time += dt
        return (outStrips.values.sorted { $0.id < $1.id }, outBuses.values.sorted { $0.id < $1.id })
    }
}
