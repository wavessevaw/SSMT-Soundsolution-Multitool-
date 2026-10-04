import Foundation

/// Function #3: show playback. A show holds cue lists; a cue list holds cues; group cues hold
/// child cues. Everything is a value type so edits are cheap to diff, undo and save.

public enum CueKind: String, Codable, CaseIterable, Sendable {
    case audio, fade, group, wait, memo
    /// Sends an OSC message to a device (video server, lighting console, mixer…).
    case network
    case start, stop, pause, load, reset, goTo, target, arm, disarm, devamp

    /// Cues that act on another cue.
    public var needsTarget: Bool {
        switch self {
        case .fade, .start, .stop, .pause, .load, .reset, .goTo, .target, .arm, .disarm, .devamp: return true
        case .audio, .group, .wait, .memo, .network: return false
        }
    }
}

/// What happens after a cue is triggered.
public enum ContinueMode: String, Codable, CaseIterable, Sendable {
    /// Wait for the next GO.
    case none
    /// Trigger the next cue when this cue's post-wait has elapsed (counted from the action start).
    case autoContinue
    /// Trigger the next cue when this cue's action has finished.
    case autoFollow
}

/// How a group plays its children.
public enum GroupMode: String, Codable, CaseIterable, Sendable {
    /// The first child starts; the others follow through their own continue modes.
    case sequence
    /// All children start together (each after its own pre-wait).
    case simultaneous
    /// Children play one after another automatically (optionally looping / shuffled).
    case playlist
    /// One random child plays.
    case random
}

/// How a one-shot pad reacts to a press.
public enum PadMode: String, Codable, CaseIterable, Sendable {
    /// Every press starts the cue (a running cue keeps playing).
    case start
    /// Press starts, the next press stops.
    case toggle
    /// Every press starts the cue from the beginning.
    case restart
    /// Plays while the pad or key is held.
    case hold
}

/// Shape of a fade.
public enum FadeCurve: String, Codable, CaseIterable, Sendable {
    /// Smooth S-shaped curve in decibels: natural for most fades.
    case sCurve
    /// Straight line in decibels.
    case linearDB
    /// Straight line in amplitude (sounds fast at the end of a fade-out).
    case linearGain

    /// Progress (0…1) → shaped progress used for interpolation.
    public func shape(_ t: Double) -> Double {
        let x = min(1, max(0, t))
        switch self {
        case .sCurve: return x * x * (3 - 2 * x)
        case .linearDB, .linearGain: return x
        }
    }
}

/// Lowest level treated as silence.
public let showSilenceDB: Double = -100

@inline(__always) public func showGain(_ db: Double) -> Double {
    db <= showSilenceDB ? 0 : pow(10, db / 20)
}

public struct AudioCueParams: Codable, Equatable, Sendable {
    /// File path; relative paths are resolved against the show file's folder.
    public var file: String = ""
    /// Region in seconds of the file; `end` nil = end of the file.
    public var start: Double = 0
    public var end: Double?
    /// Total number of plays of the region; 0 = loop until stopped or devamped.
    public var plays: Int = 1
    /// Playback rate (1 = normal; changes pitch too).
    public var rate: Double = 1
    /// Main level of the cue (dB).
    public var level: Double = 0
    /// Level of each show output (dB); missing entries = 0 dB.
    public var outputLevels: [Double] = []
    /// Crosspoints: `routing[fileChannel][output]` in dB; `showSilenceDB` or below = not routed.
    /// Empty = default routing (mono → outputs 1+2, stereo → 1/2, more channels → 1:1).
    public var routing: [[Double]] = []
    /// Optional loop inside the region (file seconds): the intro plays once, this part `plays`
    /// times (0 = until devamp / stop), then the rest. nil = the whole region loops.
    public var loopStart: Double?
    public var loopEnd: Double?
    /// Built-in fade-in at start and fade-out at the end of the region (seconds).
    public var fadeIn: Double = 0
    public var fadeOut: Double = 0

    public init(file: String = "") { self.file = file }

    public func outputLevel(_ o: Int) -> Double { o < outputLevels.count ? outputLevels[o] : 0 }

    /// Crosspoint gain in dB, with the default routing applied.
    public func crosspoint(channel c: Int, output o: Int, fileChannels: Int) -> Double {
        if c < routing.count {
            let row = routing[c]
            return o < row.count ? row[o] : showSilenceDB
        }
        switch fileChannels {
        case 1: return o <= 1 ? 0 : showSilenceDB
        default: return c == o ? 0 : showSilenceDB
        }
    }
}

public struct FadeCueParams: Codable, Equatable, Sendable {
    public var duration: Double = 3
    public var curve: FadeCurve = .sCurve
    /// New main level; nil = main level unchanged.
    public var level: Double? = showSilenceDB
    /// New output levels (index = output); nil entries are unchanged.
    public var outputLevels: [Double?] = []
    /// Stop the target when the fade is done (typical for fade-outs).
    public var stopWhenDone: Bool = true
    /// QLab's relative fade: `level` is added to the target's current level (e.g. −6 dB) instead of replacing it.
    public var relative: Bool = false
    /// Fade in: if the target is not playing, the fade starts it from silence and brings it up (to `level`, or to
    /// the target's own level when `level` is nil).
    public var fromSilence: Bool = false
    public init() {}

    /// A fade-out (to silence, then stop) or a fade-in (from silence up to the target's level).
    public static func preset(fadeIn: Bool) -> FadeCueParams {
        var f = FadeCueParams()
        f.fromSilence = fadeIn
        f.stopWhenDone = !fadeIn
        f.level = fadeIn ? nil : showSilenceDB
        return f
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 3
        curve = try c.decodeIfPresent(FadeCurve.self, forKey: .curve) ?? .sCurve
        level = try c.decodeIfPresent(Double.self, forKey: .level)
        outputLevels = try c.decodeIfPresent([Double?].self, forKey: .outputLevels) ?? []
        stopWhenDone = try c.decodeIfPresent(Bool.self, forKey: .stopWhenDone) ?? true
        relative = try c.decodeIfPresent(Bool.self, forKey: .relative) ?? false
        fromSilence = try c.decodeIfPresent(Bool.self, forKey: .fromSilence) ?? false
    }
}

public struct Cue: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: CueKind
    /// Free-form number shown in the list ("1", "12.5", "A").
    public var number: String
    public var name: String
    public var notes: String
    /// Colour tag name (UI palette key), empty = none.
    public var color: String
    public var preWait: Double
    public var postWait: Double
    public var continueMode: ContinueMode
    public var armed: Bool
    /// Single-character hotkey that triggers this cue directly (nil = none).
    public var hotkey: String?
    public var target: UUID?
    /// Target cue: the new target given to `target`.
    public var newTarget: UUID?
    /// Wait cue duration (seconds).
    public var duration: Double
    public var audio: AudioCueParams?
    public var fade: FadeCueParams?
    public var osc: OSCCueParams?
    public var groupMode: GroupMode
    /// Playlist: loop forever / shuffle order.
    public var loopPlaylist: Bool
    public var shuffle: Bool
    /// Playlist: the next entry starts this many seconds before the current one ends, the two crossfading.
    public var crossfade: Double
    /// Stop cue: fade the target out over this time instead of cutting it.
    public var stopFade: Double
    /// Devamp: also trigger the next cue in the list when the target leaves its loop.
    public var devampStartsNext: Bool
    /// One-shot pads only: reaction to a press.
    public var padMode: PadMode
    public var children: [Cue]

    public init(kind: CueKind, id: UUID = UUID(), number: String = "", name: String = "") {
        self.id = id
        self.kind = kind
        self.number = number
        self.name = name
        notes = ""
        color = ""
        preWait = 0
        postWait = 0
        continueMode = .none
        armed = true
        hotkey = nil
        target = nil
        newTarget = nil
        duration = kind == .wait ? 5 : 0
        audio = kind == .audio ? AudioCueParams() : nil
        fade = kind == .fade ? FadeCueParams() : nil
        osc = kind == .network ? OSCCueParams() : nil
        groupMode = .sequence
        loopPlaylist = false
        shuffle = false
        crossfade = 0
        stopFade = 0
        devampStartsNext = false
        padMode = .toggle
        children = []
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(CueKind.self, forKey: .kind)
        number = try c.decodeIfPresent(String.self, forKey: .number) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? ""
        preWait = try c.decodeIfPresent(Double.self, forKey: .preWait) ?? 0
        postWait = try c.decodeIfPresent(Double.self, forKey: .postWait) ?? 0
        continueMode = try c.decodeIfPresent(ContinueMode.self, forKey: .continueMode) ?? .none
        armed = try c.decodeIfPresent(Bool.self, forKey: .armed) ?? true
        hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey)
        target = try c.decodeIfPresent(UUID.self, forKey: .target)
        newTarget = try c.decodeIfPresent(UUID.self, forKey: .newTarget)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        audio = try c.decodeIfPresent(AudioCueParams.self, forKey: .audio)
        fade = try c.decodeIfPresent(FadeCueParams.self, forKey: .fade)
        osc = try c.decodeIfPresent(OSCCueParams.self, forKey: .osc)
        groupMode = try c.decodeIfPresent(GroupMode.self, forKey: .groupMode) ?? .sequence
        loopPlaylist = try c.decodeIfPresent(Bool.self, forKey: .loopPlaylist) ?? false
        shuffle = try c.decodeIfPresent(Bool.self, forKey: .shuffle) ?? false
        crossfade = try c.decodeIfPresent(Double.self, forKey: .crossfade) ?? 0
        stopFade = try c.decodeIfPresent(Double.self, forKey: .stopFade) ?? 0
        devampStartsNext = try c.decodeIfPresent(Bool.self, forKey: .devampStartsNext) ?? false
        padMode = try c.decodeIfPresent(PadMode.self, forKey: .padMode) ?? .toggle
        children = try c.decodeIfPresent([Cue].self, forKey: .children) ?? []
    }
}

public struct CueList: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var cues: [Cue]
    /// A bank of one-shot pads: its cues are triggered directly (pads, F-keys), never by GO.
    public var isBank: Bool
    public init(id: UUID = UUID(), name: String, cues: [Cue] = [], isBank: Bool = false) {
        self.id = id
        self.name = name
        self.cues = cues
        self.isBank = isBank
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        cues = try c.decodeIfPresent([Cue].self, forKey: .cues) ?? []
        isBank = try c.decodeIfPresent(Bool.self, forKey: .isBank) ?? false
    }
}

/// One output of the show, patched to a channel of the audio interface.
public struct ShowOutput: Codable, Equatable, Sendable {
    public var name: String
    /// Interface output channel (0-based); nil = not patched.
    public var deviceChannel: Int?
    public init(name: String, deviceChannel: Int?) {
        self.name = name
        self.deviceChannel = deviceChannel
    }
}

public struct ShowDocument: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var name: String
    public var lists: [CueList]
    public var outputs: [ShowOutput]
    /// Audio interface UID (nil = system default output).
    public var deviceUID: String?
    /// OSC devices the show talks to.
    public var devices: [OSCDevice]
    /// Panic: first press fades everything out over this time; a second press cuts at once.
    public var panicFade: Double
    /// Minimum time between two GOs (protects against a double press).
    public var doubleGoGuard: Double

    public init(name: String = "") {
        version = Self.currentVersion
        self.name = name
        lists = [CueList(name: "Main"), CueList(name: "Bank 1", isBank: true)]
        outputs = (0..<8).map { ShowOutput(name: "\($0 + 1)", deviceChannel: $0) }
        deviceUID = nil
        devices = []
        panicFade = 1.5
        doubleGoGuard = 0.3
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        lists = try c.decodeIfPresent([CueList].self, forKey: .lists) ?? [CueList(name: "Main")]
        if !lists.contains(where: { !$0.isBank }) { lists.insert(CueList(name: "Main"), at: 0) }
        outputs = try c.decodeIfPresent([ShowOutput].self, forKey: .outputs) ?? []
        deviceUID = try c.decodeIfPresent(String.self, forKey: .deviceUID)
        devices = try c.decodeIfPresent([OSCDevice].self, forKey: .devices) ?? []
        panicFade = try c.decodeIfPresent(Double.self, forKey: .panicFade) ?? 1.5
        doubleGoGuard = try c.decodeIfPresent(Double.self, forKey: .doubleGoGuard) ?? 0.3
    }

    public enum DecodeError: Error { case newerVersion(Int) }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }

    public static func decode(_ data: Data) throws -> ShowDocument {
        let d = try JSONDecoder().decode(ShowDocument.self, from: data)
        if d.version > currentVersion { throw DecodeError.newerVersion(d.version) }
        return d
    }
}

// MARK: - Tree helpers

extension Array where Element == Cue {
    /// Depth-first search.
    public func findCue(_ id: UUID) -> Cue? {
        for c in self {
            if c.id == id { return c }
            if let f = c.children.findCue(id) { return f }
        }
        return nil
    }

    /// Applies `change` to the cue with `id` anywhere in the tree. Returns true if found.
    @discardableResult
    public mutating func updateCue(_ id: UUID, _ change: (inout Cue) -> Void) -> Bool {
        for i in indices {
            if self[i].id == id { change(&self[i]); return true }
            if self[i].children.updateCue(id, change) { return true }
        }
        return false
    }

    /// Removes the cues with the given ids anywhere in the tree; returns them in tree order.
    @discardableResult
    public mutating func removeCues(_ ids: Set<UUID>) -> [Cue] {
        var removed: [Cue] = []
        var kept: [Cue] = []
        for var c in self {
            if ids.contains(c.id) { removed.append(c); continue }
            removed += c.children.removeCues(ids)
            kept.append(c)
        }
        self = kept
        return removed
    }

    /// All cues depth-first with their depth.
    public func flattened(depth: Int = 0, collapsed: Set<UUID> = []) -> [(cue: Cue, depth: Int)] {
        var out: [(Cue, Int)] = []
        for c in self {
            out.append((c, depth))
            if !collapsed.contains(c.id) { out += c.children.flattened(depth: depth + 1, collapsed: collapsed) }
        }
        return out
    }

    /// Path (indices) to a cue.
    public func path(of id: UUID) -> [Int]? {
        for (i, c) in enumerated() {
            if c.id == id { return [i] }
            if let p = c.children.path(of: id) { return [i] + p }
        }
        return nil
    }
}

extension ShowDocument {
    public func list(_ id: UUID?) -> CueList? { lists.first { $0.id == id } ?? cueLists.first }

    /// Cue lists played with GO (not one-shot banks).
    public var cueLists: [CueList] { lists.filter { !$0.isBank } }
    /// One-shot banks.
    public var banks: [CueList] { lists.filter(\.isBank) }

    /// F-key name ("F1"…) of a hotkey, used by pads.
    public static let functionKeys = (1...12).map { "F\($0)" }

    /// Finds a cue in any list.
    public func cue(_ id: UUID?) -> Cue? {
        guard let id else { return nil }
        for l in lists { if let c = l.cues.findCue(id) { return c } }
        return nil
    }

    /// Every cue of every list, depth-first.
    public var allCues: [Cue] { lists.flatMap { $0.cues.flattened().map(\.cue) } }

    @discardableResult
    public mutating func updateCue(_ id: UUID, _ change: (inout Cue) -> Void) -> Bool {
        for i in lists.indices where lists[i].cues.updateCue(id, change) { return true }
        return false
    }

    /// Next free number after the highest integer number in use.
    public var nextCueNumber: String {
        let top = allCues.compactMap { Double($0.number) }.max() ?? 0
        return String(Int(top.rounded(.down)) + 1)
    }
}
