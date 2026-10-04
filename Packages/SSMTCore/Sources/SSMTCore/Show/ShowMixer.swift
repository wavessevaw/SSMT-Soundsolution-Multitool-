import Foundation
import SSMTRealtime

/// Decoded audio at the output sample rate, planar (channel c starts at `samples + c * frames`).
/// Either owned memory or a memory-mapped cache file, so long shows do not fill the RAM.
/// Immutable, shared between threads.
public final class AudioClip: @unchecked Sendable {
    public let sampleRate: Double
    public let channelCount: Int
    public let frames: Int
    public let samples: UnsafePointer<Float>
    private let owned: UnsafeMutablePointer<Float>?
    private let mapping: NSData?

    public var duration: Double { Double(frames) / sampleRate }
    /// Bytes of decoded audio (resident in memory only for owned clips).
    public var bytes: Int { frames * channelCount * MemoryLayout<Float>.size }
    public var isMapped: Bool { mapping != nil }

    /// Owned copy of planar channels.
    public init(sampleRate: Double, channels: [[Float]]) {
        self.sampleRate = sampleRate
        let cc = max(1, channels.count)
        let n = channels.map(\.count).min() ?? 0
        channelCount = cc
        frames = n
        let p = UnsafeMutablePointer<Float>.allocate(capacity: max(1, cc * n))
        p.initialize(repeating: 0, count: max(1, cc * n))
        for (c, ch) in channels.enumerated() where n > 0 {
            ch.withUnsafeBufferPointer { src in (p + c * n).update(from: src.baseAddress!, count: n) }
        }
        owned = p
        mapping = nil
        samples = UnsafePointer(p)
    }

    /// Planar Float32 data (e.g. a memory-mapped cache file) holding `channelCount × frames` samples.
    public init?(sampleRate: Double, channelCount: Int, mapped data: NSData) {
        let count = data.length / MemoryLayout<Float>.size
        guard channelCount > 0, count >= channelCount, data.length % (MemoryLayout<Float>.size * channelCount) == 0 else { return nil }
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        frames = count / channelCount
        mapping = data
        owned = nil
        samples = data.bytes.assumingMemoryBound(to: Float.self)
    }

    deinit { owned?.deallocate() }

    @inline(__always) public func channel(_ c: Int) -> UnsafeBufferPointer<Float> {
        UnsafeBufferPointer(start: samples + min(c, channelCount - 1) * frames, count: frames)
    }

    /// Reads one sample per memory page from `start` for `count` frames so a mapped file is in RAM
    /// before the audio thread needs it. Call off the audio thread.
    @discardableResult
    public func prefetch(from start: Int, count: Int) -> Float {
        guard mapping != nil, frames > 0 else { return 0 }
        let a = max(0, min(frames - 1, start)), b = max(a, min(frames, start + count))
        var sink: Float = 0
        for c in 0..<channelCount {
            let p = samples + c * frames
            var i = a
            while i < b { sink += p[i]; i += 1024 } // 4 KB pages
        }
        return sink
    }
}

/// How a region plays: intro, a loop played `plays` times (0 = until devamp / stop), outro.
/// Without an inner loop the whole region is the loop (intro and outro are empty).
/// Units are free (frames in the mixer, seconds in the UI); `p` is the distance played.
public struct PlayMap: Equatable, Sendable {
    public var regionStart: Double
    public var intro: Double
    public var loop: Double
    public var outro: Double
    public var plays: Int

    public init(regionStart: Double, intro: Double, loop: Double, outro: Double, plays: Int) {
        self.regionStart = regionStart
        self.intro = max(0, intro)
        self.loop = max(1e-9, loop)
        self.outro = max(0, outro)
        self.plays = max(0, plays)
    }

    /// The whole region repeated `plays` times.
    public init(regionStart: Double, length: Double, plays: Int) {
        self.init(regionStart: regionStart, intro: 0, loop: length, outro: 0, plays: plays)
    }

    /// Total distance (nil = endless).
    public var total: Double? { plays == 0 ? nil : intro + loop * Double(plays) + outro }

    /// Position in the file for a played distance.
    @inline(__always) public func position(_ p: Double) -> Double {
        if p < intro { return regionStart + p }
        let q = p - intro
        if plays == 0 || q < loop * Double(plays) {
            return regionStart + intro + q.truncatingRemainder(dividingBy: loop)
        }
        return regionStart + intro + loop + (q - loop * Double(plays))
    }

    /// Loop pass (0-based) at a played distance; 0 during the intro.
    public func iteration(_ p: Double) -> Int { p < intro ? 0 : Int((p - intro) / loop) }

    /// Devamp at distance `p`: finish the current pass, then play the outro.
    public func devamped(at p: Double) -> PlayMap {
        var m = self
        let n = iteration(p) + 1
        if plays == 0 || plays > n { m.plays = n }
        return m
    }
}

extension AudioCueParams {
    /// Play map in seconds × `scale` (pass the sample rate for frames), for a file of `length` seconds.
    public func playMap(fileLength length: Double, scale: Double = 1) -> PlayMap {
        let s = min(max(0, start), max(0, length))
        let e = max(s, min(length, end ?? length))
        if let ls = loopStart, let le = loopEnd {
            let a = min(max(ls, s), e), b = min(max(le, a), e)
            if b - a > 0.001 {
                return PlayMap(regionStart: s * scale, intro: (a - s) * scale, loop: (b - a) * scale,
                               outro: (e - b) * scale, plays: plays)
            }
        }
        return PlayMap(regionStart: s * scale, length: max(1e-6, e - s) * scale, plays: plays)
    }
}

/// Everything a voice needs to start: region, loops, rate and levels.
public struct VoiceSetup: Sendable {
    public var map: PlayMap
    public var rate: Double
    public var levelDB: Double
    public var outputLevelsDB: [Double]
    /// `crosspointsDB[channel][output]`.
    public var crosspointsDB: [[Double]]
    public var fadeInFrames: Int
    public var fadeOutFrames: Int
    /// Load to time: the voice starts as if it had already played this far (file frames along the play map).
    public var startPlayed: Double = 0

    public init(map: PlayMap, rate: Double, levelDB: Double,
                outputLevelsDB: [Double], crosspointsDB: [[Double]], fadeInFrames: Int = 0, fadeOutFrames: Int = 0) {
        self.map = map
        self.rate = rate
        self.levelDB = levelDB
        self.outputLevelsDB = outputLevelsDB
        self.crosspointsDB = crosspointsDB
        self.fadeInFrames = fadeInFrames
        self.fadeOutFrames = fadeOutFrames
    }

    /// Whole region played `plays` times.
    public init(regionStart: Int, regionLength: Int, plays: Int, rate: Double, levelDB: Double,
                outputLevelsDB: [Double], crosspointsDB: [[Double]], fadeInFrames: Int = 0, fadeOutFrames: Int = 0) {
        self.init(map: PlayMap(regionStart: Double(regionStart), length: Double(regionLength), plays: plays), rate: rate,
                  levelDB: levelDB, outputLevelsDB: outputLevelsDB, crosspointsDB: crosspointsDB,
                  fadeInFrames: fadeInFrames, fadeOutFrames: fadeOutFrames)
    }

    /// Frames of output until a finite voice ends (nil = loops forever).
    public var outputFrames: Int64? {
        map.total.map { Int64(($0 / max(rate, 1e-6)).rounded(.up)) }
    }
}

/// Operations sent from the control thread to the mixer. Frames are absolute output frames.
public enum MixerOp: Sendable {
    case start(UUID, clip: AudioClip, setup: VoiceSetup, at: Int64)
    case stop(UUID, at: Int64, fadeFrames: Int64)
    case pause(UUID, at: Int64)
    case resume(UUID, at: Int64)
    /// Ramp the main level and/or output levels (nil = unchanged) to new values.
    case fade(UUID, at: Int64, frames: Int64, curve: FadeCurve, levelDB: Double?, outputsDB: [Double?])
    /// Freeze running ramps at their current value.
    case holdLevels(UUID, at: Int64)
    /// Devamp: finish the current loop iteration, then play out.
    case devamp(UUID, at: Int64)
    case stopAll(at: Int64, fadeFrames: Int64)
    /// Show output → interface channel (-1 = not patched).
    case patch([Int])
}

/// Command box handed to the audio thread; carries precomputed linear gains so the audio thread
/// never allocates. Boxes are returned to the control thread for release.
final class MixerCommand {
    let op: MixerOp
    /// Linear crosspoints, `[channel * maxOutputs + output]` (start only).
    let crosspoints: [Float]
    /// Patch as a plain array (patch only).
    init(op: MixerOp, maxOutputs: Int) {
        self.op = op
        if case let .start(_, clip, setup, _) = op {
            var xp = [Float](repeating: 0, count: clip.channelCount * maxOutputs)
            for c in 0..<clip.channelCount {
                for o in 0..<maxOutputs {
                    let row = c < setup.crosspointsDB.count ? setup.crosspointsDB[c] : []
                    let db = o < row.count ? row[o] : showSilenceDB
                    xp[c * maxOutputs + o] = Float(showGain(db))
                }
            }
            crosspoints = xp
        } else {
            crosspoints = []
        }
    }
}

/// A level that can ramp between two dB values with a curve.
struct LevelRamp {
    var fromDB: Double = 0
    var toDB: Double = 0
    var start: Int64 = 0
    var length: Int64 = 0
    var curve: FadeCurve = .sCurve

    init(_ db: Double) { fromDB = db; toDB = db }

    /// Linear gain at an absolute frame.
    @inline(__always) func gain(at f: Int64) -> Double {
        if length <= 0 || f >= start + length { return showGain(toDB) }
        if f <= start { return showGain(fromDB) }
        let t = curve.shape(Double(f - start) / Double(length))
        switch curve {
        case .linearGain:
            let a = showGain(fromDB), b = showGain(toDB)
            return a + (b - a) * t
        case .sCurve, .linearDB:
            // Interpolate in dB, with silence treated as the floor so fades reach true zero at the end.
            let a = max(fromDB, showSilenceDB), b = max(toDB, showSilenceDB)
            return showGain(a + (b - a) * t)
        }
    }

    func dB(at f: Int64) -> Double {
        let g = gain(at: f)
        return g <= 0 ? showSilenceDB : 20 * log10(g)
    }

    mutating func set(to db: Double, at f: Int64, frames: Int64, curve c: FadeCurve) {
        fromDB = dB(at: f)
        toDB = db
        start = f
        length = frames
        curve = c
    }

    mutating func hold(at f: Int64) {
        let d = dB(at: f)
        fromDB = d; toDB = d; length = 0
    }
}

final class Voice {
    var id = UUID()
    var active = false
    var command: MixerCommand?
    var clip: AudioClip?
    var setup: VoiceSetup?
    var startFrame: Int64 = 0
    /// Source frames advanced since start (over all loop iterations).
    var played: Double = 0
    var map = PlayMap(regionStart: 0, length: 1, plays: 1)
    var paused = false
    var pauseAt: Int64 = .max
    var resumeAt: Int64 = .max
    var devampAt: Int64 = .max
    var stopAt: Int64 = .max
    var stopFade: Int64 = 0
    var main = LevelRamp(0)
    /// Stop envelope (0 dB until a stop with fade begins).
    var stopEnv = LevelRamp(0)
    var outputs: [LevelRamp]

    init(maxOutputs: Int) { outputs = [LevelRamp](repeating: LevelRamp(0), count: maxOutputs) }
}

/// Real-time mixer of the show player. `render` runs on the audio thread: no locks, no allocation.
/// Control code sends `MixerOp`s with `send`, and must call `collectGarbage()` regularly.
public final class ShowMixer: @unchecked Sendable {
    public let maxOutputs: Int
    public let maxVoices: Int
    public let sampleRate: Double
    /// Frames rendered so far (= absolute frame of the next buffer).
    public let framesRendered = AtomicCounter()
    /// Peak per show output since the last read (linear), for meters.
    public let peaks: [AtomicFloat]
    /// Commands that could not be queued (queue full).
    public let droppedCommands = AtomicCounter()

    private let inbox: OpaquePointer
    private let garbage: OpaquePointer
    private var voices: [Voice]
    private var patch: [Int]
    private var patchCommand: MixerCommand?
    private let bus: UnsafeMutablePointer<Float>
    private let busFrames = 1024
    /// Per-segment scratch: sample index, interpolation fraction, envelope (shared by all outputs).
    private let scratchIndex: UnsafeMutablePointer<Int>
    private let scratchFrac: UnsafeMutablePointer<Float>
    private let scratchEnv: UnsafeMutablePointer<Float>
    /// Automatic fade-in when a voice starts inside a file (avoids a click), in frames.
    private let startDeclick: Double
    /// Short ramp used to avoid clicks on hard stops (≈ 3 ms).
    private let declick: Int64

    public init(sampleRate: Double, maxOutputs: Int = 64, maxVoices: Int = 128) {
        self.sampleRate = sampleRate
        self.maxOutputs = maxOutputs
        self.maxVoices = maxVoices
        inbox = ssmt_ptrq_create(4096)
        garbage = ssmt_ptrq_create(8192)
        voices = (0..<maxVoices).map { _ in Voice(maxOutputs: maxOutputs) }
        patch = Array(0..<maxOutputs)
        bus = .allocate(capacity: maxOutputs * busFrames)
        bus.initialize(repeating: 0, count: maxOutputs * busFrames)
        scratchIndex = .allocate(capacity: busFrames)
        scratchIndex.initialize(repeating: 0, count: busFrames)
        scratchFrac = .allocate(capacity: busFrames)
        scratchFrac.initialize(repeating: 0, count: busFrames)
        scratchEnv = .allocate(capacity: busFrames)
        scratchEnv.initialize(repeating: 0, count: busFrames)
        startDeclick = sampleRate * 0.002
        peaks = (0..<maxOutputs).map { _ in AtomicFloat(0) }
        declick = Int64(sampleRate * 0.003)
    }

    deinit {
        while let p = ssmt_ptrq_pop(inbox) { Unmanaged<MixerCommand>.fromOpaque(p).release() }
        collectGarbage()
        ssmt_ptrq_destroy(inbox)
        ssmt_ptrq_destroy(garbage)
        bus.deallocate()
        scratchIndex.deallocate()
        scratchFrac.deallocate()
        scratchEnv.deallocate()
    }

    // MARK: Control thread

    public func send(_ op: MixerOp) {
        let cmd = MixerCommand(op: op, maxOutputs: maxOutputs)
        let p = Unmanaged.passRetained(cmd).toOpaque()
        if !ssmt_ptrq_push(inbox, p) {
            Unmanaged<MixerCommand>.fromOpaque(p).release()
            droppedCommands.increment()
        }
    }

    /// Releases command boxes and clips handed back by the audio thread.
    public func collectGarbage() {
        while let p = ssmt_ptrq_pop(garbage) { Unmanaged<AnyObject>.fromOpaque(p).release() }
    }

    /// Reads and resets the output peaks (linear).
    public func takePeaks() -> [Float] {
        peaks.map { p in let v = p.value; p.value = 0; return v }
    }

    // MARK: Audio thread

    @inline(__always) private func discard(_ obj: AnyObject?) {
        guard let obj else { return }
        // +1 for the garbage queue so the last release never happens on this thread.
        let p = Unmanaged.passRetained(obj).toOpaque()
        if !ssmt_ptrq_push(garbage, p) {
            // Queue full: keep the object alive rather than freeing here (tiny leak, never a glitch).
            return
        }
    }

    private func voice(_ id: UUID) -> Voice? {
        for v in voices where v.active && v.id == id { return v }
        return nil
    }

    private func free(_ v: Voice) {
        v.active = false
        discard(v.command); v.command = nil
        v.clip = nil
        v.setup = nil
    }

    private func apply(_ cmd: MixerCommand) {
        switch cmd.op {
        case let .start(id, clip, setup, at):
            if let old = voice(id) { free(old) }
            guard let v = voices.first(where: { !$0.active }) else { return }
            v.id = id
            v.active = true
            v.command = cmd // released through `free` → garbage queue
            v.clip = clip
            v.setup = setup
            v.startFrame = at
            v.played = setup.startPlayed
            v.map = setup.map
            v.paused = false
            v.pauseAt = .max; v.resumeAt = .max; v.devampAt = .max; v.stopAt = .max
            v.main = LevelRamp(setup.levelDB)
            v.stopEnv = LevelRamp(0)
            for o in 0..<maxOutputs {
                v.outputs[o] = LevelRamp(o < setup.outputLevelsDB.count ? setup.outputLevelsDB[o] : 0)
            }
            return
        case let .stop(id, at, fade):
            if let v = voice(id) { v.stopAt = min(v.stopAt, at); v.stopFade = max(fade, declick) }
        case let .pause(id, at):
            if let v = voice(id) { v.pauseAt = at; v.resumeAt = .max }
        case let .resume(id, at):
            if let v = voice(id) { v.resumeAt = at }
        case let .fade(id, at, frames, curve, level, outs):
            if let v = voice(id) {
                if let level { v.main.set(to: level, at: at, frames: frames, curve: curve) }
                for (o, db) in outs.enumerated() where o < maxOutputs {
                    if let db { v.outputs[o].set(to: db, at: at, frames: frames, curve: curve) }
                }
            }
        case let .holdLevels(id, at):
            if let v = voice(id) {
                v.main.hold(at: at)
                for o in 0..<maxOutputs { v.outputs[o].hold(at: at) }
            }
        case let .devamp(id, at):
            if let v = voice(id) { v.devampAt = at }
        case let .stopAll(at, fade):
            for v in voices where v.active { v.stopAt = min(v.stopAt, at); v.stopFade = max(fade, declick) }
        case let .patch(p):
            for o in 0..<maxOutputs { patch[o] = o < p.count ? p[o] : -1 }
        }
        discard(cmd)
    }

    /// Renders `frames` frames into planar device channels (`outputs[ch]`, `channelCount` channels).
    public func render(_ outputs: UnsafePointer<UnsafeMutablePointer<Float>>, channelCount: Int, frames: Int) {
        while let p = ssmt_ptrq_pop(inbox) {
            let cmd = Unmanaged<MixerCommand>.fromOpaque(p).takeRetainedValue()
            apply(cmd)
        }
        for ch in 0..<channelCount { outputs[ch].update(repeating: 0, count: frames) }
        var done = 0
        while done < frames {
            let n = min(busFrames, frames - done)
            renderBlock(outputs, channelCount: channelCount, offset: done, frames: n)
            done += n
        }
    }

    private func renderBlock(_ outputs: UnsafePointer<UnsafeMutablePointer<Float>>, channelCount: Int, offset: Int, frames n: Int) {
        let blockStart = Int64(framesRendered.value)
        let blockEnd = blockStart + Int64(n)
        bus.update(repeating: 0, count: maxOutputs * busFrames)
        for v in voices where v.active {
            renderVoice(v, from: blockStart, to: blockEnd)
        }
        // Patch show outputs to device channels and meter them.
        for o in 0..<maxOutputs {
            let src = bus + o * busFrames
            var peak: Float = 0
            for i in 0..<n { peak = max(peak, abs(src[i])) }
            if peak > 0 { peaks[o].storeMax(peak) }
            let ch = patch[o]
            guard ch >= 0, ch < channelCount else { continue }
            let dst = outputs[ch] + offset
            for i in 0..<n { dst[i] += src[i] }
        }
        framesRendered.increment(by: UInt64(n))
    }

    private func renderVoice(_ v: Voice, from b0: Int64, to b1: Int64) {
        guard let clip = v.clip, let setup = v.setup, let cmd = v.command else { free(v); return }
        // Late start (command arrived after its frame): catch up so timing matches the schedule.
        if v.startFrame >= b1 { return }
        if v.startFrame < b0 && v.played == 0 && !v.paused {
            v.played = Double(b0 - v.startFrame) * setup.rate
        }
        // Pause / resume / devamp / stop boundaries inside this block are handled by splitting.
        var f = max(b0, v.startFrame)
        while f < b1 {
            var next = b1
            if v.pauseAt > f && v.pauseAt < next { next = v.pauseAt }
            if v.resumeAt > f && v.resumeAt < next { next = v.resumeAt }
            if v.devampAt > f && v.devampAt < next { next = v.devampAt }
            if v.stopAt > f && v.stopAt < next { next = v.stopAt }
            if v.devampAt <= f {
                v.map = v.map.devamped(at: v.played)
                v.devampAt = .max
            }
            if v.pauseAt <= f { v.paused = true; v.pauseAt = .max }
            if v.resumeAt <= f { v.paused = false; v.resumeAt = .max }
            if v.stopAt <= f && v.stopEnv.length == 0 && v.stopEnv.toDB == 0 {
                if v.paused { free(v); return }
                v.stopEnv.set(to: showSilenceDB, at: v.stopAt, frames: v.stopFade, curve: .sCurve)
            }
            if v.stopAt != .max && f >= v.stopAt + v.stopFade { free(v); return }
            var segEnd = next
            if v.stopAt != .max { segEnd = min(segEnd, v.stopAt + v.stopFade) }
            if !v.paused {
                if !mix(v, clip: clip, setup: setup, crosspoints: cmd.crosspoints, from: f, to: segEnd, blockStart: b0) {
                    free(v); return
                }
            }
            f = segEnd
        }
    }

    /// Mixes one segment; returns false when the voice has finished.
    /// Positions and the envelope are computed once per segment and shared by every channel and output.
    private func mix(_ v: Voice, clip: AudioClip, setup: VoiceSetup, crosspoints xp: [Float],
                     from f0: Int64, to f1: Int64, blockStart: Int64) -> Bool {
        let n = Int(f1 - f0)
        guard n > 0, n <= busFrames else { return true }
        let map = v.map
        let total = map.total ?? .infinity
        let rate = setup.rate
        var fadeIn = Double(setup.fadeInFrames)
        if fadeIn < startDeclick && map.regionStart > 0 { fadeIn = startDeclick }
        let fadeOut = Double(setup.fadeOutFrames)
        let main0 = v.main.gain(at: f0) * v.stopEnv.gain(at: f0)
        let main1 = v.main.gain(at: f1) * v.stopEnv.gain(at: f1)
        let last = clip.frames - 1
        guard last >= 0 else { return false }

        // Positions, interpolation and envelope (fades × main level ramp) for the segment.
        var pos = v.played
        var count = 0
        let invN = 1.0 / Double(n)
        while count < n && pos < total {
            let idx = map.position(pos)
            let i0 = min(Int(idx), last)
            scratchIndex[count] = i0
            scratchFrac[count] = i0 < last ? Float(idx - Double(i0)) : 0
            var env = 1.0
            if fadeIn > 0 && pos < fadeIn { env = pos / fadeIn }
            if fadeOut > 0 && total.isFinite && pos > total - fadeOut { env = min(env, max(0, (total - pos) / fadeOut)) }
            scratchEnv[count] = Float(env * (main0 + (main1 - main0) * Double(count) * invN))
            pos += rate
            count += 1
        }

        let busOffset = Int(f0 - blockStart)
        let chCount = clip.channelCount
        if count > 0 && (main0 > 0 || main1 > 0) {
            for o in 0..<maxOutputs {
                let og0 = v.outputs[o].gain(at: f0), og1 = v.outputs[o].gain(at: f1)
                if og0 == 0 && og1 == 0 { continue }
                let dst = bus + o * busFrames + busOffset
                let ogStep = Float((og1 - og0) * invN)
                for c in 0..<chCount {
                    let x = xp[c * maxOutputs + o]
                    if x == 0 { continue }
                    let src = clip.samples + c * clip.frames
                    var og = Float(og0) * x
                    let step = ogStep * x
                    for i in 0..<count {
                        let i0 = scratchIndex[i]
                        var s = src[i0]
                        let fr = scratchFrac[i]
                        if fr != 0 { s += (src[i0 + 1] - s) * fr }
                        dst[i] += s * scratchEnv[i] * og
                        og += step
                    }
                }
            }
        }
        v.played += Double(n) * rate
        return v.played < total
    }
}
