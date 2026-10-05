import Foundation
import SSMTCore

// What Qtrl's interface draws, as events: the document and everything SSMTCore derives from it ("show"), the playback
// state ("showLive"), file overviews ("showWave") and the tables that never change ("showStatic"). Also the parity
// fixture: the sample show and preview state of the Mac snapshot tests (App/Tests/Snapshots/SnapshotTests.swift).

extension ShowModule {
    // MARK: State

    func emitState() {
        var paths: [String: String] = [:]
        var lengths: [String: Any] = [:]
        var maps: [String: [Double]] = [:]
        for c in doc.allCues where c.kind == .audio {
            guard let p = resolvedPath(c) else { continue }
            let key = c.id.uuidString
            paths[key] = p
            if let info = clipInfo[p], let a = c.audio {
                lengths[key] = showOpt(ShowTimeline.audioDuration(c, fileLength: info.duration))
                let m = a.playMap(fileLength: info.duration)
                maps[key] = [m.regionStart, m.intro, m.loop, m.outro, Double(m.plays)]
            }
        }
        var info: [String: Any] = [:]
        for (p, i) in clipInfo { info[p] = ["duration": i.duration, "channels": i.channels] as [String: Any] }
        var f: [String: Any] = [
            "doc": Out.json(doc),
            "file": showOpt(filePath),
            "selection": selection.map(\.uuidString),
            "listID": showOpt(listID?.uuidString),
            "bankID": showOpt(currentBank?.id.uuidString),
            "timelineGroup": showOpt(timelineGroup?.uuidString),
            "collapsed": collapsed.map(\.uuidString),
            "showMode": showMode,
            "canUndo": !undoStack.isEmpty,
            "canRedo": !redoStack.isEmpty,
            "paths": paths,
            "clipInfo": info,
            "missing": Array(missingFiles),
            "unreadable": unreadableFiles,
            "loading": playback.clips.loading,
            "memory": 0,
            "output": ["name": outputName, "error": showOpt(outputError), "sampleRate": playback.sampleRate,
                       "interruptions": interruptions, "open": playback.outputOpen] as [String: Any],
            "buffer": bufferFrames,
            "lengths": lengths,
            "maps": maps,
            "issues": checkShow().map(issueDict),
            "error": showOpt(lastError),
            "audition": showOpt(audition.map { a -> [String: Any] in ["cue": a.cue.uuidString, "from": a.from, "length": a.length, "rate": a.rate] }),
        ]
        if let g = timelineGroup {
            f["groupPlan"] = ["id": g.uuidString, "clips": clipDicts(ShowTimeline.planGroup(doc, group: g, fileLength: fileLength))] as [String: Any]
        }
        if selection.count == 1, let id = selection.first, let cue = doc.cue(id) {
            var sel: [String: Any] = ["id": id.uuidString,
                                      "targets": doc.targetCandidates(for: cue.kind, excluding: id).map { $0.id.uuidString }]
            if cue.kind == .group {
                sel["multitrack"] = clipDicts(ShowTimeline.planGroup(doc, group: id, fileLength: fileLength, lanePerCue: true))
            }
            if let o = cue.osc {
                sel["display"] = o.message.display
                sel["argsText"] = o.arguments.map(\.display).joined(separator: " ")
            }
            f["selected"] = sel
        }
        Out.emit("show", f)
    }

    private func issueDict(_ i: ShowIssue) -> [String: Any] {
        switch i {
        case let .missingTarget(id): return ["type": "target", "id": id.uuidString]
        case let .missingFile(id): return ["type": "file", "id": id.uuidString]
        case let .duplicateNumber(n): return ["type": "number", "value": n]
        case let .duplicateHotkey(k): return ["type": "hotkey", "value": k]
        case let .emptyGroup(id): return ["type": "emptyGroup", "id": id.uuidString]
        case let .invalidRegion(id): return ["type": "region", "id": id.uuidString]
        case let .missingDevice(id): return ["type": "device", "id": id.uuidString]
        }
    }

    func clipDicts(_ clips: [TimelineClip], paused: [UUID: Bool] = [:]) -> [[String: Any]] {
        clips.map { c -> [String: Any] in
            ["id": c.id, "cue": c.cueID.uuidString, "style": c.style.rawValue, "start": c.start,
             "duration": showOpt(c.duration), "lane": c.lane, "live": c.live, "paused": paused[c.cueID] ?? false]
        }
    }

    // MARK: Live

    /// The live timeline (ShowTimelineView `currentClips` with no time elapsed since the snapshot): what plays and
    /// waits now, and what the next GO would start, packed into tracks.
    func liveClips() -> [TimelineClip] {
        var clips: [TimelineClip] = []
        let snap = live.snapshot
        for r in snap.running {
            guard let cue = doc.cue(r.id) else { continue }
            let style: TimelineClip.Style
            switch cue.kind {
            case .audio: style = .audio
            case .fade: style = .fade
            case .wait: style = .wait
            default: continue
            }
            if r.phase == .preWait {
                let d: Double?
                switch cue.kind {
                case .audio: d = ShowTimeline.audioDuration(cue, fileLength: fileLength(cue))
                case .fade: d = cue.fade?.duration
                default: d = cue.duration
                }
                clips.append(TimelineClip(cueID: r.id, style: style, start: max(0, r.remaining ?? 0), duration: d, live: true, tag: "live"))
            } else {
                clips.append(TimelineClip(cueID: r.id, style: style, start: -r.elapsed, duration: r.duration, live: true, tag: "live"))
            }
        }
        // What the next GO starts, if pressed now.
        let playhead = snap == .empty ? currentList?.cues.first?.id : snap.playhead
        if let ph = playhead {
            let runningIDs = Set(snap.running.map(\.id))
            clips += ShowTimeline.plan(doc, from: ph, fileLength: fileLength, limit: 60).filter { !runningIDs.contains($0.cueID) }
        }
        return ShowTimeline.assignLanes(clips)
    }

    func emitLive() {
        let s = live.snapshot
        live.forceEmit = false
        live.sentSnapshot = s
        live.sentMeters = live.meters
        live.sentClipping = live.clipping
        var problems: [String: String] = [:]
        for (k, v) in s.problems { problems[k.uuidString] = v }
        var loaded: [String: Double] = [:]
        for (k, v) in s.loaded { loaded[k.uuidString] = v }
        var paused: [UUID: Bool] = [:]
        for r in s.running { paused[r.id] = r.paused }
        let standby = s == .empty ? currentList?.cues.first?.id : s.playhead
        Out.emit("showLive", [
            "listID": showOpt(s.listID?.uuidString),
            "playhead": showOpt(s.playhead?.uuidString),
            "standby": showOpt(standby?.uuidString),
            "empty": s == .empty,
            "running": s.running.map { r -> [String: Any] in
                ["id": r.id.uuidString, "phase": r.phase.rawValue, "elapsed": r.elapsed, "duration": showOpt(r.duration),
                 "paused": r.paused, "iteration": showOpt(r.iteration)]
            },
            "problems": problems,
            "loaded": loaded,
            "meters": live.meters.map { Double($0) },
            "clipping": live.clipping,
            "goGuarded": goGuardUntil != nil,
            "clips": clipDicts(liveClips(), paused: paused),
        ])
    }

    // MARK: Static tables and overviews

    func emitStatic() {
        var presets: [String: Any] = [:]
        var kinds: [String: Any] = [:]
        for k in OSCDeviceKind.allCases {
            presets[k.rawValue] = OSCPreset.presets(for: k).map { p -> [String: Any] in
                ["id": p.id, "fields": p.fields.map { f -> [String: Any] in
                    let kind: String
                    switch f.kind {
                    case .number: kind = "number"
                    case .twoDigits: kind = "twoDigits"
                    case .level: kind = "level"
                    case .text: kind = "text"
                    }
                    return ["key": f.key, "kind": kind, "default": f.defaultValue]
                }]
            }
            kinds[k.rawValue] = ["port": Int(k.defaultPort), "probe": k.probe != nil] as [String: Any]
        }
        var shapes: [String: [Double]] = [:]
        for c in FadeCurve.allCases { shapes[c.rawValue] = (0...120).map { c.shape(Double($0) / 120) } }
        Out.emit("showStatic", ["presets": presets, "kinds": kinds, "kindOrder": OSCDeviceKind.allCases.map(\.rawValue),
                                "fadeShapes": shapes, "functionKeys": ShowDocument.functionKeys,
                                "floorDB": VolumeEnvelope.floorDB, "silenceDB": showSilenceDB])
    }

    func emitWave(_ path: String, _ w: [Float]) {
        Out.emit("showWave", ["path": path, "peaks": w.map { (Double($0) * 1000).rounded() / 1000 }])
    }

    // MARK: Parity fixture (SnapshotTests.prepareShow, testWaveformEditor, testOSCSetup)

    static func sampleShow() -> (doc: ShowDocument, intro: UUID, group: UUID, preshow: UUID, bell: UUID) {
        var doc = ShowDocument(name: "Spring gala")
        let l = doc.lists[0].id
        var preshow = Cue.audio(file: "/show/Preshow loop.wav", number: "1")
        preshow.audio?.plays = 0
        preshow.notes = "House open"
        var fade = Cue(kind: .fade, number: "2", name: "Fade preshow")
        fade.target = preshow.id
        fade.continueMode = .autoContinue
        fade.postWait = 2
        var intro = Cue.audio(file: "/show/Intro.wav", number: "3")
        intro.preWait = 1.5
        intro.continueMode = .autoFollow
        var group = Cue(kind: .group, number: "4", name: "Scene 1")
        group.groupMode = .simultaneous
        group.notes = "After the bow"
        var rain = Cue.audio(file: "/show/Rain.wav", number: "4.1")
        rain.color = "blue"
        rain.audio?.plays = 0
        var thunder = Cue.audio(file: "/show/Thunder.wav", number: "4.2")
        thunder.preWait = 3
        group.children = [rain, thunder]
        var wait = Cue(kind: .wait, number: "5")
        wait.duration = 10
        var stop = Cue(kind: .stop, number: "6", name: "Stop scene")
        stop.target = group.id
        stop.stopFade = 3
        doc.insert([preshow, fade, intro, group, wait, stop, Cue(kind: .memo, name: "Interval")], after: nil, list: l)
        var pads: [Cue] = []
        for (i, name) in ["Phone", "Door", "Applause", "Wind", "Steps", "Clock"].enumerated() {
            var c = Cue.audio(file: "/show/\(name).wav")
            c.hotkey = "F\(i + 1)"
            if name == "Wind" { c.audio?.plays = 0 }
            pads.append(c)
        }
        doc.lists[1].cues = pads
        return (doc, intro.id, group.id, preshow.id, pads[0].id)
    }

    /// `variant`: "player" (show-edit, show-show), "multitrack" (the group selected), "waveform" (the intro's region,
    /// loop, fades and volume line set), "osc" (two devices, this computer at 192.168.64.12 as on the Mac).
    func fixture(_ variant: String) {
        let s = Self.sampleShow()
        previewing = true
        showMode = false
        doc = s.doc
        undoStack = []
        redoStack = []
        filePath = nil
        listID = s.doc.lists[0].id
        bankID = s.doc.lists[1].id
        selection = [s.intro]
        clipInfo = [:]
        waveforms = [:]
        for (i, (name, d)) in [("Preshow loop", 95.0), ("Intro", 41.5), ("Rain", 180), ("Thunder", 6.2), ("Phone", 4), ("Door", 2),
                                  ("Applause", 12), ("Wind", 30), ("Steps", 3), ("Clock", 5)].enumerated() {
            let path = "/show/\(name).wav"
            clipInfo[path] = (d, 2)
            waveforms[path] = (0..<600).map { k in Float(0.25 + 0.5 * abs(sin(Double(k) * 0.05 + Double(i)) * cos(Double(k) * 0.013))) }
        }
        live.snapshot = ShowSnapshot(listID: s.doc.lists[0].id, playhead: s.group, running: [
            RunningCue(id: s.preshow, phase: .stopping, elapsed: 1.2, duration: 3, paused: false, iteration: 4),
            RunningCue(id: s.intro, phase: .running, elapsed: 12.4, duration: 41.5, paused: false, iteration: nil),
            RunningCue(id: s.bell, phase: .running, elapsed: 1.5, duration: 4, paused: false, iteration: nil),
        ], problems: [:])
        live.meters = [0.5, 0.45, 0.1, 0.1, 0, 0, 0, 0]
        live.clipping = []
        outputName = "Preview"
        outputError = nil
        playback.sampleRate = 48000
        switch variant {
        case "multitrack":
            selection = [doc.lists[0].cues[3].id]
        case "waveform":
            doc.updateCue(s.intro) { c in
                c.audio?.start = 1.2
                c.audio?.end = 38
                c.audio?.fadeIn = 2
                c.audio?.fadeOut = 4
                c.audio?.loopStart = 10
                c.audio?.loopEnd = 22
                c.audio?.plays = 0
                c.audio?.envelope = VolumeEnvelope(points: [.init(u: 0.3, db: 0), .init(u: 0.45, db: -12), .init(u: 0.7, db: -12), .init(u: 0.85, db: -3)])
            }
        case "osc":
            doc.devices = [OSCDevice(name: "Resolume", kind: .resolume, host: "127.0.0.1"),
                           OSCDevice(name: "Eos Ion", kind: .eos, host: "10.101.0.2")]
            osc.interfaces = [(name: "en0", address: "192.168.64.12", mask: "255.255.255.0")]
        default:
            break
        }
        missingFiles = []
        unreadableFiles = [:]
        undoStack = []
        emitStatic()
        for (p, w) in waveforms { emitWave(p, w) }
        emitState()
        dirty = false
        emitLive()
        emitOSC()
        osc.dirty = false
    }
}
