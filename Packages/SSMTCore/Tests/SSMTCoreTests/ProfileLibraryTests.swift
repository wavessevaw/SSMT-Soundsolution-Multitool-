import XCTest
@testable import SSMTCore

final class ProfileLibraryTests: XCTestCase {
    func testSHA256MatchesTheStandardVectors() {
        XCTAssertEqual(SHA256Digest.hex([]), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256Digest.hex(Array("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(SHA256Digest.hex(Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        // Longer than one block, with multi-byte characters.
        let long = String(repeating: "Саундчек ", count: 40)
        XCTAssertEqual(SHA256Digest.hex(Array(long.utf8)).count, 64)
        XCTAssertNotEqual(LocalProfile.hash("1234", salt: "a"), LocalProfile.hash("1234", salt: "b"))
    }

    func testRegisterChecksAndLogin() throws {
        let existing = [try ProfileLibrary.makeProfile(name: "Никита", email: "", password: "1234", repeat: "1234", role: "foh",
                                                       color: LocalProfile.avatarColors[0], existing: [])]
        XCTAssertThrowsError(try ProfileLibrary.makeProfile(name: "  ", email: "", password: "1234", repeat: "1234", role: "foh", color: 0, existing: [])) {
            XCTAssertEqual($0 as? ProfileAccountError, .emptyName)
        }
        XCTAssertThrowsError(try ProfileLibrary.makeProfile(name: "A", email: "", password: "123", repeat: "123", role: "foh", color: 0, existing: [])) {
            XCTAssertEqual($0 as? ProfileAccountError, .shortPassword)
        }
        XCTAssertThrowsError(try ProfileLibrary.makeProfile(name: "A", email: "", password: "1234", repeat: "1235", role: "foh", color: 0, existing: [])) {
            XCTAssertEqual($0 as? ProfileAccountError, .mismatch)
        }
        XCTAssertThrowsError(try ProfileLibrary.makeProfile(name: "никита ", email: "", password: "1234", repeat: "1234", role: "foh", color: 0, existing: existing)) {
            XCTAssertEqual($0 as? ProfileAccountError, .nameTaken)
        }
        let p = try ProfileLibrary.login(existing[0].id, password: "1234", in: existing)
        XCTAssertEqual(p.name, "Никита")
        XCTAssertThrowsError(try ProfileLibrary.login(existing[0].id, password: "0000", in: existing)) {
            XCTAssertEqual($0 as? ProfileAccountError, .wrongPassword)
        }
    }

    func testProfilesAreWrittenAndReadBack() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ssmt-profiles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let lib = ProfileLibrary(folder: dir)
        var a = LocalProfile(name: "Никита Г.", email: "", role: "foh", color: 0x2A4B3E, createdAt: Date(timeIntervalSince1970: 1_790_000_000),
                             salt: "s", passwordHash: "")
        a.progress.activeSeconds = 10
        a.progress.record("app.launch")
        var b = LocalProfile(name: "Bob", email: "", role: "foh", color: 0x23405A, salt: "s", passwordHash: "")
        b.progress.activeSeconds = 100
        lib.write(a)
        lib.write(b)
        let loaded = lib.load()
        XCTAssertEqual(loaded.map(\.name), ["Bob", "Никита Г."])
        XCTAssertEqual(loaded[1], a)
        XCTAssertEqual(a.initials, "НГ")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(a.id.uuidString + ".json").path))
    }

    func testInputBursts() {
        var pr = PlayerProgress()
        var t = ProfileInputTracker()
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        for i in 0..<10 { t.click(at: start.addingTimeInterval(Double(i) * 0.1), x: 100, y: 100, progress: &pr) }
        XCTAssertEqual(pr.clicks, 10)
        XCTAssertEqual(pr.counters["input.woodpecker"], 1)
        for i in 0..<15 { t.key(at: start.addingTimeInterval(Double(i) * 0.05), command: false, shift: false, key: "a", progress: &pr) }
        XCTAssertEqual(pr.counters["input.cat"], 1)
        t.key(at: start.addingTimeInterval(5), command: true, shift: false, key: "Z", progress: &pr)
        t.key(at: start.addingTimeInterval(6), command: true, shift: true, key: "z", progress: &pr)
        t.key(at: start.addingTimeInterval(7), command: true, shift: false, key: "s", progress: &pr)
        XCTAssertEqual(pr.counters["key.shortcut"], 3)
        XCTAssertEqual(pr.counters["key.undo"], 1)
        XCTAssertEqual(pr.counters["key.save"], 1)
    }

    func testHandbookIndexCategoriesFavoritesAndSearch() {
        XCTAssertEqual(HandbookIndex.entries(category: "calculators", query: "", russian: true, favorites: []).count,
                       AudioCalculator.all.count)
        XCTAssertEqual(HandbookIndex.count(.pinouts), Handbook.articles(in: .pinouts).count)
        let fav = HandbookIndex.entries(category: HandbookIndex.favoritesCategory, query: "", russian: true,
                                        favorites: ["calc.cable", "speakon", "missing"])
        XCTAssertEqual(fav.map(\.id), ["calc.cable", "speakon"])
        XCTAssertEqual(HandbookIndex.entry("calc.cable")?.category, .calculators)
        XCTAssertEqual(HandbookIndex.entry("speakon")?.category, .pinouts)
        let found = HandbookIndex.entries(category: "pinouts", query: "speakon", russian: true, favorites: [])
        XCTAssertTrue(found.contains { $0.id == "speakon" })
        let glossary = HandbookIndex.entries(category: "glossary", query: "", russian: true, favorites: [])
        XCTAssertEqual(glossary.count, HandbookIndex.count(.glossary))
    }
}
