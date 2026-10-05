import Foundation
import SSMTCore

// Qtrl's playback (App/SSMT/Show/ShowStore.swift `PlaybackCore`, `restartOutput` and App/SSMT/Show/ShowAudioOutput.swift
// `ClipCache`): SSMTCore's ShowEngine schedules every action on the mixer's sample clock and ShowMixer renders the
// show into the "show" stream of the audio bridge (Modules/AudioIO.swift). Audio files are decoded by the interface
// (Web Audio, at the engine's sample rate) into planar Float32 cache files, which are memory-mapped here as on the Mac.

/// Playback state and meters as the interface shows them (App's `ShowLive`).
struct ShowLiveState {
    var snapshot = ShowSnapshot.empty
    var meters: [Float] = []
    /// Outputs that clipped in the last 1.5 s.
    var clipping: [Bool] = []
    var clipUntil: [Int: Date] = [:]
    /// Send a "showLive" event on the next snapshot even if nothing played.
    var forceEmit = true
    var sentSnapshot: ShowSnapshot?
    var sentMeters: [Float] = []
    var sentClipping: [Bool] = []
}

/// Largest block (frames) the audio bridge asked for at once; the engine schedules further ahead than that.
final class ShowNeed: @unchecked Sendable {
    private let lock = NSLock()
    private var largest = 0
    func note(_ frames: Int) { lock.lock(); if frames > largest { largest = frames }; lock.unlock() }
    var max: Int { lock.lock(); defer { lock.unlock() }; return largest }
}

/// Planar buffers for one render call, grown when the bridge asks for more.
final class ShowPlanarScratch: @unchecked Sendable {
    private(set) var pointers: [UnsafeMutablePointer<Float>] = []
    private var capacity = 0

    func ensure(channels: Int, frames: Int) {
        if pointers.count >= channels && capacity >= frames { return }
        pointers.forEach { $0.deallocate() }
        capacity = max(frames, capacity, 4096)
        pointers = (0..<max(channels, pointers.count)).map { _ in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
            p.initialize(repeating: 0, count: capacity)
            return p
        }
    }

    deinit { pointers.forEach { $0.deallocate() } }
}

/// Engine, mixer and clock (the Mac's `PlaybackCore`), confined to the engine's main loop.
final class ShowPlaybackCore {
    var engine: ShowEngine?
    var mixer: ShowMixer?
    var sampleRate: Double = 48000
    /// Sample rate of the backup clock (used while no audio output runs).
    var clockRate: Double = 48000
    private let clockStart = Date()
    var ticks = 0
    let clips = ShowClipStore()
    let need = ShowNeed()
    let scratch = ShowPlanarScratch()
    /// What the audio bridge's "show" stream was when the engine was made.
    var outputOpen = false
    var outputRate: Double = 0

    /// Show clock: the mixer's sample counter; without an output the system clock keeps OSC cues, waits and
    /// auto-continue running.
    var now: Int64 {
        if let m = mixer { return Int64(m.framesRendered.value) }
        return Int64(Date().timeIntervalSince(clockStart) * clockRate)
    }

    /// How far ahead actions are scheduled: as on the Mac (30 ms or more), and at least twice the largest block the
    /// bridge renders at once plus a tick of the engine's loop.
    var lookahead: Int64 {
        max(Int64(clockRate * 0.03), Int64(need.max) * 2 + Int64(clockRate * 0.025))
    }
}

/// Decoded audio by resolved path (the Mac's `ClipCache`): memory-mapped planar Float32 cache files, one per file and
/// sample rate. A file not decoded yet is asked of the interface ("showDecode" event, "showDecoded" command).
final class ShowClipStore {
    private var clips: [String: AudioClip] = [:]
    private var failed: [String: String] = [:]
    /// Files the interface is decoding, and at what rate.
    private var inFlight: [String: Double] = [:]
    var folder = URL(fileURLWithPath: "Cache/Audio", isDirectory: true)

    var loading: Int { inFlight.count }

    func cached(_ path: String, sampleRate: Double) -> AudioClip? {
        guard let c = clips[path], c.sampleRate == sampleRate else { return nil }
        return c
    }

    func failure(_ path: String) -> String? { failed[path] }

    func forget(except keep: Set<String>) {
        clips = clips.filter { keep.contains($0.key) }
    }

    /// The clip when it is ready (decoded earlier: mapped from the cache); otherwise the interface is asked to decode
    /// it and nil is returned. Never blocks on decoding.
    @discardableResult
    func load(_ path: String, sampleRate: Double) -> AudioClip? {
        if let c = cached(path, sampleRate: sampleRate) { return c }
        if inFlight[path] == sampleRate { return nil }
        guard FileManager.default.fileExists(atPath: path), let key = cacheKey(path, sampleRate: sampleRate) else { return nil }
        // Already decoded: map it.
        for ch in 1...16 {
            let url = folder.appendingPathComponent(key + "-\(ch)ch.f32")
            if FileManager.default.fileExists(atPath: url.path),
               let data = try? NSData(contentsOf: url, options: .alwaysMapped),
               let clip = AudioClip(sampleRate: sampleRate, channelCount: ch, mapped: data) {
                clips[path] = clip
                failed[path] = nil
                return clip
            }
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        inFlight[path] = sampleRate
        Out.emit("showDecode", ["path": path, "sampleRate": sampleRate,
                                "out": ShowPaths.native(folder.appendingPathComponent(key + ".part"))])
        return nil
    }

    /// The interface has written the decoded file (`channels` planar Float32 channels) or reports why it could not.
    func finish(_ path: String, sampleRate: Double, channels: Int, error: String?) -> AudioClip? {
        inFlight[path] = nil
        if let error {
            failed[path] = error
            return nil
        }
        guard channels > 0, let key = cacheKey(path, sampleRate: sampleRate) else {
            failed[path] = "no audio"
            return nil
        }
        let part = folder.appendingPathComponent(key + ".part")
        let dest = folder.appendingPathComponent(key + "-\(channels)ch.f32")
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: part, to: dest)
            let data = try NSData(contentsOf: dest, options: .alwaysMapped)
            guard let clip = AudioClip(sampleRate: sampleRate, channelCount: channels, mapped: data) else {
                failed[path] = "corrupt decode"
                return nil
            }
            clips[path] = clip
            failed[path] = nil
            return clip
        } catch {
            failed[path] = "\(error)"
            return nil
        }
    }

    /// Cache file name for a source: depends on path, size, modification date and sample rate (as on the Mac).
    private func cacheKey(_ path: String, sampleRate: Double) -> String? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let size = (a[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        var h: UInt64 = 1469598103934665603 // FNV-1a
        for b in "\(path)|\(size)|\(mtime)|\(Int(sampleRate))".utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return String(h, radix: 16)
    }
}

extension ShowModule {
    static let auditionVoice = UUID()

    // MARK: Audio output

    /// The bridge's "show" stream opened, closed or changed its rate: the engine is made again for it.
    func pollOutput() {
        let s = AudioBridge.shared.stream("show")
        let open = s.isOpen && s.sampleRate > 0
        if open != playback.outputOpen || (open && s.sampleRate != playback.outputRate) { restartOutput() }
    }

    /// (Re)creates the mixer on the show stream and a new engine at its sample rate.
    func restartOutput() {
        let core = playback
        let stream = AudioBridge.shared.stream("show")
        stream.setSource(nil)
        core.engine = nil
        let open = stream.isOpen && stream.sampleRate > 0
        let sr = open ? stream.sampleRate : 48000
        core.outputOpen = open
        core.outputRate = stream.sampleRate
        core.sampleRate = sr
        core.clockRate = sr
        let mixer: ShowMixer? = open ? ShowMixer(sampleRate: sr, maxOutputs: 64) : nil
        core.mixer = mixer
        mixer?.send(.patch(doc.outputs.map { $0.deviceChannel ?? -1 }))
        let clips = core.clips
        let engine = ShowEngine(document: doc, sampleRate: sr, lookahead: core.lookahead,
                                send: { op in mixer?.send(op) },
                                clipProvider: { [weak self] cue in
                                    guard let self, let f = cue.audio?.file, !f.isEmpty else { return nil }
                                    // Never decodes here: a file not ready yet is reported, and prepared meanwhile.
                                    return clips.load(ShowPaths.resolve(f, show: self.filePath), sampleRate: sr)
                                })
        engine.clipPending = { [weak self] cue in
            guard let self, let f = cue.audio?.file, !f.isEmpty else { return false }
            let path = ShowPaths.resolve(f, show: self.filePath)
            return FileManager.default.fileExists(atPath: path) && clips.failure(path) == nil
        }
        engine.oscSend = { [weak self] device, message in self?.oscSend(message, to: device) }
        engine.preload = { [weak self] cue in
            guard let self, let f = cue.audio?.file else { return }
            clips.load(ShowPaths.resolve(f, show: self.filePath), sampleRate: sr)?.prefetch(from: 0, count: Int(sr * 10))
        }
        engine.documentChanged = { [weak self] newDoc in self?.pendingDocument = newDoc }
        if let lid = listID { engine.selectList(lid) }
        core.engine = engine
        if let mixer {
            let scratch = core.scratch
            let need = core.need
            stream.setSource { [weak self] out, frames, channels in
                guard frames > 0, channels > 0 else { return }
                need.note(frames)
                // Rendered on the engine's loop: everything due in this block is scheduled first.
                if Thread.isMainThread, let self, let e = self.playback.engine { e.advance(to: self.playback.now) }
                scratch.ensure(channels: channels, frames: frames)
                scratch.pointers.withUnsafeBufferPointer { mixer.render($0.baseAddress!, channelCount: channels, frames: frames) }
                if out.count != frames * channels { out = [Float](repeating: 0, count: frames * channels) }
                for c in 0..<channels {
                    let p = scratch.pointers[c]
                    var i = c
                    for f in 0..<frames {
                        out[i] = p[f]
                        i += channels
                    }
                }
            }
        }
        dirty = true
        live.forceEmit = true
        refreshFiles()
    }

    /// Every loop of the engine (≈ 50 a second): due actions, garbage, read-ahead, the playback snapshot.
    func playbackTick(_ date: Date) {
        guard let e = playback.engine else { return }
        let now = playback.now
        e.lookahead = playback.lookahead
        e.advance(to: now)
        playback.mixer?.collectGarbage()
        playback.ticks += 1
        if playback.ticks % 5 == 0 { e.prefetch(now: now) }
        guard playback.ticks % 2 == 0 else { return }
        if previewing {
            if live.forceEmit { emitLive() }
            return
        }
        apply(e.snapshot(now: now), peaks: playback.mixer?.takePeaks() ?? [], date: date)
    }

    private func apply(_ snap: ShowSnapshot, peaks: [Float], date: Date) {
        live.snapshot = snap
        let used = Array(peaks.prefix(doc.outputs.count))
        // Ballistics as on a console: rises at once, falls about 25 dB/s; clipping (≥ 0 dBFS, the output really
        // overloads) stays lit 1.5 s.
        var shown = live.meters
        if shown.count != used.count { shown = used }
        for i in used.indices {
            let fall = shown[i] * Float(pow(10, -1.0 / 20))   // −1 dB per update (25 a second)
            shown[i] = max(used[i], fall < 1e-5 ? 0 : fall)
            if used[i] >= 1 { live.clipUntil[i] = date.addingTimeInterval(1.5) }
        }
        live.meters = shown
        live.clipping = used.indices.map { (live.clipUntil[$0] ?? .distantPast) > date }
        if let lid = snap.listID, lid != listID, doc.lists.contains(where: { $0.id == lid }) { listID = lid }
        if live.forceEmit || live.sentSnapshot != snap || live.sentMeters != live.meters || live.sentClipping != live.clipping {
            emitLive()
        }
    }

    // MARK: Audition (waveform editor)

    /// Plays a cue's file from `from` (file seconds) for `length` seconds (nil = to the region end).
    func auditionCue(_ cue: Cue, from: Double, length: Double?) {
        guard let path = resolvedPath(cue), let a = cue.audio, let fileLen = fileLength(cue) else { return }
        let end = min(fileLen, length.map { from + $0 } ?? (a.end ?? fileLen))
        guard end > from else { return }
        if let mixer = playback.mixer {
            let sr = mixer.sampleRate
            if let clip = playback.clips.cached(path, sampleRate: sr) ?? playback.clips.load(path, sampleRate: sr),
               let setup = ShowEngine.voiceSetup(cue, clip: clip, outputs: doc.outputs.count, from: from, length: end - from) {
                mixer.send(.start(Self.auditionVoice, clip: clip, setup: setup, at: playback.now + Int64(sr * 0.03)))
            }
        }
        let rate = max(0.05, a.rate)
        audition = ShowAudition(cue: cue.id, from: from, length: end - from, rate: rate,
                                endsAt: Date().addingTimeInterval((end - from) / rate + 0.1))
        dirty = true
    }

    func stopAudition() {
        if let mixer = playback.mixer {
            mixer.send(.stop(Self.auditionVoice, at: playback.now, fadeFrames: Int64(mixer.sampleRate * 0.01)))
        }
        audition = nil
        dirty = true
    }

    /// Sets start and end at the first and last sound above −50 dBFS.
    func trimSilence(_ cueID: UUID) {
        guard let cue = doc.cue(cueID), let path = resolvedPath(cue) else { return }
        let sr = playback.sampleRate
        guard let clip = playback.clips.cached(path, sampleRate: sr) ?? playback.clips.load(path, sampleRate: sr) else {
            if FileManager.default.fileExists(atPath: path) { pendingTrims[path, default: []].append(cueID) }
            return
        }
        guard let b = ShowWaveform.soundBounds(clip) else { return }
        let duration = clip.duration
        edit { d in
            d.updateCue(cueID) { c in
                c.audio?.start = (b.start * 1000).rounded() / 1000
                c.audio?.end = b.end >= duration - 0.001 ? nil : (b.end * 1000).rounded() / 1000
            }
        }
    }

    /// Peaks of a file section (file seconds) for the waveform editor's zoomed view.
    func waveSlice(_ c: Command) {
        guard let path = c.str("path"), let clip = playback.clips.cached(path, sampleRate: playback.sampleRate),
              let peaks = ShowWaveform.slice(clip, from: c.double("from") ?? 0, to: c.double("to") ?? 0,
                                             buckets: min(4000, c.int("buckets") ?? 0)) else { return }
        Out.emit("showWaveSlice", ["key": c.str("key") ?? "", "peaks": peaks.map { (Double($0) * 1000).rounded() / 1000 }])
    }

    /// The integrated fade's volume line (dB along 0…1 of its span) for drawing, also while a point is dragged.
    func envelopeSample(_ c: Command) {
        guard let env = c.decode(VolumeEnvelope.self, "envelope") else { return }
        let n = max(2, min(2000, c.int("n") ?? 400))
        let db = (0...n).map { env.db(at: Double($0) / Double(n)) }
        Out.emit("showEnv", ["key": c.str("key") ?? "", "db": db])
    }

    // MARK: Decoding (interface → cache file)

    func decoded(_ c: Command) {
        guard let path = c.str("path") else { return }
        let sr = c.double("sampleRate") ?? 0
        let clip = playback.clips.finish(path, sampleRate: sr, channels: c.int("channels") ?? 0, error: c.str("error"))
        if let clip, sr == playback.sampleRate {
            clipReady(path, clip)
        } else if clip == nil, let why = playback.clips.failure(path) {
            unreadableFiles[path] = why
        }
        dirty = true
    }
}
