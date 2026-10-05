import AppKit
import Combine
import SSMTCore

/// Profiles on this Mac, the signed-in one, and the progress engine: input monitoring, active time,
/// events from the five functions, achievement toasts and level-ups.
@MainActor
final class ProfileCenter: ObservableObject {
    static let shared = ProfileCenter()

    @Published private(set) var profiles: [LocalProfile] = []
    /// The signed-in profile as the interface shows it: refreshed at most every 2 s, and at once when something
    /// is unlocked. Clicks and ticks change `live` only, so they never redraw the whole app.
    @Published private(set) var current: LocalProfile?
    private var live: LocalProfile?
    private var lastPublish = Date.distantPast
    /// Signed in or not — the only thing the root view watches.
    let gate = SessionGate()
    /// Achievements waiting to be shown as toasts (first = on screen).
    @Published var toasts: [String] = []
    @Published var levelUp: Int?
    @Published var showProfile = false

    static let avatarColors = LocalProfile.avatarColors
    static let roles = LocalProfile.roles

    private var monitor: Any?
    private var ticker: Timer?
    private var lastInput = Date.distantPast
    private var sessionStart = Date()
    private var sessionSections = Set<String>()
    private var lastSave = Date()
    // Bursts for the input achievements.
    private var input = ProfileInputTracker()
    /// App state sampled by the ticker (noise on, generator level, mic level…).
    var sample: (() -> Void)?

    private static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SSMT/Profiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static var library: ProfileLibrary { ProfileLibrary(folder: folder) }

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
        profiles = Self.library.load()
    }

    typealias AccountError = ProfileAccountError

    func register(name: String, email: String, password: String, repeat again: String, role: String, color: Int,
                  autoLogin: Bool) throws {
        let p = try ProfileLibrary.makeProfile(name: name, email: email, password: password, repeat: again, role: role,
                                               color: color, existing: profiles)
        write(p)
        loadProfiles()
        signIn(p, autoLogin: autoLogin)
    }

    func login(_ id: LocalProfile.ID, password: String, autoLogin: Bool) throws {
        let p = try ProfileLibrary.login(id, password: password, in: profiles)
        signIn(p, autoLogin: autoLogin)
    }

    private func signIn(_ p: LocalProfile, autoLogin: Bool) {
        if autoLogin { UserDefaults.standard.set(p.id.uuidString, forKey: Self.autoLoginKey) }
        else { UserDefaults.standard.removeObject(forKey: Self.autoLoginKey) }
        begin(p)
    }

    private func begin(_ p: LocalProfile) {
        live = p
        current = p
        gate.signedIn = true
        sessionStart = Date()
        sessionSections = []
        lastInput = Date()
        live?.progress.recordLaunch(at: Date())
        startMonitoring()
        evaluate()
    }

    func logout() {
        save()
        UserDefaults.standard.removeObject(forKey: Self.autoLoginKey)
        live = nil
        current = nil
        gate.signedIn = false
        toasts = []
        levelUp = nil
        showProfile = false
        loadProfiles()
    }

    func save() {
        guard let p = live else { return }
        write(p)
        lastSave = Date()
    }

    private func write(_ p: LocalProfile) {
        Self.library.write(p)
    }

    /// Quitting within ten seconds of the session start ("Just looking").
    func appWillQuit() {
        if live != nil, Date().timeIntervalSince(sessionStart) < 10 { record("app.quickQuit") }
        save()
    }

    // MARK: Events from the functions

    func record(_ event: String, count: Int = 1) {
        guard live != nil else { return }
        live?.progress.record(event, count: count)
        evaluate()
    }

    func recordMax(_ key: String, _ value: Int) {
        guard let p = live, value > p.progress.counters[key, default: 0] else { return }
        live?.progress.recordMax(key, value)
        evaluate()
    }

    func insert(_ item: String, into set: String) {
        guard let p = live, !p.progress.sets[set, default: []].contains(item) else { return }
        live?.progress.insert(item, into: set)
        evaluate()
    }

    func sectionOpened(_ name: String) {
        insert(name, into: "sections")
        sessionSections.insert(name)
        if sessionSections.count >= 5 { record("session.allSections") }
    }

    private func evaluate() {
        guard live != nil, let u = live?.progress.evaluate(at: Date()), !u.isEmpty else {
            publish()
            return
        }
        publish(force: true)
        toasts += u.achievements
        if let l = u.newLevel, l > 1 { levelUp = l }
        save()
    }

    /// Copies the live profile to the interface (throttled).
    private func publish(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastPublish) >= 2 else { return }
        lastPublish = Date()
        current = live
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
        guard live != nil else { return }
        let now = Date()
        lastInput = now
        guard var progress = live?.progress else { return }
        switch e.type {
        case .leftMouseDown, .rightMouseDown:
            let spot = e.locationInWindow
            input.click(at: now, x: Double(spot.x), y: Double(spot.y), progress: &progress)
        case .keyDown:
            input.key(at: now, command: e.modifierFlags.contains(.command), shift: e.modifierFlags.contains(.shift),
                      key: e.charactersIgnoringModifiers ?? "", progress: &progress)
        default: break
        }
        live?.progress = progress
        evaluate()
    }

    private func tick() {
        guard live != nil else { return }
        let active = Date().timeIntervalSince(lastInput) < 120 && NSApp.isActive
        live?.progress.tick(seconds: 5, active: active, at: Date())
        sample?()
        evaluate()
        if Date().timeIntervalSince(lastSave) > 30 { save() }
    }

    // MARK: Previews

    /// Snapshot tests: show a made-up profile without monitoring input or saving. Nothing is tracked
    /// (`live` stays empty), so activity in the test host cannot unlock achievements mid-snapshot.
    func preview(_ p: LocalProfile?) {
        live = nil
        current = p
        gate.signedIn = p != nil
        toasts = []
        levelUp = nil
    }

    // MARK: Display

    var progress: PlayerProgress { current?.progress ?? PlayerProgress() }
}

/// Signed in or not: the root view switches between the account card and the app on this alone.
@MainActor
final class SessionGate: ObservableObject {
    @Published var signedIn = false
}
