import XCTest
@testable import SSMTCore

final class HandbookTests: XCTestCase {
    func testSpeedOfSoundAndDelay() {
        XCTAssertEqual(AudioMath.speedOfSound(celsius: 20), 343.2, accuracy: 0.2)
        let r = AudioCalculator.all.first { $0.id == "delay" }!.results(["d": 34.32, "t": 20])
        XCTAssertEqual(Double(r[0].value)!, 100, accuracy: 0.2)
    }

    func testLevelConversions() {
        XCTAssertEqual(AudioMath.dBu(volts: 0.7746), 0, accuracy: 0.001)
        XCTAssertEqual(AudioMath.dBu(volts: AudioMath.volts(dBu: 4)), 4, accuracy: 1e-9)
        XCTAssertEqual(AudioMath.dBV(volts: 1), 0, accuracy: 1e-9)
        XCTAssertEqual(AudioMath.sum(dB: [90, 90]), 93.01, accuracy: 0.01)
    }

    func testInverseSquareAndLineSource() {
        XCTAssertEqual(AudioMath.levelChange(from: 1, to: 2), -6.02, accuracy: 0.01)
        XCTAssertEqual(AudioMath.levelChange(from: 1, to: 2, lineSource: true), -3.01, accuracy: 0.01)
        XCTAssertEqual(AudioMath.spl(sensitivity: 98, watts: 100, meters: 10), 98, accuracy: 1e-9)
    }

    func testImpedanceAndCable() {
        XCTAssertEqual(AudioMath.impedance([8, 8], parallel: true), 4, accuracy: 1e-9)
        XCTAssertEqual(AudioMath.impedance([8, 8, 0, 0], parallel: false), 16, accuracy: 1e-9)
        // 30 m of 2.5 mm² into 4 Ω: R ≈ 0.42 Ω, loss ≈ −0.87 dB.
        let r = AudioMath.cableResistance(meters: 30, squareMillimetres: 2.5)
        XCTAssertEqual(r, 0.42, accuracy: 0.001)
        XCTAssertEqual(AudioMath.cableLoss(load: 4, cable: r), -0.87, accuracy: 0.01)
    }

    func testRoomAndNote() {
        XCTAssertEqual(AudioMath.axialModes(length: 10)[0], 17.16, accuracy: 0.05)
        XCTAssertEqual(AudioMath.rt60Sabine(volume: 1000, surface: 600, absorption: 0.2), 1.342, accuracy: 0.01)
        let a = AudioMath.note(frequency: 440)
        XCTAssertEqual(a.name, "A")
        XCTAssertEqual(a.octave, 4)
        XCTAssertEqual(a.cents, 0, accuracy: 1e-6)
        let c = AudioMath.note(frequency: 261.63)
        XCTAssertEqual("\(c.name)\(c.octave)", "C4")
    }

    func testEveryCalculatorComputesWithDefaults() {
        var ids = Set<String>()
        for calc in AudioCalculator.all {
            XCTAssertTrue(ids.insert(calc.id).inserted, "duplicate \(calc.id)")
            let r = calc.results([:])
            XCTAssertFalse(r.isEmpty, calc.id)
            XCTAssertTrue(r.contains { $0.primary }, "no primary result in \(calc.id)")
            XCTAssertFalse(r.contains { $0.value == "nan" || $0.value == "inf" }, calc.id)
        }
    }

    func testArticlesAreUniqueAndNotEmpty() {
        var ids = Set<String>()
        for a in Handbook.articles {
            XCTAssertTrue(ids.insert(a.id).inserted, "duplicate \(a.id)")
            XCTAssertFalse(a.blocks.isEmpty, a.id)
            XCTAssertFalse(a.title.ru.isEmpty || a.title.en.isEmpty, a.id)
        }
        for c in HandbookCategory.allCases where c != .calculators {
            XCTAssertFalse(Handbook.articles(in: c).isEmpty, c.rawValue)
        }
    }

    func testSearchFindsInBothLanguagesAndPrefersTitles() {
        XCTAssertEqual(Handbook.search("speakon", russian: true).first?.id, "speakon")
        XCTAssertEqual(Handbook.search("спикон", russian: true).first?.id, "speakon")
        XCTAssertEqual(Handbook.search("x32", russian: false).first?.id, "x32")
        XCTAssertTrue(Handbook.search("заводка", russian: true).contains { $0.id == "ringOut" })
        XCTAssertTrue(Handbook.search("", russian: true).count == Handbook.articles.count)
        XCTAssertTrue(AudioCalculator.search("задержка", russian: true).contains { $0.id == "delay" })
        XCTAssertTrue(AudioCalculator.search("cable", russian: false).contains { $0.id == "cable" })
    }
}
