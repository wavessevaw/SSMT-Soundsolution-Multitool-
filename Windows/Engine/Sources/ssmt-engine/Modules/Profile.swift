import Foundation
import SSMTCore

/// Profile and progress (App/SSMT/Profile/ProfileCenter.swift): local profiles in `<dataDir>/Profiles/<id>.json`
/// (the Mac's format), the signed-in profile, clicks and keys from the interface, active time, events from the
/// functions, achievements and level-ups.
///
/// Commands: profileHello {auto}, profileRegister {name, password, again, color, autoLogin}, profileLogin {id,
/// password, autoLogin}, profileLogout, profileRecord {event, count}, profileRecordMax {key, value}, profileInsert
/// {item, set}, profileSection {name}, profileInput {kind: click|key, x, y, ctrl, shift, key}, profileFocus
/// {active}, profileQuit, profilePreview {sample} (snapshot fixtures: a made-up profile, nothing tracked).
/// Events: profileCatalog, profiles, profile, profileUnlocked {achievements, level}, profileAuto {id},
/// profileError {key}.
/// A function whose live state feeds time-based achievements every 5 s while someone is signed in.
protocol ProgressSampling: AnyObject {
    func sampleProgress()
}

final class ProfileModule: EngineModule {
    /// Other engine modules record their events here (as `ProfileCenter.shared.record` on the Mac).
    static weak var shared: ProfileModule?

    private var profiles: [LocalProfile] = []
    /// The profile as the interface last saw it, and the one that keeps changing.
    private var live: LocalProfile?
    private var preview: LocalProfile?
    private var lastPublish = Date.distantPast
    private var dirty = false
    private var lastInput = Date.distantPast
    private var focused = true
    private var sessionStart = Date()
    private var sessionSections = Set<String>()
    private var lastSave = Date()
    private var nextTick = Date.distantFuture
    private var input = ProfileInputTracker()
    private var dataDir: URL?

    init() {
        ProfileModule.shared = self
    }

    /// A true / false field (JSON booleans arrive as Bool or NSNumber depending on the platform).
    private func flag(_ c: Command, _ k: String) -> Bool? {
        if let b = c.fields[k] as? Bool { return b }
        return c.bool(k)
    }

    private func library(_ engine: Engine) -> ProfileLibrary {
        dataDir = engine.dataDir
        return ProfileLibrary(folder: engine.dataDir.appendingPathComponent("Profiles", isDirectory: true))
    }

    func handle(_ c: Command, engine: Engine) -> Bool {
        switch c.name {
        case "profileHello":
            dataDir = engine.dataDir
            emitCatalog()
            loadProfiles(engine)
            if live == nil, preview == nil, let s = c.str("auto"), let id = UUID(uuidString: s),
               let p = profiles.first(where: { $0.id == id }) {
                begin(p)
            }
            emitProfiles()
            publish(force: true)
        case "profileRegister":
            do {
                let p = try ProfileLibrary.makeProfile(name: c.str("name") ?? "", email: "", password: c.str("password") ?? "",
                                                       repeat: c.str("again") ?? "", role: "foh",
                                                       color: c.int("color") ?? LocalProfile.avatarColors[0], existing: profiles)
                library(engine).write(p)
                loadProfiles(engine)
                signIn(p, autoLogin: flag(c, "autoLogin") ?? true)
            } catch let e as ProfileAccountError {
                Out.emit("profileError", ["key": "acc.err." + e.rawValue])
            } catch {
                Out.emit("profileError", ["key": "\(error)"])
            }
        case "profileLogin":
            guard let s = c.str("id"), let id = UUID(uuidString: s),
                  let p = try? ProfileLibrary.login(id, password: c.str("password") ?? "", in: profiles) else {
                Out.emit("profileError", ["key": "acc.err.wrongPassword"])
                return true
            }
            signIn(p, autoLogin: flag(c, "autoLogin") ?? true)
        case "profileLogout":
            save(engine)
            Out.emit("profileAuto", ["id": ""])
            live = nil
            preview = nil
            nextTick = .distantFuture
            loadProfiles(engine)
            emitProfiles()
            publish(force: true)
        case "profileRecord":
            record(c.str("event") ?? "", count: c.int("count") ?? 1)
        case "profileRecordMax":
            recordMax(c.str("key") ?? "", c.int("value") ?? 0)
        case "profileInsert":
            insert(c.str("item") ?? "", into: c.str("set") ?? "")
        case "profileSection":
            sectionOpened(c.str("name") ?? "")
        case "profileInput":
            handleInput(c)
        case "profileFocus":
            focused = flag(c, "active") ?? true
        case "profileQuit":
            if live != nil, Date().timeIntervalSince(sessionStart) < 10 { record("app.quickQuit") }
            save(engine)
        case "profilePreview":
            // Snapshot tests: show a made-up profile without tracking or saving (ProfileCenter.preview).
            emitCatalog()
            live = nil
            nextTick = .distantFuture
            preview = flag(c, "sample") == true ? Self.sampleProfile : nil
            publish(force: true)
        default:
            return false
        }
        return true
    }

    func tick(_ now: Date, engine: Engine) {
        if dirty, now.timeIntervalSince(lastPublish) >= 2 { publish(force: true) }
        guard live != nil, now >= nextTick else { return }
        nextTick = now.addingTimeInterval(5)
        let active = now.timeIntervalSince(lastInput) < 120 && focused
        live?.progress.tick(seconds: 5, active: active, at: now)
        // App state sampled every 5 s (ProfileCenter.sample on the Mac: AppModel, ShowStore and AssistStore).
        for m in engine.modules { (m as? ProgressSampling)?.sampleProgress() }
        engine.sampleAssistProgress()
        evaluate()
        if now.timeIntervalSince(lastSave) > 30 { save(engine) }
    }

    // MARK: accounts

    private func loadProfiles(_ engine: Engine) {
        profiles = library(engine).load()
    }

    private func signIn(_ p: LocalProfile, autoLogin: Bool) {
        Out.emit("profileAuto", ["id": autoLogin ? p.id.uuidString : ""])
        begin(p)
        emitProfiles()
    }

    private func begin(_ p: LocalProfile) {
        preview = nil
        live = p
        sessionStart = Date()
        sessionSections = []
        lastInput = Date()
        lastSave = Date()
        nextTick = Date().addingTimeInterval(5)
        live?.progress.recordLaunch(at: Date())
        publish(force: true)
        evaluate()
    }

    private func save(_ engine: Engine) {
        guard let p = live else { return }
        library(engine).write(p)
        lastSave = Date()
    }

    /// Saves without an engine reference (after an unlock).
    private func saveNow() {
        guard let p = live, let dir = dataDir else { return }
        ProfileLibrary(folder: dir.appendingPathComponent("Profiles", isDirectory: true)).write(p)
        lastSave = Date()
    }

    // MARK: events from the functions

    func record(_ event: String, count: Int = 1) {
        guard live != nil, !event.isEmpty else { return }
        live?.progress.record(event, count: count)
        evaluate()
    }

    func recordMax(_ key: String, _ value: Int) {
        guard let p = live, !key.isEmpty, value > p.progress.counters[key, default: 0] else { return }
        live?.progress.recordMax(key, value)
        evaluate()
    }

    func insert(_ item: String, into set: String) {
        guard let p = live, !set.isEmpty, !p.progress.sets[set, default: []].contains(item) else { return }
        live?.progress.insert(item, into: set)
        evaluate()
    }

    func sectionOpened(_ name: String) {
        guard !name.isEmpty else { return }
        insert(name, into: "sections")
        sessionSections.insert(name)
        if sessionSections.count >= 5 { record("session.allSections") }
    }

    private func handleInput(_ c: Command) {
        guard var progress = live?.progress else { return }
        let now = Date()
        lastInput = now
        if c.str("kind") == "key" {
            input.key(at: now, command: flag(c, "ctrl") ?? false, shift: flag(c, "shift") ?? false, key: c.str("key") ?? "",
                      progress: &progress)
        } else {
            input.click(at: now, x: c.double("x") ?? 0, y: c.double("y") ?? 0, progress: &progress)
        }
        live?.progress = progress
        evaluate()
    }

    private func evaluate() {
        guard live != nil, let u = live?.progress.evaluate(at: Date()), !u.isEmpty else {
            if live != nil { dirty = true }
            return
        }
        publish(force: true)
        var fields: [String: Any] = ["achievements": u.achievements]
        if let l = u.newLevel, l > 1 { fields["level"] = l }
        Out.emit("profileUnlocked", fields)
        saveNow()
    }

    // MARK: to the interface

    private static func lt(_ t: LText) -> [String: String] { ["ru": t.ru, "en": t.en] }

    private func emitProfiles() {
        Out.emit("profiles", ["items": profiles.map { p -> [String: Any] in
            ["id": p.id.uuidString, "name": p.name, "initials": p.initials, "color": p.color]
        }])
    }

    /// The signed-in profile as the interface shows it, refreshed at most every 2 s unless forced.
    private func publish(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastPublish) >= 2 else {
            dirty = true
            return
        }
        lastPublish = Date()
        dirty = false
        guard let p = live ?? preview else {
            Out.emit("profile", ["signedIn": false, "profile": NSNull()])
            return
        }
        let pr = p.progress
        let level = pr.computedLevel
        var next: Any = NSNull()
        if let n = pr.nextLevel {
            next = ["level": n.level, "xp": n.xp, "hours": n.hours, "clicks": n.clicks, "overall": n.overall,
                    "xpRequired": Leveling.xpRequired(n.level), "hoursRequired": Leveling.hoursRequired(n.level),
                    "clicksRequired": Leveling.clicksRequired(n.level)] as [String: Any]
        }
        var unlocked: [String: Double] = [:]
        for (id, d) in pr.unlocked { unlocked[id] = d.timeIntervalSince1970 }
        var values: [String: Double] = [:]
        for a in AchievementCatalog.all { if let v = pr.value(for: a) { values[a.id] = v } }
        Out.emit("profile", [
            "signedIn": true,
            "preview": live == nil,
            "profile": [
                "id": p.id.uuidString, "name": p.name, "initials": p.initials, "color": p.color,
                "level": level, "rank": EngineerRank.of(level: level).rawValue, "xp": pr.xp, "hours": pr.hours,
                "clicks": pr.clicks, "next": next, "counters": pr.counters, "unlocked": unlocked, "values": values,
            ] as [String: Any],
        ])
    }

    /// Achievements, ranks and the level curve (the core's), sent once.
    private func emitCatalog() {
        let achievements = AchievementCatalog.all.map { a -> [String: Any] in
            var o: [String: Any] = ["id": a.id, "category": a.category.rawValue, "title": Self.lt(a.title),
                                    "text": Self.lt(a.text), "rarity": a.rarity.rawValue, "xp": a.rarity.xp]
            if let h = a.hint { o["hint"] = Self.lt(h) }
            if let t = a.target { o["target"] = t.value }
            return o
        }
        Out.emit("profileCatalog", [
            "achievements": achievements,
            "categories": AchievementCategory.allCases.map { ["id": $0.rawValue, "name": Self.lt($0.name)] as [String: Any] },
            "rarities": AchievementRarity.allCases.map { ["name": Self.lt($0.name), "xp": $0.xp] as [String: Any] },
            "ranks": EngineerRank.allCases.map {
                ["name": Self.lt($0.name), "title": Self.lt($0.title), "from": $0.levels.lowerBound, "to": $0.levels.upperBound] as [String: Any]
            },
            "levels": (1...Leveling.maxLevel).map {
                ["level": $0, "xp": Leveling.xpRequired($0), "hours": Leveling.hoursRequired($0), "clicks": Leveling.clicksRequired($0)] as [String: Any]
            },
            "avatarColors": LocalProfile.avatarColors,
        ])
    }

    /// The profile of the Mac snapshot tests (SnapshotTests.sampleProfile).
    static var sampleProfile: LocalProfile {
        var p = LocalProfile(name: "Никита Г.", email: "", role: "foh", color: 0x2A4B3E, salt: "s", passwordHash: "")
        var pr = PlayerProgress()
        pr.activeSeconds = 162.4 * 3600
        pr.clicks = 2410
        pr.clickXP = 2410
        pr.bonusXP = 3200
        pr.counters = ["qtrl.go": 640, "setup.finished": 12, "time.night": 1, "app.launch": 30, "foh.wave": 1,
                       "qtrl.doubleGo": 1, "ptch.maxPhantom": 24, "setup.noiseSeconds": 2000]
        let d = Date(timeIntervalSince1970: 1_790_000_000)
        for (i, id) in ["firstSound", "nightOwl", "doubleGo", "phantomPain", "stadiumWave", "go", "secretRoom"].enumerated() {
            pr.unlocked[id] = d.addingTimeInterval(Double(i) * 3600)
        }
        pr.level = pr.computedLevel
        p.progress = pr
        return p
    }
}
