import XCTest
@testable import SSMTCore

/// Waveform pictures, "trim silence" and typed OSC arguments: shared by the macOS and the Windows program.
final class ShowWaveformTests: XCTestCase {
    /// 1 s of silence, 1 s at 0.5 (left) / 0.25 (right), 1 s of silence, at 1 kHz.
    private func clip() -> AudioClip {
        let n = 3000
        let left = (0..<n).map { $0 >= 1000 && $0 < 2000 ? Float(0.5) : 0 }
        let right = (0..<n).map { $0 >= 1000 && $0 < 2000 ? Float(-0.25) : 0 }
        return AudioClip(sampleRate: 1000, channels: [left, right])
    }

    func testOverviewTakesThePeakOfEveryChannel() {
        let w = ShowWaveform.overview(clip(), buckets: 3)
        XCTAssertEqual(w.count, 3)
        XCTAssertEqual(w[0], 0)
        XCTAssertEqual(w[1], 0.5, accuracy: 1e-6)
        XCTAssertEqual(w[2], 0)
        // Never more buckets than frames, never above 1.
        let loud = AudioClip(sampleRate: 1000, channels: [[2, -3]])
        XCTAssertEqual(ShowWaveform.overview(loud, buckets: 1200), [1, 1])
        XCTAssertEqual(ShowWaveform.overview(AudioClip(sampleRate: 1000, channels: [[]])), [])
    }

    func testSliceShowsOnlyTheAskedSection() {
        let c = clip()
        let s = ShowWaveform.slice(c, from: 0.5, to: 1.5, buckets: 2)
        XCTAssertEqual(s?.count, 2)
        XCTAssertEqual(s?[0] ?? -1, 0, accuracy: 1e-6)
        XCTAssertEqual(s?[1] ?? -1, 0.5, accuracy: 1e-6)
        XCTAssertNil(ShowWaveform.slice(c, from: 2, to: 1, buckets: 10))
        XCTAssertNil(ShowWaveform.slice(c, from: 5, to: 6, buckets: 10))
        XCTAssertNil(ShowWaveform.slice(c, from: 0, to: 1, buckets: 0))
    }

    func testSoundBoundsFindTheFirstAndLastSound() throws {
        let b = try XCTUnwrap(ShowWaveform.soundBounds(clip()))
        XCTAssertEqual(b.start, 0.99, accuracy: 1e-9)
        XCTAssertEqual(b.end, 1.999 + 0.05, accuracy: 1e-9)
        XCTAssertNil(ShowWaveform.soundBounds(AudioClip(sampleRate: 1000, channels: [[Float](repeating: 0.001, count: 100)])))
    }

    func testTypedOSCArguments() {
        XCTAssertEqual(OSCArgument.parseList("1 0.5 \"Go+ Sequence 1\" true word"),
                       [.int(1), .float(0.5), .string("Go+ Sequence 1"), .bool(true), .string("word")])
        XCTAssertEqual(OSCArgument.parseList("   "), [])
        XCTAssertEqual(OSCArgument.parseList("\"open"), [.string("open")])
    }
}
