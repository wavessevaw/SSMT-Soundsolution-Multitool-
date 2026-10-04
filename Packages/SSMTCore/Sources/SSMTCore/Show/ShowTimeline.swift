import Foundation

/// One block on the multitrack timeline. Times are seconds relative to a reference
/// (the next GO for a plan, "now" for live clips).
public struct TimelineClip: Equatable, Identifiable, Sendable {
    public enum Style: String, Sendable { case audio, fade, wait, marker }
    public var id: String
    public var cueID: UUID
    public var style: Style
    public var start: Double
    /// nil = open-ended (loops until stopped).
    public var duration: Double?
    /// Track index (fades and markers use their own row, see `ShowTimeline.controlLane`).
    public var lane: Int = 0
    /// Already playing (live) rather than planned.
    public var live = false

    public init(cueID: UUID, style: Style, start: Double, duration: Double?, live: Bool = false, tag: String = "") {
        id = cueID.uuidString + tag
        self.cueID = cueID
        self.style = style
        self.start = start
        self.duration = duration
        self.live = live
    }

    public var end: Double { duration.map { start + $0 } ?? .infinity }
}

/// Predicts what cues will do in time, for the multitrack timeline.
public enum ShowTimeline {
    /// Row used by fades, waits and control markers.
    public static let controlLane = -1

    /// Length of an audio cue's action (nil = loops forever) from the file length in seconds.
    public static func audioDuration(_ cue: Cue, fileLength: Double?) -> Double? {
        guard let a = cue.audio, let length = fileLength else { return nil }
        return a.playMap(fileLength: length).total.map { $0 / max(a.rate, 0.05) }
    }

    /// Everything one GO on `cueID` starts: the cue, its continue chain and group contents.
    /// `fileLength` returns an audio cue's file length in seconds (nil if unknown).
    public static func plan(_ doc: ShowDocument, from cueID: UUID, fileLength: @escaping (Cue) -> Double?,
                            limit: Int = 400) -> [TimelineClip] {
        var sim = Simulator(doc: doc, fileLength: fileLength, limit: limit)
        guard let (siblings, index) = sim.siblings(of: cueID) else { return [] }
        sim.chain(siblings, from: index, at: 0)
        return assignLanes(sim.clips)
    }

    /// Contents of a group as if it started at 0 (for editing a group on the timeline).
    /// `lanePerCue`: every audio cue of the group on its own track, in the group's order (a multitrack view);
    /// otherwise clips are packed into the fewest tracks.
    public static func planGroup(_ doc: ShowDocument, group: UUID, fileLength: @escaping (Cue) -> Double?,
                                 lanePerCue: Bool = false) -> [TimelineClip] {
        guard var g = doc.cue(group), g.kind == .group else { return [] }
        var sim = Simulator(doc: doc, fileLength: fileLength, limit: 400)
        guard lanePerCue else {
            _ = sim.groupChildren(g, at: 0)
            return assignLanes(sim.clips)
        }
        // The multitrack edits the group as a timeline (QLab 5): every child at its pre-wait, each on its own track,
        // whatever its kind (audio, fade, wait, OSC, control cues, memos).
        g.groupMode = .simultaneous
        sim.markMemos = true
        _ = sim.groupChildren(g, at: 0)
        let order = g.children.flattened().map(\.cue).filter { $0.kind != .group }.map(\.id)
        return sim.clips.map { c in
            var c = c
            c.lane = order.firstIndex(of: c.cueID) ?? order.count
            return c
        }
    }

    /// Packs clips into the fewest tracks so that none overlap; fades and markers go to `controlLane`.
    public static func assignLanes(_ clips: [TimelineClip]) -> [TimelineClip] {
        var ends: [Double] = []
        var out: [TimelineClip] = []
        for var c in clips.sorted(by: { ($0.start, $0.id) < ($1.start, $1.id) }) {
            if c.style != .audio {
                c.lane = controlLane
                out.append(c)
                continue
            }
            if let i = ends.firstIndex(where: { $0 <= c.start + 1e-6 }) {
                c.lane = i
                ends[i] = c.end
            } else {
                c.lane = ends.count
                ends.append(c.end)
            }
            out.append(c)
        }
        return out
    }

    private struct Simulator {
        let doc: ShowDocument
        let fileLength: (Cue) -> Double?
        let limit: Int
        var clips: [TimelineClip] = []

        /// Memo cues as markers too (group multitrack).
        var markMemos = false

        init(doc: ShowDocument, fileLength: @escaping (Cue) -> Double?, limit: Int) {
            self.doc = doc
            self.fileLength = fileLength
            self.limit = limit
        }

        func siblings(of id: UUID) -> ([Cue], Int)? {
            for l in doc.lists {
                if let i = l.cues.firstIndex(where: { $0.id == id }) { return (l.cues, i) }
                if let r = find(id, in: l.cues) { return r }
            }
            return nil
        }

        private func find(_ id: UUID, in cues: [Cue]) -> ([Cue], Int)? {
            for c in cues {
                if let i = c.children.firstIndex(where: { $0.id == id }) { return (c.children, i) }
                if let r = find(id, in: c.children) { return r }
            }
            return nil
        }

        /// Triggers `cues[index]` at `t` and follows continue modes along the siblings.
        mutating func chain(_ cues: [Cue], from index: Int, at t: Double) {
            var i = index
            var time = t
            while i < cues.count, clips.count < limit {
                let cue = cues[i]
                let start = time + max(0, cue.preWait)
                let duration = trigger(cue, at: start)
                switch cue.continueMode {
                case .none: return
                case .autoContinue: time = start + max(0, cue.postWait)
                case .autoFollow:
                    guard let d = duration else { return }
                    time = start + d
                }
                i += 1
            }
        }

        /// Adds the cue's clips; returns its action length (nil = open-ended).
        @discardableResult
        mutating func trigger(_ cue: Cue, at start: Double) -> Double? {
            guard clips.count < limit else { return 0 }
            guard cue.armed else { return 0 }
            switch cue.kind {
            case .audio:
                let d = ShowTimeline.audioDuration(cue, fileLength: fileLength(cue))
                clips.append(TimelineClip(cueID: cue.id, style: .audio, start: start, duration: d, tag: "@\(start)"))
                return d
            case .fade:
                let d = max(0, cue.fade?.duration ?? 0)
                clips.append(TimelineClip(cueID: cue.id, style: .fade, start: start, duration: d, tag: "@\(start)"))
                return d
            case .wait:
                clips.append(TimelineClip(cueID: cue.id, style: .wait, start: start, duration: cue.duration, tag: "@\(start)"))
                return cue.duration
            case .group:
                return groupChildren(cue, at: start)
            case .memo:
                if markMemos { clips.append(TimelineClip(cueID: cue.id, style: .marker, start: start, duration: 0, tag: "@\(start)")) }
                return 0
            default:
                clips.append(TimelineClip(cueID: cue.id, style: .marker, start: start, duration: 0, tag: "@\(start)"))
                return 0
            }
        }

        /// Plays a group's children from `start`; returns the group length (nil = open-ended).
        mutating func groupChildren(_ g: Cue, at start: Double) -> Double? {
            let kids = g.children
            guard !kids.isEmpty else { return 0 }
            let before = clips.count
            switch g.groupMode {
            case .simultaneous:
                for k in kids { trigger(k, at: start + max(0, k.preWait)) }
            case .sequence, .enter:
                chain(kids, from: 0, at: start)
            case .random:
                trigger(kids[0], at: start + max(0, kids[0].preWait))
            case .playlist:
                var t = start
                for k in kids {
                    let s = t + max(0, k.preWait)
                    guard let d = trigger(k, at: s) else { break }
                    t = s + d
                }
            }
            let added = clips[before...]
            if added.contains(where: { $0.duration == nil }) || (g.groupMode == .playlist && g.loopPlaylist) { return nil }
            return (added.map(\.end).max() ?? start) - start
        }
    }
}
