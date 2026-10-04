import AppKit
import Combine
import CryptoKit
import SSMTCore

/// A local engineer profile: name, password and everything earned. One JSON file per profile.
struct LocalProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var email: String
    var role: String
    var color: Int
    var createdAt = Date()
    var salt: String
    var passwordHash: String
    var progress = PlayerProgress()

    static func hash(_ password: String, salt: String) -> String {
        SHA256.hash(data: Data((salt + password).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func check(_ password: String) -> Bool { Self.hash(password, salt: salt) == passwordHash }

    var initials: String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "." }).prefix(2)
        let s = words.compactMap(\.first).map(String.init).joined().uppercased()
        return s.isEmpty ? "?" : s
    }
}

/// Profiles on this Mac, the signed-in one, and the progress engine: input monitoring, active time,
/// events from the five functions, achievement toasts and level-ups.
@MainActor
final class ProfileCenter: ObservableObject {
    static let shared = ProfileCenter()

    @Published private(set) var profiles: [LocalProfile] = []
    @Published private(set) var current: LocalProfile?
    /// Achievements waiting to be shown as toasts (first = on screen).
    @Published var toasts: [String] = []
    @Published var levelUp: Int?
    @Published var showProfile = false

    static let avatarColors = [0x2A4B3E, 0x23405A, 0x43305A, 0x5A2E2E, 0x5A4A2A]
    static let roles = ["foh", "monitors", "system", "theatre", "studio", "learning"]

    private var monitor: Any?
    private var ticker: Timer?
    private var lastInput = Date.distantPast
    private var sessionStart = Date()
    private var sessionSections = Set<String>()
    private var lastSave = Date()
    // Bursts for the input achievements.
    private var clickTimes: [Date] = []
    private var clickSpots: [(Date, CGPoint)] = []
    private var keyTimes: [Date] = []
    /// App state sampled by the ticker (noise on, generator level, mic level…).
    var sample: (() -> Void)?

    private static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SSMT/Profiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static let autoLoginKey = "ssmt.profile.auto"

    init() {
        loadProfiles()
        if let s = UserDefaults.standard.string(forKey: Self.autoLoginKey), let id = UUID(uuidString: s),
           let p = profiles.first(where: { $0.id == id }) {
            begin(p)
        }
    }

    // MARK: Accounts

    func loadProfiles() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? []
        profiles = urls.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(LocalProfile.self, from: Data(contentsOf: $0)) }
            .sorted { $0.progress.activeSeconds > $1.progress.activeSeconds }
    }

    enum AccountError: String, Error { case emptyName, shortPassword, mismatch, nameTaken, wrongPassword }

    func register(name: String, email: String, password: String, repeat again: String, role: String, color: Int,
                  autoLogin: Bool) throws {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { throw AccountError.emptyName }
        guard password.count >= 4 else { throw AccountError.shortPassword }
        guard password == again else { throw AccountError.mismatch }
        guard !profiles.contains(where: { $0.name.caseInsensitiveCompare(n) == .orderedSame }) else { throw AccountError.nameTaken }
        let salt = UUID().uuidString
        let p = LocalProfile(name: n, email: email.trimmingCharacters(in: .whitespaces), role: role, color: color,
                             salt: salt, passwordHash: LocalProfile.hash(password, salt: salt))
        write(p)
        loadProfiles()
        signIn(p, autoLogin: autoLogin)
    }

    func login(_ id: LocalProfile.ID, password: String, autoLogin: Bool) throws {
        guard let p = profiles.first(where: { $0.id == id }), p.check(password) else { throw AccountError.wrongPassword }
        signIn(p, autoLogin: autoLogin)
    }

    private func signIn(_ p: LocalProfile, autoLogin: Bool) {
        if autoLogin { UserDefaults.standard.set(p.id.uuidString, forKey: Self.autoLoginKey) }
        else { UserDefaults.standard.removeObject(forKey: Self.autoLoginKey) }
        begin(p)
    }

    private func begin(_ p: LocalProfile) {
        current = p
        sessionStart = Date()
        sessionSections = []
        lastInput = Date()
        current?.progress.recordLaunch(at: Date())
        startMonitoring()
        evaluate()
    }

    func logout() {
        save()
        UserDefaults.standard.removeObject(forKey: Self.autoLoginKey)
        current = nil
        toasts = []
        levelUp = nil
        showProfile = false
        loadProfiles()
    }

    func save() {
        guard let p = current else { return }
        write(p)
        lastSave = Date()
    }

    private func write(_ p: LocalProfile) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(p).write(to: Self.folder.appendingPathComponent(p.id.uuidString + ".json"), options: .atomic)
    }

    /// Quitting within ten seconds of the session start ("Just looking").
    func appWillQuit() {
        if current != nil, Date().timeIntervalSince(sessionStart) < 10 { record("app.quickQuit") }
        save()
    }

    // MARK: Events from the functions

    func record(_ event: String, count: Int = 1) {
        guard current != nil else { return }
        current?.progress.record(event, count: count)
        evaluate()
    }

    func recordMax(_ key: String, _ value: Int) {
        guard let p = current, value > p.progress.counters[key, default: 0] else { return }
        current?.progress.recordMax(key, value)
        evaluate()
    }

    func insert(_ item: String, into set: String) {
        guard let p = current, !p.progress.sets[set, default: []].contains(item) else { return }
        current?.progress.insert(item, into: set)
        evaluate()
    }

    func sectionOpened(_ name: String) {
        insert(name, into: "sections")
        sessionSections.insert(name)
        if sessionSections.count >= 5 { record("session.allSections") }
    }

    private func evaluate() {
        guard current != nil, let u = current?.progress.evaluate(at: Date()), !u.isEmpty else { return }
        toasts += u.achievements
        if let l = u.newLevel, l > 1 { levelUp = l }
        save()
    }

    func dismissToast() { if !toasts.isEmpty { toasts.removeFirst() } }

    // MARK: Input and time

    private func startMonitoring() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) }
            return e
        }
        ticker = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func handle(_ e: NSEvent) {
        guard current != nil else { return }
        let now = Date()
        lastInput = now
        switch e.type {
        case .leftMouseDown, .rightMouseDown:
            current?.progress.recordClick(at: now)
            clickTimes = clickTimes.filter { now.timeIntervalSince($0) < 60 } + [now]
            if clickTimes.count >= 50 { current?.progress.record("input.burst") }
            let spot = e.locationInWindow
            clickSpots = clickSpots.filter { now.timeIntervalSince($0.0) < 3 && hypot($0.1.x - spot.x, $0.1.y - spot.y) < 6 } + [(now, spot)]
            if clickSpots.count >= 10 { current?.progress.record("input.woodpecker") }
        case .keyDown:
            keyTimes = keyTimes.filter { now.timeIntervalSince($0) < 1 } + [now]
            if keyTimes.count >= 15 { current?.progress.record("input.cat") }
            if e.modifierFlags.contains(.command) {
                current?.progress.record("key.shortcut")
                switch e.charactersIgnoringModifiers?.lowercased() ?? "" {
                case "z" where !e.modifierFlags.contains(.shift): current?.progress.record("key.undo")
                case "s": current?.progress.record("key.save")
                default: break
                }
            }
        default: break
        }
        evaluate()
    }

    private func tick() {
        guard current != nil else { return }
        let active = Date().timeIntervalSince(lastInput) < 120 && NSApp.isActive
        current?.progress.tick(seconds: 5, active: active, at: Date())
        sample?()
        evaluate()
        if Date().timeIntervalSince(lastSave) > 30 { save() }
    }

    // MARK: Previews

    /// Snapshot tests: show a made-up profile without monitoring input or saving.
    func preview(_ p: LocalProfile?) {
        current = p
        toasts = []
        levelUp = nil
    }

    // MARK: Display

    var progress: PlayerProgress { current?.progress ?? PlayerProgress() }
}
