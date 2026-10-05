import Foundation

/// Engineer ranks: every ten levels.
public enum EngineerRank: Int, CaseIterable, Sendable {
    case copper, bronze, silver, gold

    public static func of(level: Int) -> EngineerRank {
        EngineerRank(rawValue: min(3, max(0, (level - 1) / 10))) ?? .copper
    }

    public var name: LText {
        switch self {
        case .copper: return LText("Медь", "Copper")
        case .bronze: return LText("Бронза", "Bronze")
        case .silver: return LText("Серебро", "Silver")
        case .gold: return LText("Золото", "Gold")
        }
    }

    public var title: LText {
        switch self {
        case .copper: return LText("Стажёр у пульта", "Console trainee")
        case .bronze: return LText("Звукорежиссёр", "Sound engineer")
        case .silver: return LText("Ведущий звукорежиссёр", "Lead engineer")
        case .gold: return LText("Легенда FOH", "FOH legend")
        }
    }

    public var levels: ClosedRange<Int> { (rawValue * 10 + 1)...(rawValue * 10 + 10) }
}

/// Level curve: level 40 needs 60 000 XP, 500 hours of active work and 5 000 clicks; lower levels need less,
/// growing slowly at first (level 2 in about twenty minutes) and steeper later.
public enum Leveling {
    public static let maxLevel = 40
    public static let xpPerHour = 100
    /// Clicks that count as XP in one hour (an auto-clicker earns nothing more).
    public static let clickXPPerHourCap = 600

    private static func t(_ level: Int) -> Double { Double(min(max(level, 1), maxLevel) - 1) / Double(maxLevel - 1) }

    public static func xpRequired(_ level: Int) -> Int { Int((60_000 * pow(t(level), 1.8) / 10).rounded()) * 10 }
    public static func hoursRequired(_ level: Int) -> Double { 500 * pow(t(level), 2) }
    public static func clicksRequired(_ level: Int) -> Int { Int((5_000 * pow(t(level), 1.6) / 10).rounded()) * 10 }

    /// Highest level whose XP, hours and clicks are all reached.
    public static func level(xp: Int, hours: Double, clicks: Int) -> Int {
        var l = 1
        while l < maxLevel {
            let n = l + 1
            guard xp >= xpRequired(n), hours >= hoursRequired(n) - 1e-9, clicks >= clicksRequired(n) else { break }
            l = n
        }
        return l
    }

    /// Progress towards the next level (0…1) on each of the three conditions.
    public struct NextLevel: Equatable, Sendable {
        public var level: Int
        public var xp: Double
        public var hours: Double
        public var clicks: Double
        /// The bar: the slowest of the three.
        public var overall: Double { min(xp, hours, clicks) }
    }

    public static func next(after level: Int, xp: Int, hours: Double, clicks: Int) -> NextLevel? {
        guard level < maxLevel else { return nil }
        let n = level + 1
        func frac(_ v: Double, _ from: Double, _ to: Double) -> Double { to <= from ? 1 : min(1, max(0, (v - from) / (to - from))) }
        return NextLevel(level: n,
                         xp: frac(Double(xp), Double(xpRequired(level)), Double(xpRequired(n))),
                         hours: frac(hours, hoursRequired(level), hoursRequired(n)),
                         clicks: frac(Double(clicks), Double(clicksRequired(level)), Double(clicksRequired(n))))
    }
}
