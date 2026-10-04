import Foundation

/// A cue that is currently waiting or playing, as shown in the UI.
public struct RunningCue: Equatable, Identifiable, Sendable {
    public enum Phase: String, Sendable { case preWait, running, stopping }
    public var id: UUID
    public var phase: Phase
    /// Seconds elapsed in the current phase.
    public var elapsed: Double
    /// Pre-wait length (pre-wait phase) or action length (running); nil = open-ended (loops, groups).
    public var duration: Double?
    public var paused: Bool
    /// Current loop iteration (1-based) of a looping audio cue.
    public var iteration: Int?

    public init(id: UUID, phase: Phase, elapsed: Double, duration: Double?, paused: Bool, iteration: Int?) {
        self.id = id
        self.phase = phase
        self.elapsed = elapsed
        self.duration = duration
        self.paused = paused
        self.iteration = iteration
    }

    public var remaining: Double? { duration.map { max(0, $0 - elapsed) } }
    public var progress: Double? { duration.map { $0 > 0 ? min(1, max(0, elapsed / $0)) : 1 } }
}

public struct ShowSnapshot: Equatable, Sendable {
    public var listID: UUID?
    public var playhead: UUID?
    public var running: [RunningCue]
    /// Cues that could not play (missing file…), most recent last.
    public var problems: [UUID: String]
    /// Cues loaded to a time (⌘T, a click in a group timeline's ruler): where their next start begins, in seconds.
    public var loaded: [UUID: Double]
    public init(listID: UUID?, playhead: UUID?, running: [RunningCue], problems: [UUID: String], loaded: [UUID: Double] = [:]) {
        self.listID = listID
        self.playhead = playhead
        self.running = running
        self.problems = problems
        self.loaded = loaded
    }
    public static let empty = ShowSnapshot(listID: nil, playhead: nil, running: [], problems: [:])
}

/// Show logic: GO, playhead, pre/post-wait, auto-continue/follow, groups and control cues.
/// Time is the mixer's output frame clock, so audio starts land on exact samples. Actions are
/// scheduled `lookahead` frames ahead of the clock and sent to the mixer as `MixerOp`s.
/// Not thread-safe: confine to one serial queue.
public final class ShowEngine {
    public var document: ShowDocument { didSet { keepPlayhead(after: oldValue); stopRemovedCues() } }

    /// A cue deleted while it plays (or waits) stops at once, with a short de-click fade (QLab).
    private func stopRemovedCues() {
        let gone = instances.keys.filter { document.cue($0) == nil }
        guard !gone.isEmpty else { return }
        let t = (lastAdvance ?? 0) + lookahead
        for id in gone where instances[id] != nil { terminate(id, at: t, fade: frames(0.02)) }
    }
    public let sampleRate: Double
    public var lookahead: Int64
    /// Receives mixer operations.
    public var send: (MixerOp) -> Void
    /// Returns the decoded clip of an audio cue (nil = not available).
    public var clipProvider: (Cue) -> AudioClip?
    /// True when a cue's file exists and is still being prepared (decoded into the cache), so GO waits for
    /// it instead of reporting it missing. False for a missing or unreadable file.
    public var clipPending: (Cue) -> Bool = { _ in false }
    /// Sends an OSC message to a show device.
    public var oscSend: (OSCDevice, OSCMessage) -> Void = { _, _ in }
    /// Called by Load cues.
    public var preload: (Cue) -> Void = { _ in }
    /// Called when a cue changes the document (Arm, Disarm, Target).
    public var documentChanged: (ShowDocument) -> Void = { _ in }
    /// Random source for random groups and shuffled playlists (0..<1).
    public var random: () -> Double = { Double.random(in: 0..<1) }

    public private(set) var listID: UUID?
    public private(set) var playhead: UUID?
    public private(set) var problems: [UUID: String] = [:]

    struct Instance {
        enum Phase { case preWait, running }
        var cueID: UUID
        var kind: CueKind
        var listID: UUID
        var parent: UUID?
        var phase: Phase = .preWait
        var triggered: Int64
        var actionAt: Int64
        var actionEnd: Int64?
        var actionEnded = false
        var postWaitAt: Int64?
        var follow = false
        var paused = false
        var pausedAt: Int64 = 0
        var pausedTotal: Int64 = 0
        var hasVoice = false
        var stopping = false
        var map = PlayMap(regionStart: 0, length: 1, plays: 1)
        var rate = 1.0
        var clip: AudioClip?
        var playlist: [UUID] = []
        var playlistIndex = 0
        /// Playlist group: it has wrapped around at least once (looping); entries it already crossfaded away from.
        var playlistWrapped = false
        var crossfaded: Set<UUID> = []
        /// Playlist entry: when the next entry starts (crossfade).
        var crossfadeAt: Int64?
        /// Audio: current main level (dB), for relative fades.
        var levelDB: Double = 0
        var stopTargetsAtEnd: [UUID] = []
        var holdTargets: [UUID] = []
        /// Fade cue: the level each target voice is heading to (re-sent after a pause), and the audio cues a fade-in
        /// marked to start silent (unmarked when the fade ends, so a cue it never started plays normally later).
        var fadeLevels: [UUID: Double?] = [:]
        var fadeInMarked: [UUID] = []
        var onEnd: (cue: UUID, list: UUID, parent: UUID?)?
        /// Audio file still being decoded at GO: retried until this frame, then reported missing.
        var awaitingClip: Int64?
        /// Started part-way (a group timeline loaded to a time): what is left of a fade or wait.
        var durationOverride: Double?
        /// Fade started part-way: seconds of it already behind (its targets jump to the level it would have reached).
        var fadeInto: Double = 0
    }

    /// How long an audio cue waits for a file that is still being prepared (just added) before it gives up.
    public var clipWaitSeconds = 15.0

    private(set) var instances: [UUID: Instance] = [:]
    private var lastGo: Int64?
    private var lastClipRetry: Int64?
    private var lastPanic: Int64?
    /// Clock of the latest `advance` (for actions that come without a time, like an edit).
    private var lastAdvance: Int64?

    public init(document: ShowDocument, sampleRate: Double, lookahead: Int64 = 1024,
                send: @escaping (MixerOp) -> Void, clipProvider: @escaping (Cue) -> AudioClip?) {
        self.document = document
        self.sampleRate = sampleRate
        self.lookahead = lookahead
        self.send = send
        self.clipProvider = clipProvider
        listID = document.cueLists.first?.id
        playhead = document.cueLists.first?.cues.first?.id
    }

    private func frames(_ seconds: Double) -> Int64 { Int64((max(0, seconds) * sampleRate).rounded()) }

    // MARK: Public control

    public func selectList(_ id: UUID) {
        guard let l = document.lists.first(where: { $0.id == id }), !l.isBank else { return }
        listID = id
        if playhead.flatMap({ sequence(of: $0)?.list }) != id { playhead = l.cues.first?.id }
    }

    /// After an edit: a playhead at the end of the list moves to the first cue added; a playhead on a deleted
    /// cue moves to the next remaining one. Otherwise GO would stay greyed out after adding cues.
    private func keepPlayhead(after old: ShowDocument) {
        guard let lid = listID, let list = document.lists.first(where: { $0.id == lid }), !list.isBank else {
            // The list itself is gone: start over on the first cue list.
            listID = document.cueLists.first?.id
            playhead = document.cueLists.first?.cues.first?.id
            return
        }
        let ids = list.cues.map(\.id)
        let before = old.lists.first { $0.id == lid }?.cues.map(\.id) ?? []
        if let ph = playhead, sequence(of: ph)?.list == lid { return }   // still there (also inside an entered group)
        if let ph = playhead {
            if ids.contains(ph) { return }
            if let i = before.firstIndex(of: ph) {
                playhead = before[(i + 1)...].first(where: ids.contains) ?? ids.first { !before.contains($0) }
            } else {
                playhead = ids.first
            }
        } else {
            playhead = ids.first { !before.contains($0) }
        }
    }

    /// Puts the playhead on a cue of a cue list, or inside a Start First And Enter group (nil = end of list).
    public func setPlayhead(_ id: UUID?) {
        guard let id else { playhead = nil; return }
        guard let seq = sequence(of: id) else { return }
        listID = seq.list
        playhead = id
    }

    /// Cues the GO playhead walks through that contain `id`: its cue list, or the children of the Start First And
    /// Enter group it is in (each enclosing group entered as well).
    private func sequence(of id: UUID) -> (list: UUID, cues: [Cue], parent: UUID?)? {
        for l in document.lists where !l.isBank {
            if l.cues.contains(where: { $0.id == id }) { return (l.id, l.cues, nil) }
            if let p = parentGroup(of: id, in: l.cues), let g = document.cue(p), g.groupMode == .enter,
               let outer = sequence(of: p) {
                return (outer.list, g.children, p)
            }
        }
        return nil
    }

    /// GO: triggers the cue on the playhead and moves the playhead past its continue chain.
    /// Returns false when ignored (no cue, or double-GO protection).
    @discardableResult
    public func go(now: Int64) -> Bool {
        if let last = lastGo, now - last < frames(document.doubleGoGuard) { return false }
        guard let ph = playhead, let seq = sequence(of: ph) else { return false }
        lastGo = now
        trigger(ph, list: seq.list, parent: seq.parent, at: now + lookahead)
        standBy(after: ph)
        advance(to: now)
        return true
    }

    /// After `id` has been started: the playhead goes to the next cue that is not started along with it (past its
    /// continue chain) — into a Start First And Enter group, and out of one after its last child.
    private func standBy(after id: UUID, entering: Bool = true) {
        guard let seq = sequence(of: id), let i = seq.cues.firstIndex(where: { $0.id == id }) else { return }
        listID = seq.list
        let cue = seq.cues[i]
        if entering, cue.kind == .group, cue.groupMode == .enter, cue.armed, let n = next(in: cue.children, after: 0) {
            playhead = n
            return
        }
        if let n = next(in: seq.cues, after: i) { playhead = n; return }
        // The last cue of an entered group: on past the group (not into it again).
        if let p = seq.parent { standBy(after: p, entering: false) } else { playhead = nil }
    }

    private func next(in cues: [Cue], after i: Int) -> UUID? {
        guard i < cues.count else { return nil }
        var j = i
        while j < cues.count - 1, cues[j].continueMode != .none { j += 1 }
        return j + 1 < cues.count ? cues[j + 1].id : nil
    }

    /// Triggers any cue directly ("play this cue", preview, hotkeys). A top-level cue of a cue list moves the
    /// playhead past it, as GO does, so the next cue always stands by; one-shot pads and cues inside groups do not.
    public func start(_ id: UUID, now: Int64) {
        guard let (lid, parent) = location(of: id) else { return }
        trigger(id, list: lid, parent: parent, at: now + lookahead)
        if sequence(of: id) != nil { standBy(after: id) }
        advance(to: now)
    }

    /// One-shot pad press (`pressed`) or release, following the pad's mode.
    public func pad(_ id: UUID, pressed: Bool, now: Int64) {
        guard let cue = document.cue(id) else { return }
        let running = instances[id].map { !$0.stopping } ?? false
        let t = now + lookahead
        switch (cue.padMode, pressed) {
        case (.start, true):
            if !running { start(id, now: now); return }
        case (.toggle, true):
            if running { terminate(id, at: t, fade: frames(0.02)) } else { start(id, now: now); return }
        case (.restart, true):
            if running { terminate(id, at: t, fade: 0) }
            start(id, now: now)
            return
        case (.hold, true):
            if !running { start(id, now: now); return }
        case (.hold, false):
            terminate(id, at: t, fade: frames(0.02))
        default:
            break
        }
        advance(to: now)
    }

    /// Loads a cue (QLab "L"): its files are read in advance so it starts instantly.
    public func load(_ id: UUID) {
        if let c = document.cue(id) { preloadTree(c) }
    }

    /// Load to time (QLab ⌘T): the next start of this audio cue begins `seconds` into it (pre-wait excluded); for a
    /// timeline group, `seconds` into its timeline (everything already under way there starts part-way through).
    public func loadToTime(_ id: UUID, seconds: Double) {
        guard let c = document.cue(id) else { return }
        if c.kind == .audio {
            loadedTime[id] = max(0, seconds)
        } else if c.kind == .group && c.groupMode == .simultaneous {
            loadedGroupTime[id] = max(0, seconds)
        } else {
            return
        }
        preloadTree(c)
    }

    /// Timeline groups loaded to a time, and that time (seconds).
    public private(set) var loadedGroupTime: [UUID: Double] = [:]

    /// A click in a timeline group's ruler (QLab): a running group carries on from `seconds`; a group that is not
    /// running is loaded there for its next start. The cue list's playhead does not move.
    public func seek(_ group: UUID, to seconds: Double, now: Int64) {
        guard let c = document.cue(group), c.kind == .group, c.groupMode == .simultaneous else { return }
        guard let inst = instances[group], !inst.stopping else {
            loadToTime(group, seconds: seconds)
            return
        }
        let t = now + lookahead
        let paused = inst.paused
        terminate(group, at: t, fade: 0)
        advance(to: now)
        instances[group] = nil
        for (id, i) in instances where i.parent == group || isInside(id, group) { instances[id] = nil }
        loadedGroupTime[group] = max(0, seconds)
        // A few milliseconds later, so the restarted sounds never overlap the de-click of the stopped ones.
        let restart = t + frames(0.006)
        trigger(group, list: inst.listID, parent: inst.parent, at: restart, preWait: 0)
        advance(to: now)
        if paused { pauseInstance(group, at: restart) }
    }

    private func isInside(_ id: UUID, _ group: UUID) -> Bool {
        var p = location(of: id)?.1
        while let g = p {
            if g == group { return true }
            p = location(of: g)?.1
        }
        return false
    }

    /// Fades that reached an audio cue before its sound began (its file still being prepared, or starting at the same
    /// moment): applied when it starts, over what is left of the fade.
    private var deferredFades: [UUID: (fade: UUID, end: Int64, curve: FadeCurve, level: Double?, relative: Bool, outputs: [Double?])] = [:]

    /// Audio cues a fade-in has started: they begin silent and ramp up.
    private var pendingFadeIn: [UUID: (frames: Int64, curve: FadeCurve, levelDB: Double?)] = [:]

    /// Cues loaded to a time, and that time (seconds).
    public private(set) var loadedTime: [UUID: Double] = [:]

    public func isRunning(_ id: UUID) -> Bool { instances[id].map { !$0.stopping } ?? false }

    public func stop(_ id: UUID, now: Int64, fade: Double = 0) {
        terminate(id, at: now + lookahead, fade: frames(fade))
        advance(to: now)
    }

    public func pause(_ id: UUID, now: Int64) {
        pauseInstance(id, at: now + lookahead)
    }

    public func resume(_ id: UUID, now: Int64) {
        resumeInstance(id, at: now + lookahead)
        advance(to: now)
    }

    public func pauseAll(now: Int64) {
        for id in rootInstances { pauseInstance(id, at: now + lookahead) }
    }

    public func resumeAll(now: Int64) {
        for id in rootInstances { resumeInstance(id, at: now + lookahead) }
        advance(to: now)
    }

    /// Running cues not inside a running group: top-level cues, and cues of a group started on their own (V, the
    /// play button, a Start cue). "All" commands go through these; each reaches the cues inside it.
    private var rootInstances: [UUID] {
        instances.compactMap { id, inst in inst.parent.map { instances[$0] == nil } ?? true ? id : nil }
    }

    public var anyPaused: Bool { instances.values.contains { $0.paused } }
    public var isActive: Bool { !instances.isEmpty }

    /// Panic: the first press fades everything out over `panicFade`; a second press during that fade
    /// (or any press with `hard`) cuts everything at once.
    public func panic(now: Int64, hard: Bool = false) {
        let fade = frames(document.panicFade)
        let isSecond = lastPanic.map { now - $0 <= fade + frames(0.5) } ?? false
        let t = now + lookahead
        if hard || isSecond || fade == 0 {
            send(.stopAll(at: now, fadeFrames: 0))
            instances.removeAll()
            pendingFadeIn.removeAll()
            deferredFades.removeAll()
            lastPanic = nil
        } else {
            for id in rootInstances { terminate(id, at: t, fade: fade) }
            send(.stopAll(at: t, fadeFrames: fade))
            lastPanic = now
        }
        advance(to: now)
    }

    /// Processes everything due up to `now + lookahead`. Call often (every few milliseconds).
    public func advance(to now: Int64) {
        lastAdvance = now
        let horizon = now + lookahead
        retryAwaitingClips(now: now, at: horizon)
        var guardCount = 0
        while let (id, t, event) = nextEvent(upTo: horizon) {
            guardCount += 1
            if guardCount > 100_000 { break } // malformed show (e.g. zero-length loops)
            switch event {
            case .action: beginAction(id, at: t)
            case .postWait: postWaitElapsed(id, at: t)
            case .end: actionFinished(id, at: t)
            case .crossfade: crossfadeElapsed(id, at: t)
            }
        }
    }

    /// Reads the next `seconds` of every playing file into memory (mapped files), so the audio
    /// thread never waits for the disk. Call from the control queue a few times per second.
    public func prefetch(now: Int64, seconds: Double = 4) {
        for inst in instances.values where inst.hasVoice && !inst.actionEnded {
            guard let clip = inst.clip, clip.isMapped else { continue }
            let played = Double(max(0, now - inst.actionAt - inst.pausedTotal)) * inst.rate
            let step = sampleRate * 0.5 * inst.rate
            var p = played
            while p < played + seconds * sampleRate * inst.rate {
                if let total = inst.map.total, p >= total { break }
                clip.prefetch(from: Int(inst.map.position(p)), count: Int(step) + 1)
                p += step
            }
        }
    }

    public func snapshot(now: Int64) -> ShowSnapshot {
        var running: [RunningCue] = []
        for inst in instances.values {
            if inst.phase == .running && inst.actionEnded { continue }
            let clock = inst.paused ? inst.pausedAt : now
            switch inst.phase {
            case .preWait:
                let pre = Double(inst.actionAt - inst.triggered) / sampleRate
                running.append(RunningCue(id: inst.cueID, phase: .preWait,
                                          elapsed: max(0, Double(clock - inst.triggered) / sampleRate),
                                          duration: pre, paused: inst.paused, iteration: nil))
            case .running:
                let elapsedFrames = max(0, clock - inst.actionAt - inst.pausedTotal)
                let dur = inst.actionEnd.map { Double($0 - inst.actionAt - inst.pausedTotal) / sampleRate }
                var iteration: Int?
                if inst.hasVoice && inst.map.plays != 1 {
                    iteration = inst.map.iteration(Double(elapsedFrames) * inst.rate) + 1
                }
                running.append(RunningCue(id: inst.cueID, phase: inst.stopping ? .stopping : .running,
                                          elapsed: Double(elapsedFrames) / sampleRate, duration: dur,
                                          paused: inst.paused, iteration: iteration))
            }
        }
        // Stable order: as in the show.
        let order = Dictionary(uniqueKeysWithValues: document.allCues.enumerated().map { ($1.id, $0) })
        running.sort { (order[$0.id] ?? .max) < (order[$1.id] ?? .max) }
        return ShowSnapshot(listID: listID, playhead: playhead, running: running, problems: problems,
                            loaded: loadedTime.merging(loadedGroupTime) { a, _ in a })
    }

    // MARK: Structure

    /// List and parent group of a cue.
    private func location(of id: UUID) -> (UUID, UUID?)? {
        for l in document.lists {
            if l.cues.contains(where: { $0.id == id }) { return (l.id, nil) }
            if let p = parentGroup(of: id, in: l.cues) { return (l.id, p) }
        }
        return nil
    }

    private func parentGroup(of id: UUID, in cues: [Cue]) -> UUID? {
        for c in cues {
            if c.children.contains(where: { $0.id == id }) { return c.id }
            if let p = parentGroup(of: id, in: c.children) { return p }
        }
        return nil
    }

    private func siblings(list: UUID, parent: UUID?) -> [Cue] {
        if let parent { return document.cue(parent)?.children ?? [] }
        return document.list(list)?.cues ?? []
    }

    /// The cue after `id` among its siblings.
    private func next(after id: UUID, list: UUID, parent: UUID?) -> Cue? {
        let s = siblings(list: list, parent: parent)
        guard let i = s.firstIndex(where: { $0.id == id }), i + 1 < s.count else { return nil }
        return s[i + 1]
    }

    // MARK: Scheduling

    private enum Event { case action, postWait, end, crossfade }

    private func nextEvent(upTo horizon: Int64) -> (UUID, Int64, Event)? {
        var best: (UUID, Int64, Event)?
        var bestRank = 0
        // Events at the same frame: cues start before fades act, so a fade placed at the same moment as its target
        // (a group timeline with both at 1 s) fades the sound that starts then instead of finding nothing.
        func consider(_ id: UUID, _ t: Int64, _ e: Event, rank: Int = 0) {
            guard t <= horizon else { return }
            if best == nil || t < best!.1 || (t == best!.1 && rank < bestRank) { best = (id, t, e); bestRank = rank }
        }
        for (id, inst) in instances where !inst.paused {
            switch inst.phase {
            case .preWait: consider(id, inst.actionAt, .action, rank: inst.kind == .fade ? 1 : 0)
            case .running:
                if let p = inst.postWaitAt { consider(id, p, .postWait) }
                if !inst.actionEnded, let e = inst.actionEnd { consider(id, e, .end) }
                if !inst.actionEnded, !inst.stopping, let x = inst.crossfadeAt { consider(id, x, .crossfade) }
            }
        }
        return best
    }

    private func trigger(_ id: UUID, list: UUID, parent: UUID?, at t: Int64, preWait: Double? = nil, duration: Double? = nil) {
        guard let cue = document.cue(id) else { return }
        if let existing = instances[id] {
            if existing.paused { resumeInstance(id, at: t); return }
            if !existing.stopping { secondTrigger(cue, at: t); return }
            instances[id] = nil
        }
        var inst = Instance(cueID: id, kind: cue.kind, listID: list, parent: parent,
                            triggered: t, actionAt: t + frames(preWait ?? cue.preWait))
        inst.durationOverride = duration
        instances[id] = inst
    }

    /// Told to start while already running (QLab's second trigger).
    private func secondTrigger(_ cue: Cue, at t: Int64) {
        switch cue.secondTrigger {
        case .nothing:
            return
        case .panic:
            terminate(cue.id, at: t, fade: frames(document.panicFade))
        case .stop, .hardStop:
            terminate(cue.id, at: t, fade: 0)
        case .restart:
            guard let inst = instances[cue.id] else { return }
            terminate(cue.id, at: t, fade: 0)
            // After the de-click of the stopped sound.
            trigger(cue.id, list: inst.listID, parent: inst.parent, at: t + frames(0.006))
        case .devamp:
            devamp(cue.id, by: nil, at: t)
        case .playNext:
            playNext(cue.id, at: t)
        }
    }

    /// Playlist group told to start again: the next entry plays now, crossfading from the current one if set.
    private func playNext(_ group: UUID, at t: Int64) {
        guard let gc = document.cue(group), gc.kind == .group, gc.groupMode == .playlist, instances[group] != nil else { return }
        let current = instances.filter { $0.value.parent == group && !$0.value.stopping }.map(\.key)
        guard advancePlaylist(group, at: t) else { return }
        let fade = max(frames(gc.crossfade), frames(0.02))
        for c in current where instances[c]?.triggered != t {
            instances[group]?.crossfaded.insert(c)
            terminate(c, at: t, fade: fade)
        }
    }

    private func beginAction(_ id: UUID, at t: Int64) {
        guard var inst = instances[id], let cue = document.cue(id) else { instances[id] = nil; return }
        inst.phase = .running
        inst.actionAt = t
        inst.actionEnd = t
        inst.follow = cue.continueMode == .autoFollow
        inst.postWaitAt = cue.continueMode == .autoContinue ? t + frames(cue.postWait) : nil
        instances[id] = inst
        guard cue.armed else { return } // disarmed: no action, waits and continue still apply
        problems[id] = nil

        switch cue.kind {
        case .audio:
            startAudio(cue, at: t)
        case .wait:
            instances[id]?.actionEnd = t + frames(inst.durationOverride ?? cue.duration)
        case .memo:
            break
        case .network:
            if let p = cue.osc, let id = p.device, let device = document.devices.first(where: { $0.id == id }) {
                oscSend(device, p.message)
            } else {
                problems[cue.id] = "error.show.noDevice"
            }
        case .fade:
            startFade(cue, at: t)
        case .group:
            startGroup(cue, inst: inst, at: t)
        case .start:
            if let target = cue.target, let (lid, parent) = location(of: target) {
                trigger(target, list: lid, parent: parent, at: t)
            }
        case .stop:
            if let target = cue.target {
                terminate(target, at: t, fade: frames(cue.stopFade))
            } else {
                for other in rootInstances where other != id {
                    terminate(other, at: t, fade: frames(cue.stopFade))
                }
            }
        case .pause:
            if let target = cue.target { pauseInstance(target, at: t) }
        case .load:
            if let target = cue.target, let c = document.cue(target) {
                preloadTree(c)
            }
        case .reset:
            if let target = cue.target { terminate(target, at: t, fade: 0) }
        case .goTo:
            if let target = cue.target { setPlayhead(target) }
        case .target:
            if let target = cue.target {
                let newTarget = cue.newTarget
                if document.updateCue(target, { $0.target = newTarget }) { documentChanged(document) }
            }
        case .arm, .disarm:
            if let target = cue.target {
                let armed = cue.kind == .arm
                if document.updateCue(target, { $0.armed = armed }) { documentChanged(document) }
            }
        case .devamp:
            if let target = cue.target { devamp(target, by: cue, at: t) }
        }
    }

    private func preloadTree(_ c: Cue) {
        if c.kind == .audio { preload(c) }
        c.children.forEach(preloadTree)
    }

    private func startAudio(_ cue: Cue, at t: Int64) {
        guard let clip = clipProvider(cue) else {
            guard clipPending(cue) else {
                problems[cue.id] = "error.show.missingFile"
                return
            }
            // Not decoded yet (e.g. dropped in a moment ago): wait for it instead of failing at once.
            instances[cue.id]?.awaitingClip = t + frames(clipWaitSeconds)
            instances[cue.id]?.actionEnd = nil
            problems[cue.id] = "error.show.notReady"
            return
        }
        var playing = cue
        let xf = playlistCrossfade(cue.id)
        if let xf, var a = playing.audio {
            if !xf.first { a.fadeIn = max(a.fadeIn, xf.seconds) }
            if xf.hasNext { a.fadeOut = max(a.fadeOut, xf.seconds) }
            playing.audio = a
        }
        guard var setup = Self.voiceSetup(playing, clip: clip, outputs: document.outputs.count) else {
            problems[cue.id] = "error.show.missingFile"
            instances[cue.id]?.actionEnd = t   // nothing to play: the cue ends now and the chain goes on
            return
        }
        // Loaded to a time: start that far in; the cue's clock and end move accordingly.
        var skip: Int64 = 0
        if let s = loadedTime.removeValue(forKey: cue.id) {
            skip = frames(s)
            if let total = setup.outputFrames { skip = min(skip, Int64(total)) }
            setup.startPlayed = Double(skip) * setup.rate * clip.sampleRate / sampleRate
            setup.fadeInFrames = 0
            instances[cue.id]?.actionAt = t - skip
        }
        let fadeIn = pendingFadeIn.removeValue(forKey: cue.id)
        if fadeIn != nil { setup.levelDB = showSilenceDB; setup.fadeInFrames = 0 }
        send(.start(cue.id, clip: clip, setup: setup, at: t))
        if let fadeIn {
            let to = fadeIn.levelDB ?? cue.audio?.level ?? 0
            send(.fade(cue.id, at: t, frames: fadeIn.frames, curve: fadeIn.curve, levelDB: to, outputsDB: []))
        }
        instances[cue.id]?.hasVoice = true
        instances[cue.id]?.map = setup.map
        instances[cue.id]?.clip = clip
        instances[cue.id]?.rate = setup.rate
        instances[cue.id]?.actionEnd = setup.outputFrames.map { t + Int64($0) - skip }
        instances[cue.id]?.levelDB = fadeIn.map { $0.levelDB ?? cue.audio?.level ?? 0 } ?? cue.audio?.level ?? 0
        if let d = deferredFades.removeValue(forKey: cue.id) {
            let current = instances[cue.id]?.levelDB ?? 0
            let level = d.relative ? d.level.map { max(showSilenceDB, current + $0) } : d.level
            if let level { instances[cue.id]?.levelDB = level }
            send(.fade(cue.id, at: t, frames: max(0, d.end - t), curve: d.curve, levelDB: level, outputsDB: d.outputs))
            if instances[d.fade]?.actionEnded == false {
                instances[d.fade]?.holdTargets.append(cue.id)
                instances[d.fade]?.fadeLevels[cue.id] = level
            }
        }
        if let xf, xf.hasNext, let len = setup.outputFrames {
            instances[cue.id]?.crossfadeAt = t + max(0, Int64(len) - skip - frames(xf.seconds))
        }
    }

    /// For an entry of a playlist group with a crossfade: its length, whether it is the very first entry and whether
    /// another entry follows.
    private func playlistCrossfade(_ id: UUID) -> (seconds: Double, first: Bool, hasNext: Bool)? {
        guard let parent = instances[id]?.parent, let g = instances[parent], let gc = document.cue(parent),
              gc.groupMode == .playlist, gc.crossfade > 0 else { return nil }
        let first = g.playlistIndex == 0 && !g.playlistWrapped
        let hasNext = g.playlistIndex + 1 < g.playlist.count || gc.loopPlaylist
        return (gc.crossfade, first, hasNext)
    }

    /// Crossfade point of a playlist entry: the next entry starts now; this one is already fading out.
    private func crossfadeElapsed(_ id: UUID, at t: Int64) {
        instances[id]?.crossfadeAt = nil
        guard let parent = instances[id]?.parent else { return }
        if advancePlaylist(parent, at: t) { instances[parent]?.crossfaded.insert(id) }
    }

    /// Starts audio cues whose file has become ready since GO; gives up after `clipWaitSeconds`.
    private func retryAwaitingClips(now: Int64, at t: Int64) {
        // A few times a second is enough; the provider starts a background decode when asked.
        if let last = lastClipRetry, now - last < frames(0.05) { return }
        lastClipRetry = now
        for (id, inst) in instances {
            guard let deadline = inst.awaitingClip, !inst.stopping, !inst.paused, let cue = document.cue(id) else { continue }
            if clipProvider(cue) != nil {
                instances[id]?.awaitingClip = nil
                instances[id]?.actionAt = t
                problems[id] = nil
                startAudio(cue, at: t)
            } else if now >= deadline || !clipPending(cue) {
                instances[id]?.awaitingClip = nil
                instances[id]?.actionEnd = now
                problems[id] = "error.show.missingFile"
            }
        }
    }

    /// Voice settings of an audio cue for a decoded clip (also used to audition from the editor).
    public static func voiceSetup(_ cue: Cue, clip: AudioClip, outputs: Int, from: Double? = nil, length: Double? = nil) -> VoiceSetup? {
        guard var p = cue.audio, clip.frames > 0 else { return nil }
        let sr = clip.sampleRate
        if let from {
            // Audition: play from `from` (optionally for `length` seconds), once, without fades.
            p.start = from
            p.end = length.map { min(clip.duration, from + $0) } ?? p.end
            p.loopStart = nil; p.loopEnd = nil
            p.plays = 1
            p.fadeIn = 0; p.fadeOut = 0
        }
        let outs = max(1, outputs)
        var setup = VoiceSetup(
            map: p.playMap(fileLength: clip.duration, scale: sr), rate: max(0.05, p.rate),
            levelDB: p.level,
            outputLevelsDB: (0..<outs).map { p.outputLevel($0) },
            crosspointsDB: (0..<clip.channelCount).map { c in
                (0..<outs).map { p.crosspoint(channel: c, output: $0, fileChannels: clip.channelCount) }
            },
            fadeInFrames: Int(p.fadeIn * sr), fadeOutFrames: Int(p.fadeOut * sr))
        if let env = p.envelope, env.enabled, !env.points.isEmpty {
            let step = setup.envelopeStep
            let n = Int(Double(clip.frames) / step) + 2
            setup.envelope = (0..<n).map { i in
                Float(showGain(p.envelopeDB(atFile: Double(i) * step / sr, fileLength: clip.duration)))
            }
        }
        return setup
    }

    /// Audio cues with a voice under `id` (itself or the children of a group).
    private func voiceTargets(_ id: UUID) -> [UUID] {
        guard let c = document.cue(id) else { return [] }
        var out: [UUID] = []
        func walk(_ c: Cue) {
            if c.kind == .audio, instances[c.id]?.hasVoice == true, instances[c.id]?.actionEnded == false { out.append(c.id) }
            c.children.forEach(walk)
        }
        walk(c)
        return out
    }

    private func startFade(_ cue: Cue, at t: Int64) {
        guard let target = cue.target, let f = cue.fade else { return }
        let len = frames(instances[cue.id]?.durationOverride ?? f.duration)
        if f.fromSilence, voiceTargets(target).isEmpty, let tc = document.cue(target), let (lid, parent) = location(of: target) {
            // Fade in: start the target from silence; each of its audio cues ramps up from its own start.
            var marked: [UUID] = []
            func mark(_ c: Cue) {
                if c.kind == .audio { pendingFadeIn[c.id] = (len, f.curve, f.relative ? nil : f.level); marked.append(c.id) }
                c.children.forEach(mark)
            }
            mark(tc)
            trigger(target, list: lid, parent: parent, at: t)
            instances[cue.id]?.actionEnd = t + len
            instances[cue.id]?.fadeInMarked = marked
            return
        }
        let targets = voiceTargets(target)
        for v in targets {
            // Relative (QLab): the level is a change from where the target is now.
            let level = f.relative ? f.level.map { max(showSilenceDB, (instances[v]?.levelDB ?? 0) + $0) } : f.level
            if let level, let into = instances[cue.id]?.fadeInto, into > 0, f.duration > 0 {
                // Part-way: first where the fade would be by now, then on along the same curve.
                var ramp = LevelRamp(instances[v]?.levelDB ?? 0)
                ramp.set(to: level, at: 0, frames: frames(f.duration), curve: f.curve)
                send(.fade(v, at: t, frames: 0, curve: f.curve, levelDB: ramp.dB(at: frames(into)), outputsDB: []))
            }
            if let level { instances[v]?.levelDB = level }
            instances[cue.id]?.fadeLevels[v] = level
            send(.fade(v, at: t, frames: len, curve: f.curve, levelDB: level, outputsDB: f.outputLevels))
        }
        // Audio cues already triggered but not sounding yet get the fade when they start.
        var deferred = false
        func defer_(_ c: Cue) {
            if c.kind == .audio, let i = instances[c.id], !i.hasVoice, !i.stopping, !i.actionEnded,
               i.awaitingClip != nil || i.actionAt <= t {
                deferredFades[c.id] = (cue.id, t + len, f.curve, f.level, f.relative, f.outputLevels)
                deferred = true
            }
            c.children.forEach(defer_)
        }
        if let tc = document.cue(target) { defer_(tc) }
        instances[cue.id]?.actionEnd = t + len
        instances[cue.id]?.holdTargets = targets
        if f.stopWhenDone && (!targets.isEmpty || deferred) { instances[cue.id]?.stopTargetsAtEnd = [target] }
    }

    private func startGroup(_ cue: Cue, inst: Instance, at t: Int64) {
        instances[cue.id]?.actionEnd = nil
        let kids = cue.children
        guard !kids.isEmpty else { instances[cue.id]?.actionEnd = t; return }
        switch cue.groupMode {
        case .sequence, .enter:
            trigger(kids[0].id, list: inst.listID, parent: cue.id, at: t)
        case .simultaneous:
            guard let off = loadedGroupTime.removeValue(forKey: cue.id), off > 0 else {
                for k in kids { trigger(k.id, list: inst.listID, parent: cue.id, at: t) }
                break
            }
            // Loaded to a time: the group's clock starts `off` in; what lies ahead keeps its place, what is already
            // under way starts part-way through, finished fades leave their end state, finished one-off cues are skipped.
            instances[cue.id]?.actionAt = t - frames(off)
            for k in kids {
                let pre = max(0, k.preWait)
                if pre >= off { trigger(k.id, list: inst.listID, parent: cue.id, at: t, preWait: pre - off); continue }
                let into = off - pre
                switch k.kind {
                case .audio:
                    loadedTime[k.id] = into
                    trigger(k.id, list: inst.listID, parent: cue.id, at: t, preWait: 0)
                case .fade:
                    trigger(k.id, list: inst.listID, parent: cue.id, at: t, preWait: 0,
                            duration: max(0, (k.fade?.duration ?? 0) - into))
                    instances[k.id]?.fadeInto = min(into, k.fade?.duration ?? 0)
                case .wait where into < k.duration:
                    trigger(k.id, list: inst.listID, parent: cue.id, at: t, preWait: 0, duration: k.duration - into)
                case .group where k.groupMode == .simultaneous:
                    loadedGroupTime[k.id] = into
                    trigger(k.id, list: inst.listID, parent: cue.id, at: t, preWait: 0)
                default:
                    break
                }
            }
            if !instances.values.contains(where: { $0.parent == cue.id }) { instances[cue.id]?.actionEnd = t }
        case .random:
            let i = min(kids.count - 1, Int(random() * Double(kids.count)))
            trigger(kids[i].id, list: inst.listID, parent: cue.id, at: t)
        case .playlist:
            let order = cue.shuffle ? shuffled(kids.map(\.id)) : kids.map(\.id)
            instances[cue.id]?.playlist = order
            instances[cue.id]?.playlistIndex = 0
            trigger(order[0], list: inst.listID, parent: cue.id, at: t)
        }
    }

    private func shuffled(_ ids: [UUID]) -> [UUID] {
        var a = ids
        guard a.count > 1 else { return a }
        for i in stride(from: a.count - 1, to: 0, by: -1) {
            let j = min(i, Int(random() * Double(i + 1)))
            a.swapAt(i, j)
        }
        return a
    }

    private func devamp(_ target: UUID, by cue: Cue?, at t: Int64) {
        guard var inst = instances[target], inst.hasVoice, !inst.actionEnded, inst.phase == .running else { return }
        let played = Double(max(0, t - inst.actionAt - inst.pausedTotal)) * inst.rate
        inst.map = inst.map.devamped(at: played)
        if let total = inst.map.total {
            inst.actionEnd = inst.actionAt + inst.pausedTotal + Int64((total / inst.rate).rounded(.up))
        }
        if let cue, cue.devampStartsNext, let (lid, parent) = location(of: cue.id), let n = next(after: cue.id, list: lid, parent: parent) {
            inst.onEnd = (n.id, lid, parent)
        }
        instances[target] = inst
        send(.devamp(target, at: t))
    }

    private func postWaitElapsed(_ id: UUID, at t: Int64) {
        guard var inst = instances[id] else { return }
        inst.postWaitAt = nil
        instances[id] = inst
        continueAfter(inst, at: t)
        removeIfDone(id, at: t)
    }

    private func actionFinished(_ id: UUID, at t: Int64) {
        guard var inst = instances[id] else { return }
        inst.actionEnded = true
        instances[id] = inst
        for m in inst.fadeInMarked { pendingFadeIn[m] = nil }
        for s in inst.stopTargetsAtEnd { terminate(s, at: t, fade: 0) }
        if let onEnd = inst.onEnd { trigger(onEnd.cue, list: onEnd.list, parent: onEnd.parent, at: t) }
        if inst.follow { continueAfter(inst, at: t) }
        removeIfDone(id, at: t)
    }

    /// Auto-continue / auto-follow: the next sibling, or the next playlist entry.
    private func continueAfter(_ inst: Instance, at t: Int64) {
        if let parent = inst.parent, let group = document.cue(parent), group.groupMode != .sequence && group.groupMode != .enter {
            return // only sequence groups chain through their children's continue modes
        }
        if let n = next(after: inst.cueID, list: inst.listID, parent: inst.parent) {
            trigger(n.id, list: inst.listID, parent: inst.parent, at: t)
        }
    }

    private func removeIfDone(_ id: UUID, at t: Int64) {
        guard let inst = instances[id], inst.actionEnded, inst.postWaitAt == nil else { return }
        if inst.kind == .group && instances.values.contains(where: { $0.parent == id }) { return }
        instances[id] = nil
        if let parent = inst.parent { childFinished(inst, group: parent, at: t) }
    }

    private func childFinished(_ child: Instance, group: UUID, at t: Int64) {
        guard var g = instances[group] else { return }
        guard let cue = document.cue(group) else {
            // The group was deleted: it goes with its last child.
            if !instances.values.contains(where: { $0.parent == group }) { instances[group] = nil }
            return
        }
        if g.crossfaded.contains(child.cueID) {
            // Its successor already started at the crossfade point.
            instances[group]?.crossfaded.remove(child.cueID)
            g = instances[group] ?? g
        } else if cue.groupMode == .playlist && !g.stopping && !child.stopping {
            if advancePlaylist(group, at: t) { return }
            g = instances[group] ?? g
        }
        guard !instances.values.contains(where: { $0.parent == group }) else { return }
        if g.phase == .running && !g.actionEnded {
            g.actionEnd = t
            instances[group] = g
            actionFinished(group, at: t)
        } else if g.actionEnded {
            // Stopped with a fade: the group's own action ended at the stop; it goes once its children are gone.
            removeIfDone(group, at: t)
        }
    }

    /// Starts the next playlist entry (wrapping when looping). False when the playlist is over.
    private func advancePlaylist(_ group: UUID, at t: Int64) -> Bool {
        guard var g = instances[group], let cue = document.cue(group), !g.stopping else { return false }
        var i = g.playlistIndex + 1
        if i >= g.playlist.count, cue.loopPlaylist, !g.playlist.isEmpty {
            g.playlist = cue.shuffle ? shuffled(cue.children.map(\.id)) : cue.children.map(\.id)
            g.playlistWrapped = true
            i = 0
        }
        g.playlistIndex = i
        instances[group] = g
        guard i < g.playlist.count else { return false }
        trigger(g.playlist[i], list: g.listID, parent: group, at: t)
        return true
    }

    /// Stops a cue (and the children of a group). Stopped cues do not continue.
    private func terminate(_ id: UUID, at t: Int64, fade: Int64) {
        guard var inst = instances[id] else { return }
        deferredFades[id] = nil
        // Stopped before its children, so a group whose last child goes away now neither continues nor advances.
        inst.postWaitAt = nil
        inst.follow = false
        inst.onEnd = nil
        inst.stopTargetsAtEnd = []
        inst.crossfadeAt = nil
        inst.stopping = true
        inst.paused = false
        instances[id] = inst
        for (cid, c) in instances where c.parent == id { terminate(cid, at: t, fade: fade) }
        guard instances[id] != nil else { return }
        inst = instances[id]!
        if inst.phase == .preWait {
            instances[id] = nil
            if let parent = inst.parent { childFinished(inst, group: parent, at: t) }
            return
        }
        if inst.hasVoice && !inst.actionEnded {
            send(.stop(id, at: t, fadeFrames: fade))
            inst.actionEnd = t + fade
        } else if !inst.actionEnded {
            if inst.kind == .fade { for v in inst.holdTargets { send(.holdLevels(v, at: t)) } }
            inst.actionEnd = t
        }
        instances[id] = inst
        if inst.kind == .group && !instances.values.contains(where: { $0.parent == id }) {
            instances[id]?.actionEnd = t
        }
    }

    private func pauseInstance(_ id: UUID, at t: Int64) {
        guard var inst = instances[id], !inst.paused, !inst.actionEnded || inst.postWaitAt != nil else { return }
        inst.paused = true
        inst.pausedAt = t
        instances[id] = inst
        if inst.hasVoice { send(.pause(id, at: t)) }
        // A paused Fade cue freezes its targets where they are (QLab); resume continues the fade.
        if inst.kind == .fade, inst.phase == .running, !inst.actionEnded {
            for v in inst.holdTargets { send(.holdLevels(v, at: t)) }
        }
        for (cid, c) in instances where c.parent == id { pauseInstance(cid, at: t) }
    }

    private func resumeInstance(_ id: UUID, at t: Int64) {
        guard var inst = instances[id], inst.paused else { return }
        let delta = max(0, t - inst.pausedAt)
        if inst.kind == .fade, inst.phase == .running, !inst.actionEnded, let end = inst.actionEnd, end > inst.pausedAt,
           let f = document.cue(id)?.fade {
            for v in inst.holdTargets where instances[v]?.actionEnded == false {
                send(.fade(v, at: t, frames: end - inst.pausedAt, curve: f.curve, levelDB: inst.fadeLevels[v] ?? nil,
                           outputsDB: f.outputLevels))
            }
        }
        inst.paused = false
        if inst.phase == .preWait {
            inst.actionAt += delta
            inst.triggered += delta
        } else {
            inst.pausedTotal += delta
            if let e = inst.actionEnd, !inst.actionEnded { inst.actionEnd = e + delta }
            if let p = inst.postWaitAt { inst.postWaitAt = p + delta }
            if let x = inst.crossfadeAt { inst.crossfadeAt = x + delta }
        }
        instances[id] = inst
        if inst.hasVoice { send(.resume(id, at: t)) }
        for (cid, c) in instances where c.parent == id { resumeInstance(cid, at: t) }
    }
}
