import Foundation

/// Which reference the analyzer uses.
public enum ReferenceMode: String, Codable, Sendable, CaseIterable {
    /// B — the generated samples themselves (no loopback cable). Default.
    case internalSignal
    /// A — a hardware loopback cable into a second input.
    case loopbackInput
    /// C — external program material on a second input (architecture only in v1).
    case externalInput
}

/// Noise variants pre-built by a backend so they can be switched from the audio thread
/// without allocation (index into the bank).
public struct GeneratorBankSpec: Equatable, Codable, Sendable {
    public var kinds: [NoiseKind]
    public init(kinds: [NoiseKind] = [.pink, .white, .periodicPink(periodLength: 65536)]) { self.kinds = kinds }
}

/// Lock-free controls written by the UI/controller and read by the audio callback.
public final class GeneratorControl: @unchecked Sendable {
    /// Noise requested on (fade in) or off (fade out).
    public let run = AtomicBool(false)
    /// Set by STOP; the audio thread silences the very next buffer and clears the flag.
    public let hardMuteRequest = AtomicBool(false)
    /// Target RMS level (dBFS).
    public let targetLevelDBFS = AtomicFloat(-60)
    /// Index into the generator bank.
    public let kindIndex = AtomicCounter()
    /// Current generator level (dBFS RMS), published by the audio thread for display.
    public let currentLevelDBFS = AtomicFloat(-120)

    public init() {}

    /// STOP: silence the output immediately, from any state.
    public func emergencyStop() {
        run.value = false
        targetLevelDBFS.value = -120
        hardMuteRequest.value = true
    }
}

/// Real-time I/O contract shared by the Core Audio backend and the simulator.
///
/// Two rings are filled by the backend:
/// - `inputRing`: 2 channels — [microphone, reference input]
/// - `outputRing`: 1 channel — exact generated samples sent to the output
/// Both streams are continuous while the backend runs; the consumer pairs them sample by sample.
/// Their fixed offset is part of the measured system delay, so it must not change during a session:
/// any dropout or restart increments `discontinuities`.
public protocol AudioIOBackend: AnyObject {
    var sampleRate: Double { get }
    var inputRing: RealtimeRing { get }
    var outputRing: RealtimeRing { get }
    var generatorControl: GeneratorControl { get }
    var generatorBank: GeneratorBankSpec { get }
    var discontinuities: AtomicCounter { get }
    var isRunning: Bool { get }
    /// Human-readable description for the UI ("Simulation", device name…).
    var displayName: String { get }
    func start() throws
    func stop()
}

/// Real-time generator bank: renders the selected generator, honouring the lock-free controls.
/// Used identically by the simulator and the Core Audio backend.
public final class GeneratorBank {
    public let generators: [SignalGenerator]
    private var lastIndex = 0

    public init(spec: GeneratorBankSpec, sampleRate: Double, safety: GeneratorSafety, seed: UInt64) {
        generators = spec.kinds.enumerated().map { i, k in
            SignalGenerator(kind: k, sampleRate: sampleRate, seed: seed &+ UInt64(i), safety: safety)
        }
    }

    /// Real-time safe.
    @inline(__always)
    public func render(into out: UnsafeMutablePointer<Float>, count: Int, control: GeneratorControl) {
        if control.hardMuteRequest.value {
            control.hardMuteRequest.value = false
            for g in generators { g.hardMute() }
        }
        var idx = Int(control.kindIndex.value)
        if idx < 0 || idx >= generators.count { idx = 0 }
        if idx != lastIndex {
            // Switching noise type restarts from silence with a fresh fade-in.
            generators[lastIndex].hardMute()
            generators[idx].hardMute()
            lastIndex = idx
        }
        let g = generators[idx]
        g.render(into: out, count: count, run: control.run.value,
                 targetLevelDBFS: Double(control.targetLevelDBFS.value))
        control.currentLevelDBFS.value = g.isSilent ? -120 : Float(g.currentLevelDBFS)
    }

    public func updateSafety(_ s: GeneratorSafety) {
        generators.forEach { $0.updateSafety(s) }
    }
}

// MARK: - Stream backend (audio arrives and leaves as blocks pushed by a host)

/// Errors of `StreamAudioBackend`, worded as the Core Audio backend's.
public enum StreamAudioError: Error, CustomStringConvertible, Equatable {
    case notOpen
    case channelOutOfRange

    public var description: String {
        switch self {
        case .notOpen: return "Audio device not found"
        case .channelOutOfRange: return "Selected channel does not exist on the device"
        }
    }
}

/// Duplex backend whose audio is carried by a host instead of a driver callback: the Windows app's
/// interface captures and plays through the system's audio stack and exchanges blocks with the engine.
///
/// Same semantics as the Core Audio backend (`HALAudioBackend`):
/// - two input channels for the analyzer, [microphone, reference input]; without a reference channel
///   (internal reference) the reference input repeats the microphone, as the HAL channel map does;
/// - the generator renders one channel, copied to every selected output channel, the others silent;
/// - `outputRing` holds exactly the samples that were played, paired sample by sample with the input.
///   When the host echoes the played signal of each captured block (`hostEchoesPlayed`), that echo is
///   the reference, so the pairing stays exact even if the host's output queue ran dry for a moment.
///   Otherwise the rendered samples are written when rendered, as the HAL render callback does;
/// - any break in the captured stream (a gap in the host's frame counter, a restart, a new format)
///   increments `discontinuities`, so a locked delay is measured again.
///
/// Separate input and output devices (`splitClock`) are the Mac's split source: the host resamples the
/// input onto the output device's clock (the output device is the clock master, as in the Mac's private
/// aggregate device), so the output→input offset stays fixed apart from rare slips.
public final class StreamAudioBackend: AudioIOBackend, @unchecked Sendable {
    public struct Routing: Equatable, Codable, Sendable {
        public var microphoneChannel: Int
        /// Loopback / external reference input; nil in internal-reference mode.
        public var referenceChannel: Int?
        /// Output channels that carry the test signal.
        public var outputChannels: [Int]

        public init(microphoneChannel: Int = 0, referenceChannel: Int? = nil, outputChannels: [Int] = [0]) {
            self.microphoneChannel = microphoneChannel
            self.referenceChannel = referenceChannel
            self.outputChannels = outputChannels
        }
    }

    public let sampleRate: Double
    public let inputRing: RealtimeRing
    public let outputRing: RealtimeRing
    public let generatorControl = GeneratorControl()
    public let generatorBank: GeneratorBankSpec
    public let discontinuities = AtomicCounter()
    public let displayName: String
    public let routing: Routing
    /// Channel counts of the host stream (interleaved block widths).
    public let inputChannels: Int
    public let outputChannels: Int
    public let splitClock: Bool
    /// Round-trip latency reported by the host (samples), for display.
    public var reportedRoundTripLatency: Int = 0
    public private(set) var isRunning = false

    private let bank: GeneratorBank
    private var mono: [Float] = []
    private var expectedFrame: Int64 = -1
    /// The host echoes the played signal of each captured block: only the echo feeds `outputRing`.
    public let hostEchoesPlayed: Bool

    public init(sampleRate: Double, inputChannels: Int, outputChannels: Int, routing: Routing,
                displayName: String, splitClock: Bool = false, hostEchoesPlayed: Bool = true,
                bank: GeneratorBankSpec = GeneratorBankSpec(),
                safety: GeneratorSafety = GeneratorSafety(),
                seed: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000)) throws {
        guard routing.microphoneChannel >= 0, routing.microphoneChannel < inputChannels,
              (routing.referenceChannel ?? 0) < inputChannels, (routing.referenceChannel ?? 0) >= 0,
              !routing.outputChannels.isEmpty,
              routing.outputChannels.allSatisfy({ $0 >= 0 && $0 < outputChannels }) else {
            throw StreamAudioError.channelOutOfRange
        }
        self.sampleRate = sampleRate
        self.inputChannels = inputChannels
        self.outputChannels = outputChannels
        self.routing = routing
        self.displayName = displayName
        self.splitClock = splitClock
        self.hostEchoesPlayed = hostEchoesPlayed
        generatorBank = bank
        self.bank = GeneratorBank(spec: bank, sampleRate: sampleRate, safety: safety, seed: seed)
        let ringFrames = Int(sampleRate * 4)
        inputRing = RealtimeRing(minimumFrames: ringFrames, channels: 2)
        outputRing = RealtimeRing(minimumFrames: ringFrames, channels: 1)
    }

    public func updateSafety(_ s: GeneratorSafety) { bank.updateSafety(s) }

    public func start() throws {
        guard !isRunning else { return }
        inputRing.clear()
        outputRing.clear()
        expectedFrame = -1
        isRunning = true
    }

    public func stop() {
        guard isRunning else { return }
        generatorControl.emergencyStop()
        isRunning = false
    }

    /// The host restarted or reformatted its stream: the output→input offset is no longer known.
    public func markDiscontinuity() {
        discontinuities.increment()
        expectedFrame = -1
    }

    /// Fills `out` (interleaved, `channels` wide, `frames` long) with the generator on the routed outputs.
    public func render(into out: inout [Float], frames: Int, channels: Int) {
        let total = frames * channels
        if out.count != total { out = [Float](repeating: 0, count: total) } else {
            for i in 0..<total { out[i] = 0 }
        }
        guard isRunning, frames > 0, channels > 0 else { return }
        if mono.count < frames { mono = [Float](repeating: 0, count: frames) }
        mono.withUnsafeMutableBufferPointer { p in
            if let base = p.baseAddress { bank.render(into: base, count: frames, control: generatorControl) }
        }
        for c in routing.outputChannels where c < channels {
            for i in 0..<frames { out[i * channels + c] = mono[i] }
        }
        if !hostEchoesPlayed { outputRing.write([Array(mono[0..<frames])]) }
    }

    /// One captured block (interleaved, `channels` wide). `played` is the generator channel as it was
    /// played during the same frames (the host's echo); `frameIndex` is the host's position of the block.
    public func capture(_ interleaved: [Float], frames: Int, channels: Int, played: [Float]? = nil,
                        frameIndex: Int64? = nil) {
        guard isRunning, frames > 0, channels > 0, interleaved.count >= frames * channels else { return }
        if let idx = frameIndex {
            if expectedFrame >= 0 && idx != expectedFrame { discontinuities.increment() }
            expectedFrame = idx + Int64(frames)
        }
        func channel(_ c: Int) -> [Float] {
            guard c < channels else { return [Float](repeating: 0, count: frames) }
            return (0..<frames).map { interleaved[$0 * channels + c] }
        }
        let mic = channel(routing.microphoneChannel)
        let ref = channel(routing.referenceChannel ?? routing.microphoneChannel)
        guard hostEchoesPlayed else {
            inputRing.write([mic, ref])
            return
        }
        // Input and reference always advance together; a missing echo is silence that was played.
        let reference = played.map { $0.count >= frames ? Array($0[0..<frames]) : $0 + [Float](repeating: 0, count: frames - $0.count) }
            ?? [Float](repeating: 0, count: frames)
        inputRing.write([mic, ref])
        outputRing.write([reference])
    }
}
