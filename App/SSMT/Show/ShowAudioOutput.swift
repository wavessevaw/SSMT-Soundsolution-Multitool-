import AudioToolbox
import AVFoundation
import CoreMedia
import CoreAudio
import Foundation
import SSMTAudio
import SSMTCore

/// Audio output of Qtrl: an AVAudioEngine source node on the chosen interface that pulls
/// every channel from the `ShowMixer`.
final class ShowAudioOutput {
    let engine = AVAudioEngine()
    let mixer: ShowMixer
    let sampleRate: Double
    let channelCount: Int
    let deviceName: String
    private var source: AVAudioSourceNode?
    private var configObserver: NSObjectProtocol?
    /// Called (on the main queue) when the output was interrupted: nil = recovered, text = still failing.
    var onInterruption: ((String?) -> Void)?
    /// Device I/O buffer actually in use (frames).
    private(set) var bufferFrames: Int = 512
    private let channelPointers: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    private let silence: UnsafeMutablePointer<Float>
    private static let maxFrames = 8192

    enum OutputError: Error, CustomStringConvertible {
        case device(String), format, start(Error)
        var description: String {
            switch self {
            case let .device(name): return "Cannot use \(name)"
            case .format: return "Unsupported output format"
            case let .start(e): return "\(e.localizedDescription)"
            }
        }
    }

    init(deviceUID: String?, maxOutputs: Int, bufferFrames requested: Int = 512) throws {
        let output = engine.outputNode
        var name = "System output"
        var deviceID: AudioDeviceID? = DeviceCatalog.defaultDevice(input: false)
        if let uid = deviceUID, let info = DeviceCatalog.device(uid: uid), info.outputChannels > 0 {
            var id = info.id
            deviceID = info.id
            guard let unit = output.audioUnit,
                  AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                       &id, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else {
                throw OutputError.device(info.name)
            }
            name = info.name
        } else if let id = DeviceCatalog.defaultDevice(input: false), let info = DeviceCatalog.info(for: id) {
            name = info.name
        }
        deviceName = name
        if let deviceID { bufferFrames = Self.setBufferFrames(deviceID, requested) }
        let hw = output.outputFormat(forBus: 0)
        sampleRate = hw.sampleRate > 0 ? hw.sampleRate : 48000
        channelCount = max(1, Int(hw.channelCount))
        mixer = ShowMixer(sampleRate: sampleRate, maxOutputs: maxOutputs)
        channelPointers = .allocate(capacity: channelCount)
        silence = .allocate(capacity: Self.maxFrames)
        silence.initialize(repeating: 0, count: Self.maxFrames)

        let format: AVAudioFormat?
        if channelCount <= 2 {
            format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channelCount))
        } else if let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channelCount)) {
            format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channelLayout: layout)
        } else {
            format = nil
        }
        guard let format else { throw OutputError.format }

        let mixer = self.mixer
        let pointers = channelPointers
        let count = channelCount
        let silence = self.silence
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, abl -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            let frames = Int(frameCount)
            for c in 0..<count {
                if c < buffers.count, let data = buffers[c].mData {
                    pointers[c] = data.assumingMemoryBound(to: Float.self)
                } else {
                    pointers[c] = silence // never more channels than buffers in practice
                }
            }
            mixer.render(UnsafePointer(pointers), channelCount: min(count, buffers.count), frames: min(frames, ShowAudioOutput.maxFrames))
            return noErr
        }
        source = node
        engine.attach(node)
        engine.connect(node, to: output, format: format)
        engine.prepare()
        do { try engine.start() } catch { throw OutputError.start(error) }
        // Device reconfigured (sample rate, unplug/replug, another app): restart at once.
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                                queue: .main) { [weak self] _ in self?.recover() }
    }

    private func recover(attempt: Int = 0) {
        guard source != nil else { return }
        do {
            engine.prepare()
            try engine.start()
            onInterruption?(nil)
        } catch {
            onInterruption?(error.localizedDescription)
            // Keep trying for a while (device being replugged).
            if attempt < 120 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.recover(attempt: attempt + 1) }
            }
        }
    }

    /// Asks the device for an I/O buffer size; returns the size in use.
    private static func setBufferFrames(_ device: AudioDeviceID, _ frames: Int) -> Int {
        var value = UInt32(frames)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        var actual: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &actual) == noErr, actual > 0 { return Int(actual) }
        return frames
    }

    func stop() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine.stop()
        if let source { engine.detach(source) }
        source = nil
    }

    deinit {
        stop()
        channelPointers.deallocate()
        silence.deallocate()
    }
}

/// Audio files for the show. Each file is decoded once (any format Core Audio or AVFoundation
/// reads, including the sound of video files) into a planar Float32 cache file at the output sample
/// rate, then memory-mapped: RAM use stays small and opening a show again is instant. Thread-safe.
final class ClipCache: @unchecked Sendable {
    private var clips: [String: AudioClip] = [:]
    private var failed: [String: String] = [:]
    private var inFlight: Set<String> = []
    private let lock = NSLock()

    static let folder: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SSMT/Audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    /// Decoded audio resident in memory (owned clips only; mapped files are paged by the system).
    var totalBytes: Int { lock.lock(); defer { lock.unlock() }; return clips.values.filter { !$0.isMapped }.reduce(0) { $0 + $1.bytes } }
    var diskBytes: Int { lock.lock(); defer { lock.unlock() }; return clips.values.filter(\.isMapped).reduce(0) { $0 + $1.bytes } }

    func cached(_ path: String, sampleRate: Double) -> AudioClip? {
        lock.lock(); defer { lock.unlock() }
        guard let c = clips[path], c.sampleRate == sampleRate else { return nil }
        return c
    }

    func failure(_ path: String) -> String? { lock.lock(); defer { lock.unlock() }; return failed[path] }

    func forget(except keep: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        clips = clips.filter { keep.contains($0.key) }
    }

    /// Loads (or returns the cached) clip. Slow the first time a file is seen: call off the main
    /// thread and never on the playback queue.
    @discardableResult
    func load(_ path: String, sampleRate: Double) -> AudioClip? {
        lock.lock()
        // While a file is being decoded, its (growing) clip already plays, but only the decoder returns it.
        if inFlight.contains(path) { lock.unlock(); return nil }
        if let c = clips[path], c.sampleRate == sampleRate { lock.unlock(); return c }
        inFlight.insert(path)
        lock.unlock()
        defer { lock.lock(); inFlight.remove(path); lock.unlock() }
        do {
            // The cue can play as soon as the first second or so is decoded; the rest is decoded
            // far faster than it plays, into the same memory-mapped file.
            let clip = try Self.open(URL(fileURLWithPath: path), sampleRate: sampleRate) { [weak self] early in
                guard let self else { return }
                self.lock.lock(); self.clips[path] = early; self.lock.unlock()
            }
            lock.lock(); clips[path] = clip; failed[path] = nil; lock.unlock()
            return clip
        } catch {
            lock.lock(); failed[path] = error.localizedDescription; clips[path] = nil; lock.unlock()
            return nil
        }
    }

    // MARK: Cache files

    /// Cache file for a source: depends on path, size, modification date and sample rate.
    private static func cacheURL(for url: URL, sampleRate: Double, channels: Int) -> URL? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let size = (a[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        var h: UInt64 = 1469598103934665603 // FNV-1a
        for b in "\(url.path)|\(size)|\(mtime)|\(Int(sampleRate))".utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return folder.appendingPathComponent(String(h, radix: 16) + "-\(channels)ch.f32")
    }

    /// `started` receives a clip of the whole file as soon as its first block is decoded (the rest fills in).
    static func open(_ url: URL, sampleRate: Double, started: ((AudioClip) -> Void)? = nil) throws -> AudioClip {
        // Already decoded: map it.
        for ch in 1...16 {
            if let c = cacheURL(for: url, sampleRate: sampleRate, channels: ch), FileManager.default.fileExists(atPath: c.path),
               let data = try? NSData(contentsOf: c, options: .alwaysMapped),
               let clip = AudioClip(sampleRate: sampleRate, channelCount: ch, mapped: data) {
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: c.path)
                return clip
            }
        }
        let tmp = folder.appendingPathComponent(UUID().uuidString + ".part")
        defer { try? FileManager.default.removeItem(at: tmp) }
        var published = false
        let early: (PlanarWriter) -> Void = { w in
            // A shared mapping (not a copy): the rest of the file, written after this, is seen by the player.
            guard let started, let data = sharedMapping(of: w.url),
                  let clip = AudioClip(sampleRate: sampleRate, channelCount: w.channels, mapped: data) else { return }
            published = true
            started(clip)
        }
        let channels: Int
        do {
            channels = try decodeWithAudioFile(url, sampleRate: sampleRate, to: tmp, started: early)
        } catch {
            // A failure after playback started is final; otherwise try the AVFoundation reader
            // (containers AVAudioFile cannot read: video files, some streams).
            if published { throw error }
            channels = try decodeWithAssetReader(url, sampleRate: sampleRate, to: tmp, started: early)
        }
        guard let dest = cacheURL(for: url, sampleRate: sampleRate, channels: channels) else { throw CocoaError(.fileReadUnknown) }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        let data = try NSData(contentsOf: dest, options: .alwaysMapped)
        guard let clip = AudioClip(sampleRate: sampleRate, channelCount: channels, mapped: data) else { throw CocoaError(.fileReadCorruptFile) }
        return clip
    }

    /// Maps a file with MAP_SHARED (read-only), so later writes to it are visible through the mapping.
    private static func sharedMapping(of url: URL) -> NSData? {
        let fd = Darwin.open(url.path, O_RDONLY)   // `open` alone would be ClipCache.open
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = Darwin.stat()
        guard fstat(fd, &st) == 0, st.st_size > 0 else { return nil }
        let length = Int(st.st_size)
        guard let p = mmap(nil, length, PROT_READ, MAP_SHARED, fd, 0), p != MAP_FAILED else { return nil }
        return NSData(bytesNoCopy: p, length: length, deallocator: { ptr, len in _ = munmap(ptr, len) })
    }

    /// Planar writer: channel c of frame f lives at (c × frames + f) × 4 bytes.
    private final class PlanarWriter {
        let handle: FileHandle
        let url: URL
        let channels: Int
        let frames: Int
        var written = 0
        /// Called once, after the first block is on disk (the file already has its full, zero-filled size).
        var onFirstBlock: ((PlanarWriter) -> Void)?

        init(url: URL, channels: Int, frames: Int) throws {
            self.url = url
            FileManager.default.createFile(atPath: url.path, contents: nil)
            handle = try FileHandle(forWritingTo: url)
            self.channels = channels
            self.frames = frames
            try handle.truncate(atOffset: UInt64(channels * frames * 4)) // zero-filled (silence)
        }

        /// Appends `count` frames given one pointer per channel.
        func append(_ data: (Int) -> UnsafePointer<Float>, count: Int) throws {
            let n = min(count, frames - written)
            guard n > 0 else { return }
            for c in 0..<channels {
                try handle.seek(toOffset: UInt64((c * frames + written) * 4))
                try handle.write(contentsOf: Data(bytes: data(c), count: n * 4))
            }
            written += n
            if let f = onFirstBlock {
                onFirstBlock = nil
                f(self)
            }
        }

        func close() throws { try handle.close() }
    }

    private static func decodeWithAudioFile(_ url: URL, sampleRate: Double, to out: URL, started: ((PlanarWriter) -> Void)?) throws -> Int {
        let file = try AVAudioFile(forReading: url)
        let inFormat = file.processingFormat
        let channels = Int(inFormat.channelCount)
        guard channels > 0, file.length > 0 else { throw CocoaError(.fileReadCorruptFile) }
        let ratio = sampleRate / inFormat.sampleRate
        let frames = Int((Double(file.length) * ratio).rounded(.up))
        let writer = try PlanarWriter(url: out, channels: channels, frames: frames)
        writer.onFirstBlock = started
        defer { try? writer.close() }
        let chunk: AVAudioFrameCount = 65536
        guard let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: chunk) else { throw CocoaError(.fileReadCorruptFile) }
        if abs(ratio - 1) < 1e-9 {
            while file.framePosition < file.length {
                try file.read(into: input, frameCount: chunk)
                guard input.frameLength > 0, let d = input.floatChannelData else { break }
                try writer.append({ UnsafePointer(d[$0]) }, count: Int(input.frameLength))
            }
            return channels
        }
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                            channels: inFormat.channelCount, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat),
              let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(Double(chunk) * ratio) + 1024) else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        var readError: Error?
        var finished = false
        while !finished {
            output.frameLength = 0
            var convError: NSError?
            let status = converter.convert(to: output, error: &convError) { _, outStatus in
                if file.framePosition >= file.length { outStatus.pointee = .endOfStream; return nil }
                do { try file.read(into: input, frameCount: chunk) } catch { readError = error; outStatus.pointee = .endOfStream; return nil }
                outStatus.pointee = .haveData
                return input
            }
            if let readError { throw readError }
            if status == .error { throw convError ?? CocoaError(.fileReadCorruptFile) }
            if output.frameLength > 0, let d = output.floatChannelData {
                try writer.append({ UnsafePointer(d[$0]) }, count: Int(output.frameLength))
            }
            if status == .endOfStream || (status == .inputRanDry && file.framePosition >= file.length) { finished = true }
        }
        return channels
    }

    private static func decodeWithAssetReader(_ url: URL, sampleRate: Double, to out: URL, started: ((PlanarWriter) -> Void)?) throws -> Int {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first else { throw CocoaError(.fileReadCorruptFile) }
        let reader = try AVAssetReader(asset: asset)
        let desc = track.formatDescriptions.first.map { $0 as! CMFormatDescription }
        let asbd = desc.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        let channels = max(1, Int(asbd?.mChannelsPerFrame ?? 2))
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
        let seconds = CMTimeGetSeconds(asset.duration)
        let frames = Int(((seconds.isFinite ? seconds : 0) * sampleRate).rounded(.up))
        guard frames > 0 else { throw CocoaError(.fileReadCorruptFile) }
        let writer = try PlanarWriter(url: out, channels: channels, frames: frames)
        writer.onFirstBlock = started
        defer { try? writer.close() }
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var length = 0
            var ptr: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &ptr) == noErr,
                  let ptr else { continue }
            let n = length / (4 * channels)
            guard n > 0 else { continue }
            let bufs = (0..<channels).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: n) }
            defer { bufs.forEach { $0.deallocate() } }
            ptr.withMemoryRebound(to: Float.self, capacity: n * channels) { f in
                for i in 0..<n {
                    for c in 0..<channels { bufs[c][i] = f[i * channels + c] }
                }
            }
            try writer.append({ UnsafePointer(bufs[$0]) }, count: n)
        }
        if reader.status == .failed { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
        return channels
    }

    /// Removes cache files not used for 30 days.
    static func prune() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let limit = Date().addingTimeInterval(-30 * 86400)
        for f in files {
            let d = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if d < limit || f.pathExtension == "part" { try? fm.removeItem(at: f) }
        }
    }
}
