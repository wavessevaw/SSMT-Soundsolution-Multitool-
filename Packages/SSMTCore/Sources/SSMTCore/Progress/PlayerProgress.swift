import Foundation

/// Everything a profile has earned: active time, clicks, counters of events, unlocked achievements, level.
/// The app feeds it input (clicks, a periodic tick while the user is active) and events from the functions;
/// `evaluate` turns that into XP, levels and achievements.
public struct PlayerProgress: Codable, Equatable, Sendable {
    public var activeSeconds: Double = 0
    public var clicks = 0
    /// XP earned by clicks (capped per hour).
    public var clickXP = 0
    /// XP from events and achievements.
    public var bonusXP = 0
    public var counters: [String: Int] = [:]
    public var sets: [String: Set<String>] = [:]
    public var unlocked: [String: Date] = [:]
    /// Level already announced to the user.
    public var level = 1

    // Bookkeeping for time-based achievements.
    var days: Set<String> = []
    var lastDay: String?
    var todaySeconds: Double = 0
    var continuousSeconds: Double = 0
    var lastActive: Date?
    var hourStart: Date?
    var clicksThisHour = 0

    public init() {}

    enum CodingKeys: String, CodingKey {
        case activeSeconds, clicks, clickXP, bonusXP, counters, sets, unlocked, level
        case days, lastDay, todaySeconds, continuousSeconds, lastActive, hourStart, clicksThisHour
    }

    /// Missing keys take their defaults, so profiles from older versions keep loading.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        activeSeconds = try c.decodeIfPresent(Double.self, forKey: .activeSeconds) ?? 0
        clicks = try c.decodeIfPresent(Int.self, forKey: .clicks) ?? 0
        clickXP = try c.decodeIfPresent(Int.self, forKey: .clickXP) ?? 0
        bonusXP = try c.decodeIfPresent(Int.self, forKey: .bonusXP) ?? 0
        counters = try c.decodeIfPresent([String: Int].self, forKey: .counters) ?? [:]
        sets = try c.decodeIfPresent([String: Set<String>].self, forKey: .sets) ?? [:]
        unlocked = try c.decodeIfPresent([String: Date].self, forKey: .unlocked) ?? [:]
        level = try c.decodeIfPresent(Int.self, forKey: .level) ?? 1
        days = try c.decodeIfPresent(Set<String>.self, forKey: .days) ?? []
        lastDay = try c.decodeIfPresent(String.self, forKey: .lastDay)
        todaySeconds = try c.decodeIfPresent(Double.self, forKey: .todaySeconds) ?? 0
        continuousSeconds = try c.decodeIfPresent(Double.self, forKey: .continuousSeconds) ?? 0
        lastActive = try c.decodeIfPresent(Date.self, forKey: .lastActive)
        hourStart = try c.decodeIfPresent(Date.self, forKey: .hourStart)
        clicksThisHour = try c.decodeIfPresent(Int.self, forKey: .clicksThisHour) ?? 0
    }

    public var hours: Double { activeSeconds / 3600 }
    public var xp: Int { Int(activeSeconds / 3600 * Double(Leveling.xpPerHour)) + clickXP + bonusXP }
    public var computedLevel: Int { Leveling.level(xp: xp, hours: hours, clicks: clicks) }
    public var nextLevel: Leveling.NextLevel? { Leveling.next(after: computedLevel, xp: xp, hours: hours, clicks: clicks) }
    public var rank: EngineerRank { .of(level: computedLevel) }

    /// XP for events that stand for real work.
    public static let eventXP: [String: Int] = [
        "setup.delayFound": 20, "setup.finished": 150, "qtrl.show": 200, "foh.soundcheck": 150,
    ]

    // MARK: Input

    public mutating func recordClick(at now: Date) {
        clicks += 1
        if let s = hourStart, now.timeIntervalSince(s) < 3600 {
            clicksThisHour += 1
        } else {
            hourStart = now
            clicksThisHour = 1
        }
        if clicksThisHour <= Leveling.clickXPPerHourCap { clickXP += 1 }
    }

    /// Called periodically while the app runs; `active` = the user did something recently.
    public mutating func tick(seconds: Double, active: Bool, at now: Date, calendar: Calendar = .current) {
        guard active else {
            continuousSeconds = 0
            return
        }
        let day = Self.dayKey(now, calendar)
        if day != lastDay {
            if let last = lastDay, let lastDate = Self.date(last, calendar),
               let gap = calendar.dateComponents([.day], from: lastDate, to: Self.date(day, calendar) ?? now).day {
                counters["time.streak"] = gap == 1 ? (counters["time.streak"] ?? 1) + 1 : 1
            } else {
                counters["time.streak"] = 1
            }
            recordMax("time.maxStreak", counters["time.streak"] ?? 1)
            lastDay = day
            todaySeconds = 0
            days.insert(day)
            counters["time.days"] = days.count
        }
        if let last = lastActive, now.timeIntervalSince(last) > 600 { continuousSeconds = 0 }
        lastActive = now
        activeSeconds += seconds
        todaySeconds += seconds
        continuousSeconds += seconds
        recordMax("time.maxContinuousMin", Int(continuousSeconds / 60))
        recordMax("time.maxDayMin", Int(todaySeconds / 60))
        let c = calendar.dateComponents([.hour, .month, .day], from: now)
        if let h = c.hour, (3..<5).contains(h) { record("time.night") }
        if c.month == 12 && c.day == 31 { record("time.dec31") }
    }

    /// A new session after login.
    public mutating func recordLaunch(at now: Date, calendar: Calendar = .current) {
        if let last = lastActive, now.timeIntervalSince(last) > 30 * 86_400 { record("app.returned") }
        record("app.launch")
        let c = calendar.dateComponents([.hour, .month, .day], from: now)
        if c.hour == 5 { record("app.earlyLaunch") }
        if c.month == 4 && c.day == 1 { record("app.april1") }
    }

    // MARK: Events

    public mutating func record(_ event: String, count: Int = 1) {
        counters[event, default: 0] += count
        if let x = Self.eventXP[event] { bonusXP += x * count }
    }

    /// Keeps the largest value seen (channels in a patch, cues in a show…).
    public mutating func recordMax(_ key: String, _ value: Int) {
        if value > counters[key, default: 0] { counters[key] = value }
    }

    public mutating func insert(_ item: String, into set: String) {
        sets[set, default: []].insert(item)
    }

    // MARK: Results

    public struct Update: Equatable, Sendable {
        public var achievements: [String] = []
        /// New level reached (announce it), nil if unchanged.
        public var newLevel: Int?
        public var isEmpty: Bool { achievements.isEmpty && newLevel == nil }
    }

    public func isMet(_ a: Achievement) -> Bool {
        switch a.condition {
        case .count(let k, let n): return counters[k, default: 0] >= n
        case .distinct(let k, let n): return sets[k, default: []].count >= n
        case .hours(let h): return hours >= h
        case .clicks(let n): return clicks >= n
        case .level(let l): return computedLevel >= l
        case .collected(let n): return unlocked.keys.filter { $0 != a.id }.count >= n
        }
    }

    /// Current value towards a counter achievement (for the progress bar).
    public func value(for a: Achievement) -> Double? {
        guard let t = a.target else { return nil }
        return t.isSet ? Double(sets[t.key, default: []].count) : Double(counters[t.key, default: 0])
    }

    /// Unlocks what is earned (achievements add XP, which can unlock more) and reports a new level.
    public mutating func evaluate(at now: Date) -> Update {
        var update = Update()
        var changed = true
        while changed {
            changed = false
            for a in AchievementCatalog.all where unlocked[a.id] == nil && isMet(a) {
                unlocked[a.id] = now
                bonusXP += a.rarity.xp
                update.achievements.append(a.id)
                changed = true
            }
        }
        let l = computedLevel
        if l > level {
            level = l
            update.newLevel = l
        }
        return update
    }

    static func dayKey(_ d: Date, _ cal: Calendar) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func date(_ key: String, _ cal: Calendar) -> Date? {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return cal.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }
}
