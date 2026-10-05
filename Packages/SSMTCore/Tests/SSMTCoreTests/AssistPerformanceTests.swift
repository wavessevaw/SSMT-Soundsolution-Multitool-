import Foundation
import XCTest
@testable import SSMTCore

final class AssistPerformanceTests: XCTestCase {
    static func input(seconds: Int) -> [Float] {
        (0..<(seconds * 48000)).map { i in
            let t = Double(i) / 48000
            return Float(0.2 * sin(2 * .pi * 220 * t) + 0.07 * sin(2 * .pi * 440 * t)
                         + 0.03 * sin(2 * .pi * 880 * t))
        }
    }

    func testHotPathMedians() throws {
        let signal = Self.input(seconds: 2)
        let mic = Self.input(seconds: 1)
        let extractor = FeatureExtractor()
        let detector = FeedbackDetector()
        let console = SimulatedConsole.demo()
        let channels = Array(1...16)
        var checksum = 0.0
        func median(_ name: String, _ body: () -> Void) {
            body() // Warm up FFT plans and oscillator tables outside the timed samples.
            var samples: [Double] = []
            for _ in 0..<5 {
                let start = DispatchTime.now().uptimeNanoseconds
                body()
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
            print("ASSIST_BENCH \(name) median_ms=\(samples.sorted()[2]) samples_ms=\(samples)")
        }
        #if DEBUG
        print("ASSIST_BENCH configuration=debug backend=\(FFT.defaultBackend)")
        #else
        print("ASSIST_BENCH configuration=release backend=\(FFT.defaultBackend)")
        #endif
        median("analyze_2s_48k") { checksum += extractor.analyze(signal).rmsDB }
        median("feedback_1s_48k") { detector.reset(); checksum += Double(detector.process(mic).count) }
        median("render_16ch_1s_48k") {
            let output = console.render(seconds: 1, channels: channels)
            checksum += Double(output.mic[100])
        }
        XCTAssertTrue(checksum.isFinite)
        let reference = try JSONEncoder().encode(extractor.analyze(signal))
        print("ASSIST_FEATURE_REFERENCE \(String(decoding: reference, as: UTF8.self))")
    }
}
