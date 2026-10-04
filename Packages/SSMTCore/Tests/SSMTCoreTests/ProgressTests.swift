import XCTest
@testable import SSMTCore

final class ProgressTests: XCTestCase {
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    func testCurveEndsAtTheRequestedLevel40() {
        XCTAssertEqual(Leveling.xpRequired(1), 0)
        XCTAssertEqual(Leveling.xpRequired(40), 60_000)
        XCTAssertEqual(Leveling.hoursRequired(40), 500, accuracy: 1e-9)
        XCTAssertEqual(Leveling.clicksRequired(40), 5_000)
        for l in 2...40 {
            XCTAssertGreaterThan(Leveling.xpRequired(l), Leveling.xpRequired(l - 1))
            XCTAssertGreaterThan(Leveling.hoursRequired(l), Leveling.hoursRequired(l - 1))
            XCTAssertGreaterThanOrEqual(Leveling.clicksRequired(l), Leveling.clicksRequired(l - 1))
        }
        XCTAssertEqual(EngineerRank.of(level: 10), .copper)
        XCTAssertEqual(EngineerRank.of(level: 11), .bronze)
        XCTAssertEqual(EngineerRank.of(level: 30), .silver)
        XCTAssertEqual(EngineerRank.of(level: 40), .gold)
    }

    func testLevel40NeedsBothHoursAndClicks() {
        // Lots of XP but too few hours: no level 40.
        XCTAssertLessThan(Leveling.level(xp: 1_000_000, hours: 499, clicks: 1_000_000), 40)
        XCTAssertLessThan(Leveling.level(xp: 1_000_000, hours: 1_000, clicks: 4_999), 40)
        XCTAssertEqual(Leveling.level(xp: 60_000, hours: 500, clicks: 5_000), 40)
        XCTAssertEqual(Leveling.level(xp: 0, hours: 0, clicks: 0), 1)
    }

    func testClickXPIsCappedPerHour() {
        var p = PlayerProgress()
        let t0 = date(2026, 10, 4)
        for i in 0..<1_000 { p.recordClick(at: t0.addingTimeInterval(Double(i))) }
        XCTAssertEqual(p.clicks, 1_000)
        XCTAssertEqual(p.clickXP, Leveling.clickXPPerHourCap)
        p.recordClick(at: t0.addingTimeInterval(3_700))
        XCTAssertEqual(p.clickXP, Leveling.clickXPPerHourCap + 1)
    }

    func testIdleTimeDoesNotCount() {
        var p = PlayerProgress()
        let t0 = date(2026, 10, 4)
        p.tick(seconds: 5, active: true, at: t0, calendar: cal)
        p.tick(seconds: 5, active: false, at: t0.addingTimeInterval(5), calendar: cal)
        XCTAssertEqual(p.activeSeconds, 5)
    }

    func testFirstLaunchUnlocksFirstSoundAndALevel() {
        var p = PlayerProgress()
        p.recordLaunch(at: date(2026, 10, 4), calendar: cal)
        let u = p.evaluate(at: date(2026, 10, 4))
        XCTAssertTrue(u.achievements.contains("firstSound"))
        XCTAssertEqual(p.bonusXP, 50)
    }

    func testStreakAndNightAndNewYear() {
        var p = PlayerProgress()
        for d in 1...7 { p.tick(seconds: 5, active: true, at: date(2026, 3, d), calendar: cal) }
        XCTAssertEqual(p.counters["time.streak"], 7)
        p.tick(seconds: 5, active: true, at: date(2026, 3, 10), calendar: cal)
        XCTAssertEqual(p.counters["time.streak"], 1)
        XCTAssertEqual(p.counters["time.days"], 8)
        p.tick(seconds: 5, active: true, at: date(2026, 3, 11, 3, 30), calendar: cal)
        p.tick(seconds: 5, active: true, at: date(2026, 12, 31), calendar: cal)
        let u = p.evaluate(at: date(2026, 12, 31))
        XCTAssertTrue(u.achievements.contains("noWeekends"))
        XCTAssertTrue(u.achievements.contains("nightOwl"))
        XCTAssertTrue(u.achievements.contains("newYear"))
    }

    func testContinuousWorkResetsAfterABreak() {
        var p = PlayerProgress()
        let t0 = date(2026, 5, 5, 8)
        for i in 0..<(3 * 720) { p.tick(seconds: 5, active: true, at: t0.addingTimeInterval(Double(i) * 5), calendar: cal) }
        XCTAssertEqual(p.counters["time.maxContinuousMin"], 180)
        let later = t0.addingTimeInterval(4 * 3600)
        for i in 0..<720 { p.tick(seconds: 5, active: true, at: later.addingTimeInterval(Double(i) * 5), calendar: cal) }
        XCTAssertEqual(p.counters["time.maxContinuousMin"], 180)
    }

    func testCountersMaximaSetsAndProgressBars() {
        var p = PlayerProgress()
        p.recordMax("ptch.maxChannels", 30)
        p.recordMax("ptch.maxChannels", 20)
        XCTAssertEqual(p.counters["ptch.maxChannels"], 30)
        let thousand = AchievementCatalog.achievement("thousandGo")!
        p.record("qtrl.go", count: 640)
        XCTAssertEqual(p.value(for: thousand), 640)
        XCTAssertFalse(p.isMet(thousand))
        for c in Handbook.articles(in: .consoles) where c.id != "consoleCommon" { p.insert(c.id, into: "hb.consoles") }
        _ = p.evaluate(at: Date())
        XCTAssertNotNil(p.unlocked["consoleExpert"])
        XCTAssertNotNil(p.unlocked["go"])
    }

    func testEventXPAndCodableRoundTrip() throws {
        var p = PlayerProgress()
        p.record("setup.finished")
        XCTAssertEqual(p.bonusXP, 150)
        p.tick(seconds: 3600, active: true, at: date(2026, 1, 2), calendar: cal)
        XCTAssertEqual(p.xp, 250)
        let data = try JSONEncoder().encode(p)
        XCTAssertEqual(try JSONDecoder().decode(PlayerProgress.self, from: data), p)
        // An older or partial file still loads.
        let partial = try JSONDecoder().decode(PlayerProgress.self, from: Data(#"{"clicks": 7}"#.utf8))
        XCTAssertEqual(partial.clicks, 7)
        XCTAssertEqual(partial.level, 1)
    }

    func testCatalogHasAHundredUniqueAchievementsAndCollectorWorks() {
        let all = AchievementCatalog.all
        XCTAssertEqual(all.count, 100)
        XCTAssertEqual(Set(all.map(\.id)).count, 100)
        var p = PlayerProgress()
        let now = Date()
        for a in all where a.id != "collector" { p.unlocked[a.id] = now }
        _ = p.evaluate(at: now)
        XCTAssertNotNil(p.unlocked["collector"])
    }

    func testAchievementXPCanLevelUpAndIsReported() {
        var p = PlayerProgress()
        p.tick(seconds: 3600 * 2, active: true, at: date(2026, 6, 1), calendar: cal)
        for i in 0..<200 { p.recordClick(at: date(2026, 6, 1).addingTimeInterval(Double(i))) }
        let u = p.evaluate(at: date(2026, 6, 1))
        XCTAssertNotNil(u.newLevel)
        XCTAssertEqual(p.level, p.computedLevel)
        XCTAssertGreaterThanOrEqual(p.level, 3)
        XCTAssertTrue(p.evaluate(at: date(2026, 6, 1)).isEmpty)
    }
}
