import Foundation
import SSMTCore

// Audio between the interface and the engine. The interface captures and plays through Chromium's Web Audio
// (WASAPI underneath) and exchanges blocks with the engine as JSON lines (see Windows/App/src/renderer/audio-io.js):
//   interface → engine  {cmd:'audioConfig', stream, sampleRate, inChannels, outChannels[, loopChannel, latency]}
//                       {cmd:'audioIn', stream, data[, played, frame]}   data: base64 Float32LE interleaved
//                       {cmd:'audioNeed', stream, frames}
//                       {cmd:'audioClose', stream}
//   engine → interface  {event:'audioOut', stream, data[, flush]}
// `played` is the interface's echo of one output channel (`loopChannel`) during the captured block's frames and
// `frame` the block's position in the stream; both are optional.

/// One audio stream of the interface ('setup' for the measurement, 'show' for Qtrl).
final class AudioStream {
    let id: String
    private(set) var sampleRate: Double = 48000
    private(set) var inChannels = 0
    private(set) var outChannels = 0
    private(set) var isOpen = false
    /// Output channel the interface echoes in `played`, if any.
    private(set) var loopChannel: Int?
    /// Round-trip latency the interface reported (seconds).
    private(set) var latency: Double = 0
    /// Number of times the stream was (re)configured: a new value means a new stream.
    private(set) var generation: UInt64 = 0
    /// The echo of the looped output channel for the block being delivered to the sink (nil if none).
    private(set) var played: [Float]?
    /// Position of the block being delivered to the sink (frames since the stream opened), if known.
    private(set) var frame: Int64?

    private var render: ((_ out: inout [Float], _ frames: Int, _ channels: Int) -> Void)?
    private var sink: ((_ samples: [Float], _ frames: Int, _ channels: Int) -> Void)?
    private var buffer: [Float] = []

    init(id: String) { self.id = id }

    /// Fills the interleaved output when the interface asks for more (`audioNeed`). Nil: silence.
    func setSource(_ render: ((_ out: inout [Float], _ frames: Int, _ channels: Int) -> Void)?) {
        self.render = render
    }

    /// Receives every captured block (`audioIn`), interleaved, `channels` wide.
    func setSink(_ sink: (([Float], _ frames: Int, _ channels: Int) -> Void)?) {
        self.sink = sink
    }

    /// Drops what the interface has queued for playback (STOP must be heard at once).
    func flush() {
        guard isOpen else { return }
        Out.emit("audioOut", ["stream": id, "data": "", "flush": true])
    }

    func configure(sampleRate: Double, inChannels: Int, outChannels: Int, loopChannel: Int?, latency: Double) {
        self.sampleRate = sampleRate
        self.inChannels = max(0, inChannels)
        self.outChannels = max(0, outChannels)
        self.loopChannel = loopChannel
        self.latency = latency
        generation &+= 1
        isOpen = true
    }

    func close() {
        isOpen = false
        generation &+= 1
    }

    func received(data: String, played playedB64: String?, frame: Int64?) {
        guard isOpen, inChannels > 0, let samples = AudioCodec.decode(data) else { return }
        let frames = samples.count / inChannels
        guard frames > 0 else { return }
        played = playedB64.flatMap(AudioCodec.decode)
        self.frame = frame
        sink?(samples, frames, inChannels)
        played = nil
        self.frame = nil
    }

    func need(frames: Int) {
        guard isOpen, outChannels > 0, frames > 0 else { return }
        let n = min(frames, 48000)
        if buffer.count != n * outChannels { buffer = [Float](repeating: 0, count: n * outChannels) } else {
            for i in buffer.indices { buffer[i] = 0 }
        }
        render?(&buffer, n, outChannels)
        Out.emit("audioOut", ["stream": id, "data": AudioCodec.encode(buffer)])
    }
}

/// Base64 Float32 little-endian, as the interface sends and expects it.
enum AudioCodec {
    static func decode(_ b64: String) -> [Float]? {
        guard let d = Data(base64Encoded: b64) else { return nil }
        var out = [Float](repeating: 0, count: d.count / 4)
        _ = out.withUnsafeMutableBytes { d.copyBytes(to: $0) }
        #if _endian(big)
        out = out.map { Float(bitPattern: $0.bitPattern.byteSwapped) }
        #endif
        return out
    }

    static func encode(_ samples: [Float]) -> String {
        #if _endian(big)
        let le = samples.map { Float(bitPattern: $0.bitPattern.byteSwapped) }
        #else
        let le = samples
        #endif
        return le.withUnsafeBufferPointer { Data(buffer: $0) }.base64EncodedString()
    }
}

/// The engine's audio streams.
final class AudioBridge {
    static let shared = AudioBridge()
    private var streams: [String: AudioStream] = [:]

    func stream(_ id: String) -> AudioStream {
        if let s = streams[id] { return s }
        let s = AudioStream(id: id)
        streams[id] = s
        return s
    }
}

/// Takes the audio commands of the interface.
final class AudioIOModule: EngineModule {
    func handle(_ c: Command, engine: Engine) -> Bool {
        switch c.name {
        case "audioConfig":
            AudioBridge.shared.stream(c.str("stream") ?? "setup").configure(
                sampleRate: c.double("sampleRate") ?? 48000, inChannels: c.int("inChannels") ?? 0,
                outChannels: c.int("outChannels") ?? 0, loopChannel: c.int("loopChannel"), latency: c.double("latency") ?? 0)
        case "audioIn":
            let frame = (c.fields["frame"] as? NSNumber)?.int64Value
            AudioBridge.shared.stream(c.str("stream") ?? "setup").received(data: c.str("data") ?? "", played: c.str("played"), frame: frame)
        case "audioNeed":
            AudioBridge.shared.stream(c.str("stream") ?? "setup").need(frames: c.int("frames") ?? 0)
        case "audioClose":
            AudioBridge.shared.stream(c.str("stream") ?? "setup").close()
        default:
            return false
        }
        return true
    }
}
