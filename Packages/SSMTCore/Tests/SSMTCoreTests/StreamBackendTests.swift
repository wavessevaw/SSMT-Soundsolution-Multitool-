import XCTest
@testable import SSMTCore

/// The Windows app's backend: blocks pushed by a host, same semantics as the Core Audio backend.
final class StreamBackendTests: XCTestCase {
    /// A host with a fixed output→input latency: what is played comes back `latency` frames later.
    final class Host {
        let backend: StreamAudioBackend
        var line: [Float]
        var position: Int64 = 0
        init(backend: StreamAudioBackend, latency: Int) {
            self.backend = backend
            line = [Float](repeating: 0, count: latency)
        }
        func step(_ frames: Int) {
            var out: [Float] = []
            backend.render(into: &out, frames: frames, channels: backend.outputChannels)
            let played = (0..<frames).map { out[$0 * backend.outputChannels + backend.routing.outputChannels[0]] }
            line += played
            let heard = Array(line[0..<frames])
            line.removeFirst(frames)
            var input = [Float](repeating: 0, count: frames * backend.inputChannels)
            for i in 0..<frames { input[i * backend.inputChannels + backend.routing.microphoneChannel] = heard[i] * 0.5 }
            backend.capture(input, frames: frames, channels: backend.inputChannels, played: played, frameIndex: position)
            position += Int64(frames)
        }
    }

    func makeBackend() throws -> StreamAudioBackend {
        var safety = GeneratorSafety()
        safety.fadeInSeconds = 0.05
        safety.startLevelDBFS = -20
        return try StreamAudioBackend(sampleRate: 48000, inputChannels: 4, outputChannels: 2,
                                      routing: .init(microphoneChannel: 2, referenceChannel: nil, outputChannels: [1]),
                                      displayName: "Test", safety: safety, seed: 3)
    }

    func testFindsTheHostLatencyAsTheSystemDelay() throws {
        let backend = try makeBackend()
        let engine = MeasurementEngine(backend: backend)
        try backend.start()
        backend.generatorControl.targetLevelDBFS.value = -20
        backend.generatorControl.run.value = true
        let host = Host(backend: backend, latency: 700)
        func run(_ seconds: Double) { for _ in 0..<Int(seconds * 40) { host.step(1200); engine.drainNow() } }
        run(1)
        var delay: DelayEstimate?
        engine.findDelay(seconds: 2) { delay = $0 }
        run(2.5)
        let d = try XCTUnwrap(delay)
        XCTAssertTrue(d.isReliable)
        XCTAssertEqual(d.samples, 700, accuracy: 1)
        XCTAssertEqual(backend.discontinuities.value, 0)
        backend.stop()
    }

    func testOnlyRoutedOutputsCarryTheSignal() throws {
        let backend = try makeBackend()
        try backend.start()
        backend.generatorControl.targetLevelDBFS.value = -20
        backend.generatorControl.run.value = true
        var out: [Float] = []
        for _ in 0..<20 { backend.render(into: &out, frames: 480, channels: 2) }
        XCTAssertEqual(out.count, 960)
        XCTAssertTrue((0..<480).allSatisfy { out[$0 * 2] == 0 })
        XCTAssertTrue((0..<480).contains { out[$0 * 2 + 1] != 0 })
        backend.stop()
        backend.render(into: &out, frames: 480, channels: 2)
        XCTAssertTrue(out.allSatisfy { $0 == 0 })
    }

    func testGapsAndRestartsAreDiscontinuities() throws {
        let backend = try makeBackend()
        try backend.start()
        let block = [Float](repeating: 0, count: 256 * 4)
        backend.capture(block, frames: 256, channels: 4, played: [Float](repeating: 0, count: 256), frameIndex: 0)
        backend.capture(block, frames: 256, channels: 4, played: [Float](repeating: 0, count: 256), frameIndex: 256)
        XCTAssertEqual(backend.discontinuities.value, 0)
        backend.capture(block, frames: 256, channels: 4, played: [Float](repeating: 0, count: 256), frameIndex: 1024)
        XCTAssertEqual(backend.discontinuities.value, 1)
        backend.markDiscontinuity()
        XCTAssertEqual(backend.discontinuities.value, 2)
        XCTAssertEqual(backend.inputRing.readable, backend.outputRing.readable)
    }

    func testChannelsOutsideTheDeviceAreRefused() {
        XCTAssertThrowsError(try StreamAudioBackend(sampleRate: 48000, inputChannels: 2, outputChannels: 2,
                                                    routing: .init(microphoneChannel: 2), displayName: "x"))
        XCTAssertThrowsError(try StreamAudioBackend(sampleRate: 48000, inputChannels: 2, outputChannels: 2,
                                                    routing: .init(microphoneChannel: 0, outputChannels: [2]), displayName: "x"))
    }

    func testCalibrationLibraryRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ssmt-cal-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var lib = CalibrationLibrary()
        let mic = MicrophoneCalibration(name: "Test", frequencies: [100, 1000, 10000], deviationDB: [1, 0, -2])
        lib.microphones.append(mic)
        lib.selectedMicrophoneID = mic.id
        lib.spl = SPLCalibration(dBFSAt94dBSPL: -30)
        lib.save(to: url)
        let back = CalibrationLibrary.load(from: url)
        XCTAssertEqual(back, lib)
        XCTAssertEqual(back.selectedMicrophone?.name, "Test")
        XCTAssertNil(back.selectedProfile)
        let profile = try XCTUnwrap(MicrophoneProfiles.all.first)
        lib.selectedMicrophoneID = profile.uuid
        XCTAssertEqual(lib.selectedProfile?.id, profile.id)
        XCTAssertEqual(CalibrationLibrary.load(from: url.appendingPathExtension("missing")), CalibrationLibrary())
    }

    func testDemoSystemIsTheMisalignedPA() {
        let s = VirtualSystem.demo()
        XCTAssertEqual(s.sampleRate, 48000)
        XCTAssertTrue(s.sub.invertPolarity)
        XCTAssertEqual(s.sub.gainDB, 3)
        XCTAssertLessThan(s.sub.delaySamples, s.main.delaySamples)
        XCTAssertEqual(s.room.reflections.count, 2)
        XCTAssertEqual(s.micNoiseDBFS, -75)
    }
}
