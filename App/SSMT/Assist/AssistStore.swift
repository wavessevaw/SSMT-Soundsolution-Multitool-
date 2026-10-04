import Foundation
import Network
import SSMTAudio
import SSMTCore
import SwiftUI

/// UDP link to a Behringer X32 / Midas M32 or X Air console over the venue network (Wi-Fi router or cable),
/// as remote-control apps do: OSC parameters, /xremote updates and meter streams.
final class X32Link: @unchecked Sendable {
    let family: MixerFamily
    let host: String
    private let queue = DispatchQueue(label: "ssmt.assist.x32")
    private var connection: NWConnection?
    private var keepAlive: DispatchSourceTimer?
    /// Meter banks to keep streaming.
    var meterBanks: [ConsoleMeters.Bank] = [.channels, .buses, .rta]
    /// Every message received from the console (called on the link's queue).
    var onMessage: ((OSCMessage) -> Void)?

    init(family: MixerFamily, host: String) {
        self.family = family
        self.host = host
    }

    func start() {
        open()
        // The console forgets a remote and stops meters after 10 s without renewal.
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 8, repeating: 8)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.sendNow(self.subscriptions())
        }
        t.resume()
        keepAlive = t
    }

    /// Opens the UDP flow and asks the console to talk to us. A flow that fails (the Wi-Fi dropped, the Mac changed
    /// network) is opened again a second later, so the link comes back by itself when the network does.
    private func open() {
        let c = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: family.defaultPort) ?? 10023, using: .udp)
        connection = c
        c.stateUpdateHandler = { [weak self, weak c] state in
            guard let self, let c, self.connection === c else { return }
            if case .failed = state { self.reopenSoon(c) }
        }
        c.start(queue: queue)
        receive(c)
        sendNow([X32Codec.info] + subscriptions())
    }

    private func reopenSoon(_ c: NWConnection) {
        c.cancel()
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.connection === c, self.keepAlive != nil else { return }
            self.open()
        }
    }

    private func subscriptions() -> [OSCMessage] {
        [X32Codec.subscribe(family: family)] + meterBanks.map { ConsoleMeters.request($0, family: family) }
    }

    /// Asks for the input routing (X32), every channel strip and every mix bus. Spaced out — a few
    /// messages per millisecond at most — because a console on Wi-Fi drops bursts; what is still missing is asked
    /// again later (`ask`).
    func queryAll(channels: Int, routing: X32InputRouting) {
        if family != .xAir {
            ask(X32InputRouting.blockAddresses + (1...channels).map { X32Codec.channelPath($0) + "/config/source" })
        }
        ask((1...channels).flatMap { X32Codec.queryAddresses($0, family: family, routing: routing) }
            + (1...X32Codec.busCount(family)).flatMap { X32Codec.busQueryAddresses($0, family: family) })
    }

    /// Queries addresses in small paced batches (8 every 10 ms), after whatever is already queued.
    func ask(_ addresses: [String]) {
        queue.async { [weak self] in
            guard let self else { return }
            var t = max(self.nextFree, DispatchTime.now())
            for start in stride(from: 0, to: addresses.count, by: 8) {
                let msgs = addresses[start..<min(start + 8, addresses.count)].map { OSCMessage($0) }
                self.queue.asyncAfter(deadline: t) { [weak self] in self?.sendNow(msgs) }
                t = t + 0.01
            }
            self.nextFree = t
        }
    }

    /// When the paced queries already queued are all sent (touched on `queue` only).
    private var nextFree = DispatchTime.now()

    func send(_ messages: [OSCMessage]) { queue.async { [weak self] in self?.sendNow(messages) } }

    private func sendNow(_ messages: [OSCMessage]) {
        for m in messages { connection?.send(content: m.encoded(), completion: .contentProcessed { _ in }) }
    }

    private func receive(_ c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, let msgs = OSCMessage.decode(data) { msgs.forEach { self.onMessage?($0) } }
            if error == nil { self.receive(c) } else if self.connection === c { self.reopenSoon(c) }
        }
    }

    func stop() {
        keepAlive?.cancel()
        keepAlive = nil
        connection?.cancel()
        connection = nil
    }
}

/// Live levels for the meters (separate from the store so only the meters redraw ~10 times a second).
@MainActor
final class AssistMeters: ObservableObject {
    /// Channel levels (dBFS).
    @Published var channels: [Int: Double] = [:]
    /// Mix bus levels (dBFS).
    @Published var buses: [Int: Double] = [:]
    private var lastPublish = Date.distantPast
    private var pending: [Int: Double] = [:]

    /// Collects a meter frame; publishes at most 10 times a second.
    func feed(channels levels: [Double]) {
        for (i, v) in levels.enumerated() { pending[i + 1] = v }
        if Date().timeIntervalSince(lastPublish) >= 0.1 {
            channels = pending
            lastPublish = Date()
        }
    }

    func set(channels levels: [Int: Double]) { channels.merge(levels) { $1 } }
}

/// Function #4: FOH Assist. Soundcheck: tunes channels and groups by itself. Show: backs up the engineer.
@MainActor
final class AssistStore: ObservableObject {
    enum Connection: Equatable {
        case disconnected
        case connecting
        case connected(String)
        case failed(String)
    }

    /// Where the assistant hears each channel.
    enum SignalSource: String, CaseIterable {
        /// Console meters and RTA over the network (Wi-Fi). Nothing else to connect.
        case network
        /// Every console channel as an input of the Mac (USB / Dante card): full audio analysis.
        case interface
    }

    enum Mode: String, CaseIterable { case soundcheck, show, test }

    @Published var family: MixerFamily = .simulator
    @Published var host = UserDefaults.standard.string(forKey: "assist.host") ?? "192.168.1.64" {
        didSet { UserDefaults.standard.set(host, forKey: "assist.host") }
    }
    @Published private(set) var connection: Connection = .disconnected
    @Published private(set) var strips: [ChannelStrip] = []
    @Published private(set) var buses: [BusStrip] = []
    @Published var mode: Mode = .soundcheck { didSet { if mode != .test { stopWave() } } }
    @Published var character: MixCharacter = .musical {
        didSet { session?.character = character; guardian?.character = character }
    }
    @Published var tap: TapPoint = .preEQ { didSet { session?.tap = tap } }
    @Published var signalSource: SignalSource = .network
    /// Audio interface with the measurement mic (and, for `.interface`, the console channels).
    @Published var inputDeviceUID: String?
    /// Interface input that carries console channel 1 (the others follow in order).
    @Published var firstInput = 1
    /// Interface input of the hall measurement microphone (0 = none) and of an optional stage mic.
    @Published var micInput = 0
    @Published var stageMicInput = 0
    /// Measurement microphone from the function #1 library (nil = the one selected there).
    @Published var micID: UUID?
    @Published var rangeFrom = 1
    @Published var rangeTo = 8
    @Published private(set) var log: [AssistSession.LogEntry] = []
    @Published private(set) var guardLog: [(time: Double, action: GuardAction)] = []
    @Published private(set) var features: [Int: SignalFeatures] = [:]
    @Published private(set) var busLevels: [Int: Double] = [:]
    /// Channel shown in the detail panel of the soundcheck screen.
    @Published var selectedChannel: Int?
    /// Console / audio settings sheet.
    @Published var showSettings = false
    /// What the show guard is holding right now.
    @Published private(set) var corrections: [ShowGuard.Correction] = []
    /// Consoles found on the network (connect screen).
    @Published private(set) var discovered: [DiscoveredConsole] = []
    @Published private(set) var scanning = false
    /// The connect screen searches the network when it opens (off in snapshot tests).
    var autoScan = true
    /// The console answers (meters, /xremote updates) — the green / red lamp.
    @Published private(set) var linkAlive = false
    private var lastHeard = Date.distantPast
    private var healthTimer: Timer?
    /// Show time since the guard (or the show simulation) started, seconds.
    @Published private(set) var guardElapsed: Double = 0
    let liveMeters = AssistMeters()
    @Published private(set) var job: AssistSession.Job = .none
    @Published private(set) var running = false
    @Published private(set) var guarding = false
    @Published private(set) var groupPhase: GroupPhase?
    @Published private(set) var micLevel: Double?
    @Published private(set) var micCalibrated = false
    @Published var message: String?
    // Console test with simulation
    @Published var testScenario = "musical"
    @Published var testFirst = 1
    @Published var testMuteMain = true
    @Published private(set) var testChecks: [ConsoleTestCheck] = []
    @Published private(set) var testing = false
    // Show simulation: a made-up show with a virtual engineer riding the faders; the guard runs alongside.
    @Published private(set) var rehearsing = false
    @Published private(set) var rehearsalScene: ShowRehearsal.Scene?
    @Published private(set) var rehearsalLog: [(time: Double, event: ShowRehearsal.Event)] = []
    @Published var rehearsalSceneSeconds = 20.0
    private var rehearsal: ShowRehearsal?
    private var rehearsalBackup: (strips: [Int: ChannelStrip], buses: [Int: BusStrip])?
    private let rehearsalQueue = DispatchQueue(label: "ssmt.assist.rehearsal")
    private var rehearsalBusy = false

    /// Microphones of the function #1 library, the selected one and the SPL calibration (set by AppModel).
    var micLibrary: () -> (mics: [MicrophoneCalibration], selected: UUID?, spl: SPLCalibration?) = { ([], nil, nil) }

    private var session: AssistSession?
    private(set) var guardian: ShowGuard?
    private var sim: SimulatedConsole?
    private var link: X32Link?
    private var capture: AssistCapture?
    private var timer: Timer?
    private var stripMap: [Int: ChannelStrip] = [:]
    private var busMap: [Int: BusStrip] = [:]
    /// Which head amp feeds each channel (X32): gains are read and written only where this is known.
    private var routing = X32InputRouting()
    /// Routing set by hand (default: local inputs 1–32, the console as it comes) or read from the console (auto).
    @Published var routingPreset: X32InputRouting.Preset =
        X32InputRouting.Preset(rawValue: UserDefaults.standard.string(forKey: "ssmt.assist.routing") ?? "") ?? .local {
        didSet {
            UserDefaults.standard.set(routingPreset.rawValue, forKey: "ssmt.assist.routing")
            if let fixed = X32InputRouting.preset(routingPreset) { routing = fixed } else if routingPreset != oldValue { routing = X32InputRouting(); link?.ask(X32InputRouting.blockAddresses + (1...family.channelCount).map { X32Codec.channelPath($0) + "/config/source" }) }
            gainAsked = []
            askGains()
        }
    }

    /// What the link brings, per second (shown as connection diagnostics).
    struct LinkStats: Equatable {
        var channelFrames = 0, busFrames = 0, rtaFrames = 0
        var paramsHeard = 0, paramsExpected = 0
        var gainKnown = 0, channels = 0
        var model = ""
    }
    @Published private(set) var linkStats = LinkStats()
    private var frameCount = (ch: 0, bus: 0, rta: 0)
    /// Addresses the console has answered (what is missing is asked again a few times).
    private var heard: Set<String> = []
    private var gainAsked: Set<Int> = []
    private var meters = ConsoleMeterAccumulator()
    /// Main L+R meter frames of the current window (the polarity check's "ear" without a hall mic).
    private var mainFrames: [Double] = []
    private var rtaCursor = 0
    private var references: [Int: [Double]] = [:]
    private var guardStart = Date()
    private let hallDetector = FeedbackDetector()
    private let stageDetector = FeedbackDetector()

    var isConnected: Bool { if case .connected = connection { return true } else { return false } }

    // MARK: measurement microphone (any microphone of the function #1 library)

    struct MicChoice: Identifiable, Hashable {
        let id: UUID
        let name: String
        let typical: Bool
    }

    var micChoices: [MicChoice] {
        let lib = micLibrary()
        return lib.mics.map { MicChoice(id: $0.id, name: $0.name, typical: false) }
            + MicrophoneProfiles.all.map { MicChoice(id: $0.uuid, name: $0.displayName, typical: true) }
    }

    var measurementMic: MeasurementMic {
        let lib = micLibrary()
        let id = micID ?? lib.selected
        let cal = id.flatMap { i in lib.mics.first { $0.id == i } ?? MicrophoneProfiles.profile(id: i)?.calibration }
        return MeasurementMic(calibration: cal, spl: lib.spl)
    }

    // MARK: connection

    func connect() {
        disconnect()
        switch family {
        case .simulator:
            let c = SimulatedConsole.demo()
            sim = c
            setStrips(c.strips)
            busMap = c.buses
            buses = busMap.values.sorted { $0.id < $1.id }
            connection = .connected("SSMT simulator · \(c.strips.count) ch")
            linkAlive = true
        case .x32, .xAir:
            connection = .connecting
            setStrips(Dictionary(uniqueKeysWithValues: (1...family.channelCount).map { ($0, ChannelStrip(id: $0)) }))
            busMap = Dictionary(uniqueKeysWithValues: (1...X32Codec.busCount(family)).map { ($0, BusStrip(id: $0)) })
            buses = busMap.values.sorted { $0.id < $1.id }
            let l = X32Link(family: family, host: host)
            l.onMessage = { [weak self] m in Task { @MainActor in self?.received(m) } }
            link = l
            l.start()
            routing = X32InputRouting.preset(routingPreset) ?? X32InputRouting()
            heard = []
            gainAsked = []
            linkStats = LinkStats()
            l.queryAll(channels: family.channelCount, routing: routing)
            l.ask([X32Codec.mainOnAddress(family)])
            // Ask again for whatever got lost on the way (Wi-Fi drops UDP).
            for delay in [2.5, 5.0, 9.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.askMissing(from: l) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.connection == .connecting else { return }
                self.connection = .failed("noAnswer")
            }
            startCapture()
        case .wing, .yamaha, .allenHeath:
            connection = .failed("not supported yet")
        }
        session = AssistSession(strips: strips, character: character, tap: tap)
        session?.measurementMic = measurementMic
        startHealthCheck()
    }

    /// Looks for X32 / M32 and X Air / MR consoles on the Wi-Fi network.
    func scan() {
        guard !scanning else { return }
        scanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let found = ConsoleScanner.scan()
            Task { @MainActor [weak self] in
                self?.discovered = found
                self?.scanning = false
            }
        }
    }

    /// Previews and tests: consoles as if found on the network.
    func showDiscovered(_ consoles: [DiscoveredConsole]) { discovered = consoles }

    func connect(to console: DiscoveredConsole) {
        family = console.family
        host = console.ip
        connect()
    }

    private func startHealthCheck() {
        healthTimer?.invalidate()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let alive = self.sim != nil || (self.isConnected && Date().timeIntervalSince(self.lastHeard) < 4)
                if alive != self.linkAlive { self.linkAlive = alive }
                self.updateLinkStats()
            }
        }
    }

    /// Once a second: frames per second of each meter stream, parameters read, channels whose gain is reachable.
    private func updateLinkStats() {
        guard link != nil else { return }
        var st = linkStats
        st.channelFrames = frameCount.ch; st.busFrames = frameCount.bus; st.rtaFrames = frameCount.rta
        frameCount = (0, 0, 0)
        let n = family.channelCount
        let expected = (1...n).flatMap { X32Codec.queryAddresses($0, family: family, routing: routing) }
            + (1...X32Codec.busCount(family)).flatMap { X32Codec.busQueryAddresses($0, family: family) }
        st.paramsExpected = expected.count
        st.paramsHeard = expected.filter { heard.contains($0) }.count
        st.gainKnown = routing.knownChannels(n, family: family)
        st.channels = n
        if st != linkStats { linkStats = st }
    }

    func disconnect() {
        stopWave()
        healthTimer?.invalidate()
        healthTimer = nil
        linkAlive = false
        stopRehearsal()
        stopJob()
        stopGuard()
        link?.stop()
        link = nil
        capture?.stop()
        capture = nil
        sim = nil
        session = nil
        connection = .disconnected
    }

    private func startCapture() {
        // Audio is needed for the measurement mic, and for the channels when they come over USB / Dante.
        guard micInput > 0 || stageMicInput > 0 || signalSource == .interface else { return }
        do { capture = try AssistCapture(deviceUID: inputDeviceUID) } catch { message = "\(error)" }
    }

    func restartCapture() {
        guard family != .simulator, isConnected || connection == .connecting else { return }
        capture?.stop()
        capture = nil
        startCapture()
    }

    /// Channels and buses whose values have not all arrived: asked again.
    private func askMissing(from l: X32Link) {
        guard link === l else { return }
        var missing: [String] = []
        if family != .xAir {
            missing += X32InputRouting.blockAddresses.filter { !heard.contains($0) }
            missing += (1...family.channelCount).map { X32Codec.channelPath($0) + "/config/source" }.filter { !heard.contains($0) }
        }
        missing += (1...family.channelCount).flatMap { X32Codec.queryAddresses($0, family: family, routing: routing) }.filter { !heard.contains($0) }
        missing += (1...X32Codec.busCount(family)).flatMap { X32Codec.busQueryAddresses($0, family: family) }.filter { !heard.contains($0) }
        if !missing.isEmpty { l.ask(missing) }
    }

    /// Gains of channels whose routing has just become known.
    private func askGains() {
        guard let link else { return }
        var asks: [String] = []
        for ch in 1...family.channelCount where !gainAsked.contains(ch) {
            if let a = X32Codec.gainAddress(ch, family: family, routing: routing) { asks.append(a); gainAsked.insert(ch) }
        }
        if !asks.isEmpty { link.ask(asks) }
    }

    private func received(_ m: OSCMessage) {
        lastHeard = Date()
        if !linkAlive && isConnected { linkAlive = true }
        if !m.arguments.isEmpty { heard.insert(m.address) }
        if m.address == X32Codec.mainOnAddress(family), let a = m.arguments.first {
            switch a { case let .int(i): mainOn = i != 0; case let .float(f): mainOn = f != 0; default: break }
            return
        }
        if family != .xAir, X32InputRouting.blockAddresses.contains(m.address) || m.address.hasSuffix("/config/source") {
            // Read from the console only in "auto"; a routing set by hand stays as set.
            if routingPreset == .auto, routing.apply(m) { askGains() }
            return
        }
        if m.address == "/info" {
            let parts = m.arguments.compactMap { if case let .string(s) = $0 { return s } else { return nil } }
            linkStats.model = parts.dropFirst().joined(separator: " · ")
            connection = .connected(parts.dropFirst().joined(separator: " · "))
            return
        }
        if let (bank, values) = ConsoleMeters.decode(m, family: family) {
            switch bank {
            case .channels: frameCount.ch += 1
            case .buses: frameCount.bus += 1
            case .rta: frameCount.rta += 1
            }
            switch bank {
            case .channels:
                liveMeters.feed(channels: values)
                if running || guarding { meters.add(channelLevels: values) }
            case .rta: if running || guarding { meters.add(rtaBands: values) }
            case .buses:
                for (i, v) in values.prefix(X32Codec.busCount(family)).enumerated() { busLevels[i + 1] = v }
                liveMeters.buses = busLevels
                if values.count >= 24, running { mainFrames.append(Decibel.fromPower(pow(10, values[22] / 10) + pow(10, values[23] / 10))) }
            }
            return
        }
        let t = Date().timeIntervalSince(guardStart)
        if let ch = X32Codec.apply(m, to: &stripMap, family: family, routing: routing) {
            if connection == .connecting { connection = .connected(host) }
            strips = stripMap.values.sorted { $0.id < $1.id }
            if let s = stripMap[ch] { session?.updateFromConsole(s); guardian?.consoleChanged(s, time: t) }
        } else if let id = X32Codec.apply(m, toBuses: &busMap) {
            buses = busMap.values.sorted { $0.id < $1.id }
            if let b = busMap[id] { guardian?.consoleChanged(bus: b, time: t) }
        }
    }

    private func setStrips(_ map: [Int: ChannelStrip]) {
        stripMap = map
        strips = map.values.sorted { $0.id < $1.id }
    }

    // MARK: soundcheck jobs

    func tune(channel: Int) {
        guard let session else { return }
        session.measurementMic = measurementMic
        session.startChannel(channel)
        begin()
    }

    func tune(_ selection: AssistGroupSelection) {
        guard let session else { return }
        session.measurementMic = measurementMic
        if session.startGroup(selection).isEmpty {
            message = "nothing found"
            return
        }
        begin()
    }

    /// Automatic polarity check of the mic pairs found from the console names (kick in/out, snare top/bottom,
    /// bass DI/mic, guitar L/R, overheads against the snare).
    func checkPolarity() {
        guard let session else { return }
        session.measurementMic = measurementMic
        if session.startPolarity().isEmpty {
            message = "nothing found"
            return
        }
        begin()
    }

    private func begin() {
        message = nil
        job = session?.job ?? .none
        running = true
        followRTA()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.step() }
        }
    }

    func stopJob() {
        if !guarding { timer?.invalidate(); timer = nil }
        session?.stop()
        running = false
        job = .none
        groupPhase = nil
    }

    func undoAll() {
        guard let session else { return }
        apply(session.undo())
        stopJob()
    }

    /// Runs steps immediately instead of every 2 s (demo in the simulator, snapshot tests).
    func runNow(steps: Int) {
        timer?.invalidate()
        timer = nil
        for _ in 0..<steps { step() }
    }

    /// The console RTA follows the channel being tuned; in a group it visits the members in turn.
    private func followRTA() {
        guard let link, let session else { return }
        let chans = session.listening
        guard !chans.isEmpty else { return }
        let ch = chans[rtaCursor % chans.count]
        rtaCursor += 1
        meters.rtaChannel = ch
        link.send(ConsoleMeters.rtaFollow(channel: ch, family: family))
    }

    /// Features of the listened channels for the last window, and the hall mic audio.
    private func window(channels chans: [Int], seconds: Double) -> ([Int: SignalFeatures], [Float]?, [Float]?) {
        var feats: [Int: SignalFeatures] = [:]
        var mic: [Float]?
        var stage: [Float]?
        let ex = FeatureExtractor()
        if let sim {
            let r = sim.render(seconds: seconds, channels: chans, tap: tap)
            for (ch, x) in r.taps { feats[ch] = ex.analyze(x) }
            mic = r.mic
        } else {
            if signalSource == .interface, let capture {
                for ch in chans { if let x = capture.latest(input: firstInput + ch - 1, seconds: seconds) { feats[ch] = ex.analyze(x) } }
            } else {
                let w = meters.takeWindow(seconds: seconds)
                for ch in chans { if let f = w[ch] { feats[ch] = f } }
            }
            if micInput > 0 { mic = capture?.latest(input: micInput, seconds: seconds) }
            if stageMicInput > 0 { stage = capture?.latest(input: stageMicInput, seconds: seconds) }
        }
        if let mic {
            let l = measurementMic.levelA(mic, sampleRate: capture?.sampleRate ?? 48000)
            micLevel = l.value
            micCalibrated = l.calibrated
        }
        return (feats, mic, stage)
    }

    private func step() {
        guard let session, session.isRunning else {
            if running { running = false; if !guarding { timer?.invalidate(); timer = nil } }
            return
        }
        let (feats, mic, _) = window(channels: session.listening, seconds: 2)
        let main = mainFrames.isEmpty ? nil : Decibel.fromPower(mainFrames.reduce(0) { $0 + pow(10, $1 / 10) } / Double(mainFrames.count))
        mainFrames.removeAll()
        let changed = session.tick(features: feats, mic: mic, mainLevelDB: main)
        apply(changed)
        log = Array(session.log.suffix(200))
        features.merge(session.features) { $1 }
        liveMeters.set(channels: feats.filter { $0.value.hasSignal }.mapValues(\.rmsDB))
        groupPhase = session.group?.phase
        // A channel that is ready becomes the show guard's tonal reference.
        for ch in session.listening where references[ch] == nil {
            let done = session.single?.channel == ch ? session.single?.state == .done : session.group?.tunings[ch]?.state == .done
            if done, let f = session.features[ch], f.bandsDB.contains(where: { $0 > -119 }) { references[ch] = f.bandsDB }
        }
        if !session.isRunning { running = false; timer?.invalidate(); timer = nil } else { followRTA() }
    }

    private func apply(_ changed: [ChannelStrip]) {
        for var s in changed {
            let old = stripMap[s.id]
            // A gain the console cannot take yet (routing still unknown): it stays as it is, and the assistant
            // learns so instead of believing it changed.
            if link != nil, let o = old, o.gainDB != s.gainDB, X32Codec.gainAddress(s.id, family: family, routing: routing) == nil {
                s.gainDB = o.gainDB
                session?.updateFromConsole(s)
            }
            stripMap[s.id] = s
            sim?.setStrip(s)
            link?.send(X32Codec.messages(from: old, to: s, family: family, routing: routing))
        }
        if !changed.isEmpty { strips = stripMap.values.sorted { $0.id < $1.id } }
    }

    private func apply(buses changed: [BusStrip]) {
        for b in changed {
            let old = busMap[b.id]
            busMap[b.id] = b
            sim?.setBus(b)
            link?.send(X32Codec.busMessages(from: old, to: b, family: family))
        }
        if !changed.isEmpty { buses = busMap.values.sorted { $0.id < $1.id } }
    }

    // MARK: console test with simulation

    /// Runs the whole assistant on the real console with made-up musicians and reads every value back
    /// (in the simulator: against the built-in X32 emulator). The console is restored at the end.
    func runConsoleTest() {
        guard !testing else { return }
        stopWave()
        stopJob()
        stopGuard()
        let scenario = AssistScenario.all.first { $0.id == testScenario } ?? .musical
        let transport: ConsoleTransport
        var udp: UDPConsoleTransport?
        switch family {
        case .x32, .xAir:
            let t = UDPConsoleTransport(host: host, port: family.defaultPort)
            udp = t
            transport = t
        default:
            transport = ConsoleEmulator(family: .x32)
        }
        let fam: MixerFamily = family == .xAir ? .xAir : .x32
        let first = min(testFirst, max(1, fam.channelCount - scenario.channels.count + 1))
        let runner = ConsoleTestRunner(scenario: scenario, family: fam, firstChannel: first, transport: transport)
        runner.muteMain = testMuteMain
        runner.character = character
        runner.onProgress = { [weak self] c in Task { @MainActor in self?.testChecks = c } }
        testChecks = []
        testing = true
        Task.detached { [weak self] in
            let result = await runner.run()
            udp?.close()
            await MainActor.run {
                self?.testChecks = result
                self?.testing = false
                // Show the console as it is now (restored).
                if let self, let link = self.link { link.queryAll(channels: self.family.channelCount, routing: self.routing) }
            }
        }
    }

    // MARK: show simulation

    /// Plays a made-up show on the console: channel names, musicians coming and going by scene, a virtual
    /// engineer riding faders (motor faders move on a real X32), and the show guard reacting. On a real console
    /// the channels and monitors used are backed up first and restored when the simulation stops.
    func startRehearsal() {
        guard !rehearsing else { return }
        stopJob()
        stopGuard()
        let scenario = AssistScenario.all.first { $0.id == testScenario } ?? .musical
        let fam: MixerFamily = family == .xAir ? .xAir : .x32
        let first = min(testFirst, max(1, fam.channelCount - scenario.channels.count + 1))
        let console = SimulatedConsole.scenario(scenario, first: first)
        let r = ShowRehearsal(console: console, character: character, sceneSeconds: rehearsalSceneSeconds)
        rehearsal = r
        guardian = r.guardian
        guarding = true
        rehearsing = true
        rehearsalLog = []
        guardLog = []
        let chans = console.strips.keys.sorted()
        if family == .x32 || family == .xAir {
            let t = UDPConsoleTransport(host: host, port: family.defaultPort)
            Task { [weak self] in
                let routing = await ConsoleBackup.readRouting(t, channels: chans, family: fam)
                let backup = await ConsoleBackup.read(t, channels: chans, buses: Array(1...4), family: fam, routing: routing)
                t.close()
                guard let self, self.rehearsing else { return }
                self.routing = routing
                self.rehearsalBackup = backup
                // Names, the starting faders and the monitor buses of the made-up show.
                for s in r.strips.values { self.link?.send(X32Codec.messages(from: nil, to: s, family: fam, routing: routing)) }
                for b in r.buses.values { self.link?.send(X32Codec.busMessages(from: nil, to: b, family: fam) + [OSCMessage(X32Codec.busPath(b.id, family: fam) + "/config/name", [.string(b.name)])]) }
                self.beginRehearsalClock()
            }
        } else {
            beginRehearsalClock()
        }
        for s in r.strips.values { stripMap[s.id] = s }
        strips = stripMap.values.sorted { $0.id < $1.id }
        for b in r.buses.values { busMap[b.id] = b }
        buses = busMap.values.sorted { $0.id < $1.id }
    }

    private func beginRehearsalClock() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.rehearsalTick() }
        }
    }

    private func rehearsalTick() {
        guard let r = rehearsal, !rehearsalBusy else { return }
        rehearsalBusy = true
        // The show (and its audio analysis) runs off the main thread; the console and the screen are updated here.
        rehearsalQueue.async { [weak self] in
            let out = r.step(dt: 0.25)
            let scene = r.scene
            let events = Array(r.events.suffix(80))
            let glog = Array(r.guardian.log.suffix(200))
            let busLv = r.lastBusLevels
            let chLv = r.lastChannelLevels
            let now = r.time
            DispatchQueue.main.async {
                guard let self, self.rehearsal === r else { return }
                self.rehearsalBusy = false
                let fam: MixerFamily = self.family == .xAir ? .xAir : .x32
                for s in out.strips {
                    self.link?.send(X32Codec.messages(from: self.stripMap[s.id], to: s, family: fam, routing: self.routing))
                    self.stripMap[s.id] = s
                }
                for b in out.buses {
                    self.link?.send(X32Codec.busMessages(from: self.busMap[b.id], to: b, family: fam))
                    self.busMap[b.id] = b
                }
                if !out.strips.isEmpty { self.strips = self.stripMap.values.sorted { $0.id < $1.id } }
                if !out.buses.isEmpty { self.buses = self.busMap.values.sorted { $0.id < $1.id } }
                self.rehearsalScene = scene
                self.rehearsalLog = events.filter { if case .engineerFader = $0.event { return false }; return true }
                self.guardLog = glog
                self.corrections = r.guardian.corrections(at: r.time)
                self.liveMeters.buses = busLv
                self.busLevels = busLv
                self.liveMeters.set(channels: chLv)
                self.guardElapsed = now
            }
        }
    }

    func stopRehearsal() {
        guard rehearsing else { return }
        timer?.invalidate()
        timer = nil
        rehearsing = false
        rehearsalScene = nil
        if let r = rehearsal {
            let (s, b) = r.guardian.releaseAll()
            for x in s { stripMap[x.id] = x }
            for x in b { busMap[x.id] = x }
        }
        rehearsal = nil
        guardian = nil
        guarding = false
        // Put the console back as it was before the simulation.
        if let backup = rehearsalBackup, let link {
            let fam: MixerFamily = family == .xAir ? .xAir : .x32
            for s in backup.strips.values { link.send(X32Codec.messages(from: nil, to: s, family: fam, routing: routing)); stripMap[s.id] = s }
            for b in backup.buses.values {
                link.send(X32Codec.busMessages(from: nil, to: b, family: fam) + [OSCMessage(X32Codec.busPath(b.id, family: fam) + "/config/name", [.string(b.name)])])
                busMap[b.id] = b
            }
            link.queryAll(channels: family.channelCount, routing: routing)
        }
        rehearsalBackup = nil
        strips = stripMap.values.sorted { $0.id < $1.id }
        buses = busMap.values.sorted { $0.id < $1.id }
    }

    // MARK: per-channel state for the table

    func state(of ch: Int) -> TuningState? {
        guard let session else { return nil }
        if let t = session.single, t.channel == ch { return t.state }
        return session.group?.tunings[ch]?.state
    }

    func kind(of ch: Int) -> SourceKind? {
        guard let session else { return nil }
        if let t = session.single, t.channel == ch { return t.kind }
        if let t = session.group?.tunings[ch] { return t.kind }
        return SourceClassifier.classify(name: stripMap[ch]?.name ?? "", features: features[ch]).kind
    }

    var inputDevices: [AudioDeviceInfo] { DeviceCatalog.allDevices().filter { $0.inputChannels > 0 } }

    // MARK: fader wave (console test)

    /// Every channel fader runs a travelling sine wave top to bottom, to judge the motor faders' smoothness.
    @Published private(set) var waving = false
    /// Seconds for one fader to go top → bottom → top.
    @Published var waveCycle: Double = 4
    private(set) var waveStart = Date()
    private var waveTimer: Timer?
    private var waveBackup: [Int: Double] = [:]
    private var waveMainWasOn: Bool?
    /// The console's main output on / off, as last read or pushed.
    private var mainOn: Bool?
    /// Fader updates per second during the wave.
    static let waveRate = 25.0

    var waveChannels: Int { family == .simulator ? stripMap.count : family.channelCount }

    func startWave() {
        guard isConnected, !waving else { return }
        stopJob()
        stopGuard()
        stopRehearsal()
        waveBackup = stripMap.mapValues(\.faderDB)
        // Faders at the top must not reach the PA: the main output is off for the wave.
        waveMainWasOn = mainOn
        link?.send([OSCMessage(X32Codec.mainOnAddress(family), [.int(0)])])
        waveStart = Date()
        waving = true
        let t = Timer(timeInterval: 1 / Self.waveRate, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.waveTick() }
        }
        RunLoop.main.add(t, forMode: .common)
        waveTimer = t
    }

    private func waveTick() {
        guard waving else { return }
        let w = FaderWave(cycleSeconds: waveCycle)
        let t = Date().timeIntervalSince(waveStart)
        if let link {
            link.send(w.messages(at: t, channels: waveChannels))
        } else if let sim {
            for (i, p) in w.positions(at: t, channels: waveChannels).enumerated() {
                guard var s = stripMap[i + 1] else { continue }
                s.faderDB = X32Codec.faderDB(p)
                sim.setStrip(s)
            }
        }
    }

    func stopWave() {
        guard waving else { return }
        waveTimer?.invalidate()
        waveTimer = nil
        waving = false
        // Faders back where they were, then the main output as it was (left off if that is not known).
        if let link {
            link.send(waveBackup.keys.sorted().map { OSCMessage(X32Codec.faderAddress($0), [.float(Float(X32Codec.faderPosition(waveBackup[$0]!)))]) })
            if waveMainWasOn == true { link.send([OSCMessage(X32Codec.mainOnAddress(family), [.int(1)])]) }
            else if waveMainWasOn == nil { message = "assist.wave.mainLeftOff" }
        } else if let sim {
            for (ch, db) in waveBackup { if var s = stripMap[ch] { s.faderDB = db; sim.setStrip(s) } }
        }
        waveBackup = [:]
    }

    // MARK: show guard

    func startGuard() {
        guard isConnected else { return }
        stopJob()
        let g = ShowGuard(strips: strips, buses: buses, character: character)
        g.references = references
        guardian = g
        guardStart = Date()
        guardElapsed = 0
        corrections = []
        guarding = true
        hallDetector.reset()
        stageDetector.reset()
        timer?.invalidate()
        // 4 steps a second: feedback and ringing monitors are caught within a quarter of a second.
        guardSteps = 0
        timer = Timer.scheduledTimer(withTimeInterval: Self.guardInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.guardStep() }
        }
    }

    func stopGuard() {
        guard let g = guardian else { return }
        let (s, b) = g.releaseAll()
        apply(s)
        apply(buses: b)
        guardian = nil
        guarding = false
        timer?.invalidate()
        timer = nil
    }

    func setMonitor(_ bus: Int, _ on: Bool) {
        if on { guardian?.monitorBuses.insert(bus) } else { guardian?.monitorBuses.remove(bus) }
        objectWillChange.send()
    }

    func setLead(_ ch: Int, _ on: Bool) {
        if on { guardian?.leads.insert(ch) } else { guardian?.leads.remove(ch) }
        objectWillChange.send()
    }

    /// Runs guard steps immediately (simulator demo, tests).
    func runGuardNow(steps: Int) {
        timer?.invalidate()
        timer = nil
        for _ in 0..<steps { guardStep() }
    }

    private var guardTime: Double = 0
    private var guardSteps = 0
    static let guardInterval = 0.25

    /// The engineer cancels one correction of the guard from the list.
    func cancelCorrection(_ id: String) {
        guard let g = guardian else { return }
        let t = rehearsal?.time ?? (sim != nil ? guardTime : Date().timeIntervalSince(guardStart))
        let (s, b) = g.cancel(id, time: t)
        apply(s)
        apply(buses: b)
        corrections = g.corrections(at: t)
        guardLog = Array(g.log.suffix(200))
    }

    /// Log lines of one channel (soundcheck detail panel).
    func log(of ch: Int) -> [AssistSession.LogEntry] { log.filter { $0.channel == ch } }

    private func guardStep() {
        guard let g = guardian else { return }
        let t = sim != nil ? guardTime : Date().timeIntervalSince(guardStart)
        guardTime += Self.guardInterval
        guardSteps += 1
        // Spectra visit the channels that are playing, one per second (the console has one RTA, and needs a moment
        // after each switch).
        let playing = stripMap.values.filter { !$0.muted && $0.faderDB > -60 }.map(\.id).sorted()
        if !playing.isEmpty, let link, guardSteps % Int((1 / Self.guardInterval).rounded()) == 1 {
            let ch = playing[rtaCursor % playing.count]
            rtaCursor += 1
            meters.rtaChannel = ch
            link.send(ConsoleMeters.rtaFollow(channel: ch, family: family))
        }
        let (feats, mic, stage) = window(channels: sim != nil ? playing : Array(stripMap.keys), seconds: Self.guardInterval)
        if let sim {
            busLevels = sim.busLevels(channelRMS: feats.filter { $0.value.hasSignal }.mapValues(\.rmsDB))
        }
        let hall = mic.map { hallDetector.process($0) } ?? []
        let onStage = stage.map { stageDetector.process($0) } ?? []
        let r = g.step(time: t, channels: feats, busLevels: busLevels, hallFeedback: hall, stageFeedback: onStage)
        apply(r.strips)
        apply(buses: r.buses)
        features.merge(feats) { $1 }
        guardLog = Array(g.log.suffix(200))
        corrections = g.corrections(at: t)
        guardElapsed = t
        liveMeters.set(channels: feats.filter { $0.value.hasSignal }.mapValues(\.rmsDB))
        liveMeters.buses = busLevels
    }
}
