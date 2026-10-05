import Foundation

/// A local engineer profile: name, password and everything earned. One JSON file per profile (the same file on
/// macOS and Windows: `<folder>/<id>.json`, pretty-printed with sorted keys).
public struct LocalProfile: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var name: String
    public var email: String
    public var role: String
    public var color: Int
    public var createdAt = Date()
    public var salt: String
    public var passwordHash: String
    public var progress = PlayerProgress()

    public init(id: UUID = UUID(), name: String, email: String, role: String, color: Int, createdAt: Date = Date(),
                salt: String, passwordHash: String, progress: PlayerProgress = PlayerProgress()) {
        self.id = id
        self.name = name
        self.email = email
        self.role = role
        self.color = color
        self.createdAt = createdAt
        self.salt = salt
        self.passwordHash = passwordHash
        self.progress = progress
    }

    /// SHA-256 of salt + password as lower-case hex.
    public static func hash(_ password: String, salt: String) -> String {
        SHA256Digest.hex(Array((salt + password).utf8))
    }

    public func check(_ password: String) -> Bool { Self.hash(password, salt: salt) == passwordHash }

    public var initials: String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "." }).prefix(2)
        let s = words.compactMap(\.first).map(String.init).joined().uppercased()
        return s.isEmpty ? "?" : s
    }

    /// Avatar colours offered when a profile is created.
    public static let avatarColors = [0x2A4B3E, 0x23405A, 0x43305A, 0x5A2E2E, 0x5A4A2A]
    public static let roles = ["foh", "monitors", "system", "theatre", "studio", "learning"]
}

/// Why a profile could not be created or opened (string keys `acc.err.<rawValue>`).
public enum ProfileAccountError: String, Error, Sendable {
    case emptyName, shortPassword, mismatch, nameTaken, wrongPassword
}

/// The profiles on this computer: one JSON file each in a folder.
public struct ProfileLibrary: Sendable {
    public let folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    /// Every readable profile, the most used first.
    public func load() -> [LocalProfile] {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }
            .compactMap { url -> LocalProfile? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(LocalProfile.self, from: data)
            }
            .sorted { $0.progress.activeSeconds > $1.progress.activeSeconds }
    }

    public func write(_ p: LocalProfile) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(p).write(to: folder.appendingPathComponent(p.id.uuidString + ".json"), options: .atomic)
    }

    /// A new profile after the checks of the account card (name, password length, repeat, unique name).
    public static func makeProfile(name: String, email: String, password: String, repeat again: String, role: String,
                                   color: Int, existing: [LocalProfile]) throws -> LocalProfile {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { throw ProfileAccountError.emptyName }
        guard password.count >= 4 else { throw ProfileAccountError.shortPassword }
        guard password == again else { throw ProfileAccountError.mismatch }
        guard !existing.contains(where: { $0.name.caseInsensitiveCompare(n) == .orderedSame }) else {
            throw ProfileAccountError.nameTaken
        }
        let salt = UUID().uuidString
        return LocalProfile(name: n, email: email.trimmingCharacters(in: .whitespaces), role: role, color: color,
                            salt: salt, passwordHash: LocalProfile.hash(password, salt: salt))
    }

    /// The profile if the password is right.
    public static func login(_ id: UUID, password: String, in profiles: [LocalProfile]) throws -> LocalProfile {
        guard let p = profiles.first(where: { $0.id == id }), p.check(password) else { throw ProfileAccountError.wrongPassword }
        return p
    }
}

/// Bursts of input for the input achievements (clicks per minute, clicks on one spot, keys per second, shortcuts).
/// The app reports every click and key press; the tracker records the events into the progress.
public struct ProfileInputTracker: Sendable {
    private var clickTimes: [Date] = []
    private var clickSpots: [(Date, Double, Double)] = []
    private var keyTimes: [Date] = []

    public init() {}

    public mutating func click(at now: Date, x: Double, y: Double, progress: inout PlayerProgress) {
        progress.recordClick(at: now)
        clickTimes = clickTimes.filter { now.timeIntervalSince($0) < 60 } + [now]
        if clickTimes.count >= 50 { progress.record("input.burst") }
        clickSpots = clickSpots.filter { now.timeIntervalSince($0.0) < 3 && hypot($0.1 - x, $0.2 - y) < 6 } + [(now, x, y)]
        if clickSpots.count >= 10 { progress.record("input.woodpecker") }
    }

    /// `command`: the shortcut modifier (⌘ on macOS, Ctrl on Windows); `key`: the character without modifiers.
    public mutating func key(at now: Date, command: Bool, shift: Bool, key: String, progress: inout PlayerProgress) {
        keyTimes = keyTimes.filter { now.timeIntervalSince($0) < 1 } + [now]
        if keyTimes.count >= 15 { progress.record("input.cat") }
        guard command else { return }
        progress.record("key.shortcut")
        switch key.lowercased() {
        case "z" where !shift: progress.record("key.undo")
        case "s": progress.record("key.save")
        default: break
        }
    }
}

/// SHA-256 (FIPS 180-4) without CryptoKit, so the same password hashes work on every platform.
enum SHA256Digest {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }

    static func digest(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var data = message
        let bitLength = UInt64(message.count) &* 8
        data.append(0x80)
        while data.count % 64 != 56 { data.append(0) }
        for i in stride(from: 56, through: 0, by: -8) { data.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(i))) }
        var w = [UInt32](repeating: 0, count: 64)
        for chunk in stride(from: 0, to: data.count, by: 64) {
            for i in 0..<16 {
                let b = chunk + i * 4
                let b0: UInt32 = UInt32(data[b]) << 24
                let b1: UInt32 = UInt32(data[b + 1]) << 16
                let b2: UInt32 = UInt32(data[b + 2]) << 8
                let b3: UInt32 = UInt32(data[b + 3])
                w[i] = b0 | b1 | b2 | b3
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                hh = g
                g = f
                f = e
                e = d &+ t1
                d = c
                c = b
                b = a
                a = t1 &+ t2
            }
            h[0] = h[0] &+ a
            h[1] = h[1] &+ b
            h[2] = h[2] &+ c
            h[3] = h[3] &+ d
            h[4] = h[4] &+ e
            h[5] = h[5] &+ f
            h[6] = h[6] &+ g
            h[7] = h[7] &+ hh
        }
        var out: [UInt8] = []
        out.reserveCapacity(32)
        for v in h {
            out.append(UInt8(truncatingIfNeeded: v >> 24))
            out.append(UInt8(truncatingIfNeeded: v >> 16))
            out.append(UInt8(truncatingIfNeeded: v >> 8))
            out.append(UInt8(truncatingIfNeeded: v))
        }
        return out
    }

    static func hex(_ message: [UInt8]) -> String {
        let digits = Array("0123456789abcdef")
        var s = ""
        for b in digest(message) {
            s.append(digits[Int(b >> 4)])
            s.append(digits[Int(b & 0x0F)])
        }
        return s
    }
}
