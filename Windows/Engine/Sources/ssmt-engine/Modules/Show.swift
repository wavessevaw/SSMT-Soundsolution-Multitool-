import Foundation
import SSMTCore

// Function #3, Qtrl (the show control center), in the engine. A copy of App/SSMT/Show/ShowStore.swift: the open
// show with undo, the selection, files and the show's media folder, the keyboard actions, and the link to the
// playback engine (ShowPlayback.swift) and OSC (ShowOSC.swift). The interface (sections/show*.js) draws it and sends
// `{cmd: "show", op: …}`; this module answers with "show" (document and everything derived from it by SSMTCore),
// "showLive" (playback state and meters, ≈ 25 a second while something plays), "showWave" (file overviews) and
// "showOSC" events.

final class ShowModule: EngineModule {
    // MARK: Document (ShowStore)

    var doc = ShowDocument(name: "") {
        didSet { if doc != oldValue { documentEdited() } }
    }
    /// The show file (a native path), nil = not saved yet.
    var filePath: String? {
        didSet { if filePath != oldValue { dirty = true } }
    }
    var selection = Set<UUID>() { didSet { dirty = true } }
    var listID: UUID? { didSet { dirty = true } }
    /// One-shot bank shown in the pad grid.
    var bankID: UUID? { didSet { dirty = true } }
    /// The live timeline shows this group's contents (nil = the live show).
    var timelineGroup: UUID? { didSet { dirty = true } }
    var collapsed = Set<UUID>() { didSet { dirty = true } }
    /// Show mode: editing locked (the interface sends it when the person switches).
    var showMode = false { didSet { dirty = true } }
    /// The workspace's error banner: {key, args, suffix} or {text}.
    var lastError: [String: Any]? { didSet { dirty = true } }

    var undoStack: [ShowDocument] = []
    var redoStack: [ShowDocument] = []
    private var cueClipboard: [Cue] = []
    private var lastStop: Date?
    /// Double-GO protection is holding GO until then.
    var goGuardUntil: Date?
    var autosaveAt: Date?
    /// The state changed: a "show" event goes out on the next tick.
    var dirty = true
    var started = false
    var dataDir = URL(fileURLWithPath: ".")

    // MARK: Files and playback state

    /// Clip lengths (seconds) and channel counts by resolved path, for the list and the inspector.
    var clipInfo: [String: (duration: Double, channels: Int)] = [:]
    /// File overviews (peak per bucket, 0…1) by resolved path.
    var waveforms: [String: [Float]] = [:]
    var missingFiles = Set<String>()
    var unreadableFiles: [String: String] = [:]
    var outputName = ""
    var outputError: String?
    var interruptions = 0
    /// Device I/O buffer (frames) chosen in the settings; remembered by the interface.
    var bufferFrames = 512
    let playback = ShowPlaybackCore()
    let osc = ShowOSCHub()
    var live = ShowLiveState()
    /// Snapshot tests / parity: a fixed playback state, the engine's own is not shown.
    var previewing = false
    /// A document changed by the playback engine (Arm, Disarm, Target cues), applied on the next tick.
    var pendingDocument: ShowDocument?
    var audition: ShowAudition?
    /// "Trim silence" asked for a file still being prepared: done when it is ready.
    var pendingTrims: [String: [UUID]] = [:]
    /// What the achievements keep between events (ShowStore's progress fields).
    var progress = ShowProgressState()

    init() {}

    // MARK: EngineModule

    func handle(_ c: Command, engine: Engine) -> Bool {
        switch c.name {
        case "show": break
        case "showDecoded": decoded(c); return true
        case "oscIn", "oscListenError", "netInterfaces": oscCommand(c); return true
        default: return false
        }
        if !started { start(engine) }
        let op = c.str("op") ?? ""
        let id = uuid(c.str("id"))
        switch op {
        case "hello":
            emitStatic()
            for (p, w) in waveforms { emitWave(p, w) }
            dirty = true
            live.forceEmit = true
            osc.dirty = true
        case "fixture": fixture(c.str("variant") ?? "player")
        // Documents
        case "new": newDocument()
        case "open": if let p = c.str("path") { open(p) }
        case "save": save(path: c.str("path"))
        case "relink": if let f = c.str("folder") { relinkMissing(folder: f) }
        case "name": if let v = c.str("value") { edit { $0.name = v } }
        case "undo": undo()
        case "redo": redo()
        case "showMode": showMode = c.bool("on") ?? false
        case "dismissError": lastError = nil
        // Cue creation
        case "add": if let k = CueKind(rawValue: c.str("kind") ?? "") { add(k) }
        case "addFade": addFade(fadeIn: c.bool("fadeIn") ?? false, name: c.str("name") ?? "")
        case "addAudio": addAudioFiles(strings(c, "paths"), after: uuid(c.str("after")), intoGroup: uuid(c.str("group")))
        case "chooseFile": if let id, let p = c.str("path") { setFile(p, for: id) }
        case "addPads": addPads(strings(c, "paths"), bankWord: c.str("bankWord") ?? "Bank")
        case "addBank": addBank(c.str("bankWord") ?? "Bank")
        case "bank": bankID = id
        case "addList": addList(c.str("listWord") ?? "List")
        case "selectList": if let id { selectList(id) }
        case "renameList": if let id { let n = c.str("name") ?? ""; edit { d in if let i = d.lists.firstIndex(where: { $0.id == id }) { d.lists[i].name = n } } }
        case "deleteList": if let id, doc.cueLists.count > 1 { edit { $0.lists.removeAll { $0.id == id } } }
        case "addNetworkFromLog": if let e = osc.log.first(where: { $0.id == id }) { addNetworkCue(from: e) }
        // Selection and structure
        case "select":
            selection = Set(strings(c, "ids").compactMap { UUID(uuidString: $0) })
            if let p = uuid(c.str("playhead")) { setPlayhead(p) }
        case "collapse": if let id { if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) } }
        case "expand": if let id { collapsed.remove(id) }
        case "delete": deleteSelection()
        case "deleteCue": if let id { edit { $0.delete([id]) } }
        case "duplicate": duplicateSelection()
        case "moveSel": moveSelection(by: c.int("delta") ?? 0)
        case "ungroup": ungroupSelection()
        case "renumber": renumberSelection()
        case "move": moveCues(strings(c, "ids").compactMap { UUID(uuidString: $0) }, before: uuid(c.str("before")), into: uuid(c.str("into")))
        case "selectAll": selection = Set(currentList?.cues.flattened().map(\.cue.id) ?? [])
        case "copy": copySelection()
        case "cut": copySelection(); deleteSelection()
        case "paste": pasteCues()
        case "timelineGroup": timelineGroup = id
        // Cue settings
        case "set": if let id, let f = c.fields["fields"] as? [String: Any] { setFields(id, f) }
        case "fadePreset": if let id { fadePreset(id, fadeIn: c.bool("fadeIn") ?? false) }
        case "route": if let id { route(id, channel: c.int("channel") ?? 0, output: c.int("output") ?? 0, channels: c.int("channels") ?? 2) }
        case "oscPreset": if let id { applyPreset(id, c.str("preset") ?? "") }
        case "oscField": if let id { presetField(id, key: c.str("key") ?? "", value: c.str("value") ?? "") }
        case "oscArgs": if let id { let a = OSCArgument.parseList(c.str("text") ?? ""); updateCue(id) { $0.osc?.arguments = a } }
        case "sendNow": if let id, let cue = doc.cue(id) { sendNow(cue) }
        case "envOn": if let id { envelopeOn(id, c.bool("on") ?? false) }
        case "loopMode": if let id { loopMode(id, c.int("mode") ?? 0) }
        case "editField": editSelected(c.str("field") ?? "", c.str("value") ?? "")
        case "continueCycle": cycleContinueMode()
        case "nudge": nudgePreWait(c.double("delta") ?? 0)
        // Show settings
        case "device": let v = c.str("uid") ?? ""; edit { $0.deviceUID = v.isEmpty ? nil : v }
        case "outputs": setOutputCount(c.int("count") ?? 8)
        case "outputName": if let i = c.int("index"), i >= 0, i < doc.outputs.count { let v = c.str("name") ?? ""; edit { $0.outputs[i].name = v } }
        case "outputChannel": if let i = c.int("index"), i >= 0, i < doc.outputs.count { let v = c.int("channel") ?? -1; edit { $0.outputs[i].deviceChannel = v < 0 ? nil : v } }
        case "panicFade": if let v = c.double("value") { edit { $0.panicFade = min(10, max(0, v)) } }
        case "goGuard": if let v = c.double("value") { edit { $0.doubleGoGuard = min(2, max(0, v)) } }
        case "buffer": bufferFrames = c.int("frames") ?? 512; dirty = true
        case "outputInfo":
            outputName = c.str("name") ?? ""
            outputError = c.str("error")
            if c.bool("recovered") == true { interruptions += 1 }
            dirty = true
        case "restartOutput": restartOutput()
        case "saveDevice":
            if let d = c.decode(OSCDevice.self, "device") {
                edit { doc in if let i = doc.devices.firstIndex(where: { $0.id == d.id }) { doc.devices[i] = d } else { doc.devices.append(d) } }
            }
        case "deleteDevice": if let id { edit { $0.devices.removeAll { $0.id == id } } }
        // Transport
        case "go": go()
        case "panic": panic()
        case "pauseAll": run { e, now in e.pauseAll(now: now) }
        case "resumeAll": run { e, now in e.resumeAll(now: now) }
        case "start": if let id { startCue(id) }
        case "stop": if let id { run { e, now in e.stop(id, now: now) } }
        case "togglePause": if let id { togglePause(id) }
        case "setPlayhead": setPlayhead(id)
        case "seek": if let id { let s = c.double("seconds") ?? 0; run { e, now in e.seek(id, to: s, now: now) } }
        case "pad": if let id { pad(id, pressed: c.bool("pressed") ?? true) }
        case "pauseSelected": selectedCues.forEach(togglePause)
        case "stopSelected": stopSelected()
        case "loadSelected": selectedCues.forEach { id in run { e, _ in e.load(id) } }
        case "startSelected": selectedCues.forEach { startCue($0) }
        case "moveCursor": moveCursor(by: c.int("delta") ?? 1)
        case "movePlayhead": movePlayhead(by: c.int("delta") ?? 1)
        case "jump": jumpToCue(c.str("number") ?? "")
        case "loadToTime": loadSelectedToTime(c.str("value") ?? "")
        case "hotkey": hotkey(c.str("key") ?? "")
        case "fkey": functionKey(c.str("key") ?? "", down: c.bool("down") ?? true)
        // Waveform editor
        case "audition": if let id, let cue = doc.cue(id) { auditionCue(cue, from: c.double("from") ?? 0, length: c.double("length")) }
        case "stopAudition": stopAudition()
        case "trim": if let id { trimSilence(id) }
        case "slice": waveSlice(c)
        case "envSample": envelopeSample(c)
        // OSC devices
        default: return oscOp(op, c)
        }
        return true
    }

    func tick(_ now: Date, engine: Engine) {
        if !started { start(engine) }
        pollOutput()
        if let d = pendingDocument {
            pendingDocument = nil
            doc = d
        }
        playbackTick(now)
        if let g = goGuardUntil, now >= g { goGuardUntil = nil; live.forceEmit = true }
        if let a = audition, now >= a.endsAt { audition = nil; dirty = true }
        if let t = autosaveAt, now >= t { autosaveAt = nil; autosave() }
        oscTick(now)
        if dirty { dirty = false; emitState() }
    }

    /// First command or tick: the autosaved show, the network addresses, the static tables.
    func start(_ engine: Engine) {
        started = true
        dataDir = engine.dataDir
        playback.clips.folder = dataDir.appendingPathComponent("Cache/Audio", isDirectory: true)
        if let data = try? Data(contentsOf: autosaveURL), let d = try? ShowDocument.decode(data) {
            doc = d
        }
        listID = doc.cueLists.first?.id
        bankID = doc.banks.first?.id
        emitStatic()
        Out.emit("netInterfaces")
        restartOutput()
        refreshFiles()
    }

    // MARK: Helpers

    func uuid(_ s: String?) -> UUID? { s.flatMap { UUID(uuidString: $0) } }
    func strings(_ c: Command, _ k: String) -> [String] { c.fields[k] as? [String] ?? [] }
    var currentList: CueList? { doc.list(listID) }
    var currentBank: CueList? { doc.banks.first { $0.id == bankID } ?? doc.banks.first }
    var autosaveURL: URL { dataDir.appendingPathComponent("show-autosave.json") }

    // MARK: Editing with undo

    func edit(_ change: (inout ShowDocument) -> Void) {
        guard !showMode else { return }
        let before = doc
        change(&doc)
        if doc != before { trackShape() }
        guard doc != before else { return }
        undoStack.append(before)
        if undoStack.count > 200 { undoStack.removeFirst(undoStack.count - 200) }
        redoStack = []
        dirty = true
    }

    func undo() {
        guard let d = undoStack.popLast() else { return }
        redoStack.append(doc)
        doc = d
        dirty = true
    }

    func redo() {
        guard let d = redoStack.popLast() else { return }
        undoStack.append(doc)
        doc = d
        dirty = true
    }

    private func documentEdited() {
        playback.engine?.document = doc
        if listID == nil || !doc.cueLists.contains(where: { $0.id == listID }) { listID = doc.cueLists.first?.id }
        if bankID == nil || !doc.banks.contains(where: { $0.id == bankID }) { bankID = doc.banks.first?.id }
        if let g = timelineGroup, doc.cue(g) == nil { timelineGroup = nil }
        autosaveAt = Date().addingTimeInterval(1)
        refreshFiles()
        dirty = true
        live.forceEmit = true
    }

    func updateCue(_ id: UUID, _ change: (inout Cue) -> Void) {
        edit { $0.updateCue(id, change) }
    }

    /// The interface's bindings: dotted paths of the cue's file format ("audio.level", "fade.duration", "name")
    /// set to JSON values (null = none). The cue goes through its own Codable, so only valid values get in.
    func setFields(_ id: UUID, _ fields: [String: Any]) {
        guard let cue = doc.cue(id), let d = try? JSONEncoder().encode(cue),
              var obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return }
        for (path, value) in fields {
            obj = Self.setting(obj, path.split(separator: ".").map(String.init)[...], value) as? [String: Any] ?? obj
        }
        guard JSONSerialization.isValidJSONObject(obj), let data = try? JSONSerialization.data(withJSONObject: obj),
              var new = try? JSONDecoder().decode(Cue.self, from: data) else { return }
        new.id = id
        new.children = cue.children
        updateCue(id) { $0 = new }
    }

    static func setting(_ obj: Any, _ path: ArraySlice<String>, _ value: Any) -> Any {
        guard let key = path.first else { return value }
        var dict = obj as? [String: Any] ?? [:]
        dict[key] = path.count == 1 ? value : setting(dict[key] ?? [String: Any](), path.dropFirst(), value)
        return dict
    }

    // MARK: Cue creation

    /// Adds a cue after the selection (targeting the selected cue when the kind needs a target).
    func add(_ kind: CueKind) {
        guard let lid = listID else { return }
        var c = Cue(kind: kind, number: kind == .memo || kind == .group ? "" : doc.nextCueNumber)
        if kind == .group { c.groupMode = .simultaneous }   // New groups are timeline groups
        let anchor = lastSelected
        if kind.needsTarget, let a = anchor, let target = doc.cue(a) {
            if doc.targetCandidates(for: kind, excluding: c.id).contains(where: { $0.id == target.id }) {
                c.target = target.id
            }
        }
        if kind == .group, selection.count > 1 {
            var newID: UUID?
            let ids = Array(selection)
            edit { newID = $0.group(ids, list: lid) }
            selection = newID.map { [$0] } ?? []
            return
        }
        let new = c
        edit { $0.insert([new], after: anchor, list: lid) }
        selection = [c.id]
    }

    /// A fade-in or fade-out aimed at the selected cue (`name`: the interface's "Fade in" / "Fade out").
    func addFade(fadeIn: Bool, name: String) {
        add(.fade)
        guard let id = selection.first else { return }
        updateCue(id) { c in
            var f = FadeCueParams.preset(fadeIn: fadeIn)
            f.duration = c.fade?.duration ?? 3
            c.fade = f
            if c.name.isEmpty { c.name = name }
        }
    }

    /// The last selected cue in show order.
    var lastSelected: UUID? {
        guard let list = currentList else { return nil }
        return list.cues.flattened().map(\.cue.id).last { selection.contains($0) }
    }

    /// Selected cues in show order.
    var orderedSelection: [UUID] {
        guard let list = currentList else { return [] }
        return list.cues.flattened().map(\.cue.id).filter { selection.contains($0) }
    }

    var selectedCues: [UUID] { orderedSelection.isEmpty ? Array(selection) : orderedSelection }

    /// Adds audio files as cues; they play from where they are and are copied into the show's folder on save.
    func addAudioFiles(_ paths: [String], after: UUID? = nil, intoGroup: UUID? = nil) {
        guard let lid = listID, !paths.isEmpty else { return }
        var number = Double(doc.nextCueNumber) ?? 1
        let sorted = paths.sorted { ShowPaths.basename($0).compare(ShowPaths.basename($1), options: [.caseInsensitive, .numeric]) == .orderedAscending }
        let cues: [Cue] = sorted.map {
            defer { number += 1 }
            return Cue.audio(file: storedPath(for: $0), number: String(Int(number)))
        }
        let anchor = after ?? lastSelected
        edit {
            if let g = intoGroup { $0.append(cues, toGroup: g) } else { $0.insert(cues, after: anchor, list: lid) }
        }
        selection = Set(cues.map(\.id))
    }

    func setFile(_ path: String, for cueID: UUID) {
        let stored = storedPath(for: path)
        let name = ShowPaths.stem(path)
        edit { d in
            d.updateCue(cueID) { c in
                c.audio?.file = stored
                if c.name.isEmpty { c.name = name }
            }
        }
    }

    // MARK: One-shot pads

    /// Adds audio files as pads of the current bank, each on the next free F-key.
    func addPads(_ paths: [String], bankWord: String) {
        if doc.banks.isEmpty { edit { $0.lists.append(CueList(name: "\(bankWord) 1", isBank: true)) } }
        guard let bank = currentBank, !paths.isEmpty else { return }
        var used = Set(doc.allCues.compactMap(\.hotkey))
        let pads: [Cue] = paths.map { p in
            var c = Cue.audio(file: storedPath(for: p))
            if let key = ShowDocument.functionKeys.first(where: { !used.contains($0) }) {
                c.hotkey = key
                used.insert(key)
            }
            return c
        }
        edit { $0.insert(pads, after: nil, list: bank.id) }
        selection = Set(pads.map(\.id))
    }

    func addBank(_ bankWord: String) {
        let b = CueList(name: "\(bankWord) \(doc.banks.count + 1)", isBank: true)
        edit { $0.lists.append(b) }
        bankID = b.id
    }

    func pad(_ id: UUID, pressed: Bool) {
        if pressed { ProfileModule.shared?.record("qtrl.oneShot") }
        run { e, now in e.pad(id, pressed: pressed, now: now) }
    }

    /// File length of an audio cue in seconds, when loaded.
    func fileLength(_ cue: Cue) -> Double? {
        resolvedPath(cue).flatMap { clipInfo[$0]?.duration }
    }

    // MARK: Structure

    func deleteSelection() {
        let ids = selection
        if live.snapshot.running.contains(where: { ids.contains($0.id) }) { ProfileModule.shared?.record("qtrl.deletePlaying") }
        // A deleted cue stops sounding at once (the engine stops it when the edit reaches it); so does its preview.
        if let a = audition, ids.contains(a.cue) || ids.contains(where: { doc.cue($0)?.children.findCue(a.cue) != nil }) { stopAudition() }
        edit { $0.delete(ids) }
        selection = []
    }

    func duplicateSelection() {
        guard let lid = listID else { return }
        var copies: [UUID] = []
        let ids = orderedSelection
        edit { copies = $0.duplicate(ids, list: lid) }
        selection = Set(copies)
    }

    func moveSelection(by delta: Int) {
        guard let lid = listID else { return }
        let ids = delta < 0 ? orderedSelection : orderedSelection.reversed()
        edit { d in ids.forEach { d.move($0, by: delta, list: lid) } }
    }

    func ungroupSelection() {
        guard let lid = listID else { return }
        let groups = orderedSelection.filter { doc.cue($0)?.kind == .group }
        edit { d in groups.forEach { d.ungroup($0, list: lid) } }
    }

    func renumberSelection() {
        guard let lid = listID else { return }
        let ids = selection.isEmpty ? nil : orderedSelection
        edit { $0.renumber(ids, list: lid) }
    }

    /// A drag in the cue list: cues before a row, or into a group.
    func moveCues(_ dragged: [UUID], before: UUID?, into target: UUID?) {
        guard !showMode, let lid = listID, let first = dragged.first else { return }
        let ids = dragged.count == 1 && selection.contains(first) ? orderedSelection : dragged
        if let target {
            guard !ids.contains(target) else { return }
            edit { $0.move(ids, before: nil, intoGroup: target, list: lid) }
            collapsed.remove(target)
            return
        }
        guard before != first else { return }
        edit { $0.move(ids, before: before, list: lid) }
    }

    func addList(_ listWord: String) {
        let l = CueList(name: "\(listWord) \(doc.lists.count + 1)")
        edit { $0.lists.append(l) }
        selectList(l.id)
    }

    func selectList(_ id: UUID) {
        listID = id
        selection = []
        playback.engine?.selectList(id)
    }

    // MARK: Cue settings with logic of their own (the inspector)

    /// Fade out (to silence) or fade in (from silence up to the target's level).
    func fadePreset(_ id: UUID, fadeIn: Bool) {
        updateCue(id) { c in
            var f = FadeCueParams.preset(fadeIn: fadeIn)
            f.duration = c.fade?.duration ?? 3
            f.curve = c.fade?.curve ?? .sCurve
            c.fade = f
        }
    }

    /// Crosspoints: file channel × show output, click to connect.
    func route(_ id: UUID, channel c: Int, output o: Int, channels: Int) {
        let outputs = doc.outputs.count
        guard c >= 0, c < channels, o >= 0, o < outputs else { return }
        updateCue(id) { cue in
            guard var a = cue.audio else { return }
            if a.routing.count < channels {
                // Materialise the default routing before the first manual change.
                a.routing = (0..<channels).map { ch in (0..<outputs).map { a.crosspoint(channel: ch, output: $0, fileChannels: channels) } }
            }
            while a.routing[c].count < outputs { a.routing[c].append(showSilenceDB) }
            a.routing[c][o] = a.routing[c][o] > showSilenceDB ? showSilenceDB : 0
            cue.audio = a
        }
    }

    /// Integrated fade on / off.
    func envelopeOn(_ id: UUID, _ on: Bool) {
        updateCue(id) { c in
            if c.audio?.envelope == nil { c.audio?.envelope = VolumeEnvelope() }
            c.audio?.envelope?.enabled = on
        }
    }

    /// Once / loop all / loop a part (WaveformEditor's picker).
    func loopMode(_ id: UUID, _ m: Int) {
        guard let cue = doc.cue(id) else { return }
        let length = fileLength(cue) ?? cue.audio?.end ?? 0
        updateCue(id) { c in
            guard var p = c.audio else { return }
            switch m {
            case 0: p.loopStart = nil; p.loopEnd = nil; p.plays = 1
            case 1: p.loopStart = nil; p.loopEnd = nil; if p.plays == 1 { p.plays = 0 }
            default:
                let s = p.start, e = p.end ?? length
                p.loopStart = ((s + (e - s) / 3) * 100).rounded() / 100
                p.loopEnd = ((s + 2 * (e - s) / 3) * 100).rounded() / 100
                if p.plays == 1 { p.plays = 0 }
            }
            c.audio = p
        }
    }

    func setOutputCount(_ count: Int) {
        edit { d in
            let n = min(64, max(1, count))
            while d.outputs.count < n {
                let i = d.outputs.count
                d.outputs.append(ShowOutput(name: "\(i + 1)", deviceChannel: i))
            }
            if d.outputs.count > n { d.outputs.removeLast(d.outputs.count - n) }
        }
    }

    // MARK: Transport

    func go() {
        trackGo()
        // A red border on GO while double-GO protection holds it.
        if doc.doubleGoGuard > 0, goGuardUntil == nil {
            goGuardUntil = Date().addingTimeInterval(doc.doubleGoGuard)
            live.forceEmit = true
        }
        run { e, now in e.go(now: now) }
    }

    func panic() {
        if !live.snapshot.running.isEmpty, let c = ProfileModule.shared {
            c.record("qtrl.panic")
            if let t = progress.lastPanicTap, Date().timeIntervalSince(t) < 1.5 { c.record("qtrl.panicHard") }
            progress.lastPanicTap = Date()
        }
        run { e, now in e.panic(now: now) }
    }

    func startCue(_ id: UUID) {
        if let cue = doc.cue(id) { trackFired(cue) }
        run { e, now in e.start(id, now: now) }
    }

    func togglePause(_ id: UUID) {
        let paused = live.snapshot.running.first { $0.id == id }?.paused ?? false
        run { e, now in paused ? e.resume(id, now: now) : e.pause(id, now: now) }
    }

    func setPlayhead(_ id: UUID?) { run { e, _ in e.setPlayhead(id) } }

    /// S: stops the selected cues with the panic fade; S again within a second stops them at once.
    func stopSelected() {
        let hard = lastStop.map { Date().timeIntervalSince($0) < 1 } ?? false
        lastStop = hard ? nil : Date()
        let fade = hard ? 0 : doc.panicFade
        for id in selectedCues { run { e, now in e.stop(id, now: now, fade: fade) } }
    }

    /// ↑ / ↓: the previous / next row is selected and gets the playhead where it can stand (as a click does).
    func moveCursor(by delta: Int) {
        let rows = currentList?.cues.flattened(collapsed: collapsed) ?? []
        guard !rows.isEmpty else { return }
        let current = rows.lastIndex { selection.contains($0.cue.id) } ?? (delta > 0 ? -1 : rows.count)
        let i = max(0, min(rows.count - 1, current + delta))
        selection = [rows[i].cue.id]
        setPlayhead(rows[i].cue.id)
    }

    /// ⇧Ctrl↑ / ⇧Ctrl↓: the playhead to the previous / next top-level cue.
    func movePlayhead(by delta: Int) {
        guard let cues = currentList?.cues, !cues.isEmpty else { return }
        let ph = live.snapshot.playhead
        let i = ph.flatMap { id in cues.firstIndex { $0.id == id } } ?? (delta > 0 ? -1 : cues.count)
        let j = i + delta
        setPlayhead(cues.indices.contains(j) ? cues[j].id : nil)
    }

    /// Ctrl+J: the cue with this number is selected and gets the playhead.
    func jumpToCue(_ n: String) {
        guard let cue = doc.allCues.first(where: { $0.number == n.trimmingCharacters(in: .whitespaces) }) else { return }
        if let l = doc.cueLists.first(where: { $0.cues.findCue(cue.id) != nil }), l.id != listID { selectList(l.id) }
        selection = [cue.id]
        setPlayhead(cue.id)
    }

    /// Ctrl+T: the selected audio cue's (or timeline group's) next start begins this many seconds in.
    func loadSelectedToTime(_ v: String) {
        guard selection.count == 1, let id = selection.first, let c = doc.cue(id),
              c.kind == .audio || (c.kind == .group && c.groupMode == .simultaneous),
              let s = Double(v.replacingOccurrences(of: ",", with: ".")) else { return }
        run { e, _ in e.loadToTime(id, seconds: s) }
    }

    /// Hotkeys the person gave to cues: a pad of a bank is pressed, any other cue starts.
    func hotkey(_ ch: String) {
        let key = ch.lowercased()
        guard !key.isEmpty, let cue = doc.allCues.first(where: { ($0.hotkey ?? "").lowercased() == key }) else { return }
        if doc.banks.contains(where: { $0.cues.findCue(cue.id) != nil }) { pad(cue.id, pressed: true) } else {
            startCue(cue.id)
        }
    }

    /// One-shot pads on F-keys: press and release (for "hold" pads).
    func functionKey(_ key: String, down: Bool) {
        guard let cue = doc.allCues.first(where: { $0.hotkey == key }) else { return }
        pad(cue.id, pressed: down)
    }

    /// N, Q, E, D, W: the number, name, pre-wait, duration or post-wait of the selected cue (typed in a prompt).
    func editSelected(_ field: String, _ v: String) {
        guard selection.count == 1, let id = selection.first, let cue = doc.cue(id) else { return }
        if field == "duration" && cue.kind != .wait && cue.kind != .fade { return }
        let seconds = Double(v.replacingOccurrences(of: ",", with: "."))
        edit { d in
            d.updateCue(id) { c in
                switch field {
                case "number": c.number = v
                case "name": c.name = v
                case "preWait": if let s = seconds { c.preWait = max(0, s) }
                case "duration": if let s = seconds { if c.kind == .fade { c.fade?.duration = max(0, s) } else { c.duration = max(0, s) } }
                case "postWait": if let s = seconds { c.postWait = max(0, s) }
                default: break
                }
            }
        }
    }

    /// C: no continue → auto-continue → auto-follow → no continue.
    func cycleContinueMode() {
        let ids = selectedCues
        guard !ids.isEmpty else { return }
        edit { d in
            for id in ids {
                d.updateCue(id) { c in
                    switch c.continueMode {
                    case .none: c.continueMode = .autoContinue
                    case .autoContinue: c.continueMode = .autoFollow
                    case .autoFollow: c.continueMode = .none
                    }
                }
            }
        }
    }

    /// Alt+← / Alt+→: pre-wait of the selected cues −/+ 0.1 s, which moves them on a group timeline.
    func nudgePreWait(_ delta: Double) {
        let ids = selectedCues
        guard !ids.isEmpty else { return }
        edit { d in
            for id in ids { d.updateCue(id) { $0.preWait = max(0, (($0.preWait + delta) * 100).rounded() / 100) } }
        }
    }

    private func copySelection() {
        cueClipboard = orderedSelection.compactMap { doc.cue($0) }
    }

    private func pasteCues() {
        guard let lid = listID, !cueClipboard.isEmpty else { return }
        let copies = cueClipboard.map { $0.duplicated() }
        let after = lastSelected
        edit { $0.insert(copies, after: after, list: lid) }
        selection = Set(copies.map(\.id))
    }

    // MARK: Files

    /// Absolute path of a cue's file (relative paths are resolved against the show file's folder).
    func resolvedPath(_ cue: Cue) -> String? {
        guard let f = cue.audio?.file, !f.isEmpty else { return nil }
        return ShowPaths.resolve(f, show: filePath)
    }

    /// Paths are stored absolute; files next to the show file are stored relative to it ("/" between folders, as on
    /// the Mac, so a show folder opens on both).
    func storedPath(for path: String) -> String {
        guard let show = filePath else { return path }
        let base = ShowPaths.dirname(show)
        for sep in ["/", "\\"] where path.hasPrefix(base + sep) {
            return String(path.dropFirst(base.count + 1)).replacingOccurrences(of: "\\", with: "/")
        }
        return path
    }

    /// Where the show's audio is gathered on save: "<show> Audio" next to the show file.
    var mediaFolder: String? {
        filePath.map { ShowPaths.join(ShowPaths.dirname($0), ShowPaths.stem($0) + " Audio") }
    }

    /// On save: every audio file outside the show's media folder is copied into it and stored relative to the
    /// show, so the show folder carries everything it plays. `oldShow` resolves the current relative paths.
    private func collectMedia(oldShow: String?) {
        guard let folder = mediaFolder else { return }
        var paths: [UUID: String] = [:]
        var failed: [String] = []
        for c in doc.allCues {
            guard let f = c.audio?.file, !f.isEmpty else { continue }
            let src = ShowPaths.resolve(f, show: oldShow)
            var copied: String?
            if FileManager.default.fileExists(atPath: src) {
                let r = ShowMedia.copy([URL(fileURLWithPath: src)], into: URL(fileURLWithPath: folder, isDirectory: true))
                copied = r.copied.first.map(ShowPaths.native)
                failed += r.errors
            }
            // Copied: relative to the show. Not copied (missing, no access): the full old path, so a relative path
            // does not end up pointing into the new show's folder.
            paths[c.id] = copied.map { storedPath(for: $0) } ?? src
        }
        if paths.contains(where: { doc.cue($0.key)?.audio?.file != $0.value }) {
            edit { d in for (id, p) in paths { d.updateCue(id) { $0.audio?.file = p } } }
        }
        if !failed.isEmpty { lastError = ["key": "show.import.failed", "suffix": " " + failed.joined(separator: "; ")] }
    }

    /// Checks files and decodes them in the background so GO never waits for disk.
    func refreshFiles(load: Bool = true) {
        let paths = Set(doc.allCues.compactMap { resolvedPath($0) })
        missingFiles = Set(paths.filter { !FileManager.default.fileExists(atPath: $0) })
        unreadableFiles = unreadableFiles.filter { paths.contains($0.key) }
        dirty = true
        guard load, !previewing else { return }
        let sr = playback.sampleRate
        let todo = paths.subtracting(missingFiles).filter { clipInfo[$0] == nil || playback.clips.cached($0, sampleRate: sr) == nil }
        for p in todo where playback.clips.failure(p) == nil {
            if let clip = playback.clips.load(p, sampleRate: sr) { clipReady(p, clip) }
        }
        playback.clips.forget(except: paths)
    }

    /// A file is decoded (or mapped from the cache): its length, channels and overview.
    func clipReady(_ path: String, _ clip: AudioClip) {
        clipInfo[path] = (duration: clip.duration, channels: clip.channelCount)
        unreadableFiles[path] = nil
        if waveforms[path] == nil {
            let w = ShowWaveform.overview(clip)
            waveforms[path] = w
            emitWave(path, w)
        }
        for id in pendingTrims.removeValue(forKey: path) ?? [] { trimSilence(id) }
        dirty = true
        live.forceEmit = true
    }

    /// Looks for missing files by name inside a folder (recursively) and relinks them.
    func relinkMissing(folder: String) {
        var found: [String: String] = [:]
        if let e = FileManager.default.enumerator(at: URL(fileURLWithPath: folder, isDirectory: true), includingPropertiesForKeys: nil) {
            for case let url as URL in e {
                let p = ShowPaths.native(url)
                found[ShowPaths.basename(p).lowercased()] = p
            }
        }
        var relinked = 0
        let missing = missingFiles
        let show = filePath
        edit { d in
            for c in d.allCues {
                guard let f = c.audio?.file, missing.contains(ShowPaths.resolve(f, show: show)),
                      let p = found[ShowPaths.basename(f).lowercased()] else { continue }
                let stored = self.storedPath(for: p)
                d.updateCue(c.id) { $0.audio?.file = stored }
                relinked += 1
            }
        }
        lastError = ["key": "show.relink.done", "args": [relinked]]
    }

    /// Pre-show check.
    func checkShow() -> [ShowIssue] {
        doc.issues { cue in
            guard let p = resolvedPath(cue) else { return false }
            return FileManager.default.fileExists(atPath: p)
        }
    }

    // MARK: Documents

    func newDocument() {
        guard !showMode else { return }
        run { e, now in e.panic(now: now, hard: true) }
        edit { $0 = ShowDocument(name: "") }
        filePath = nil
        selection = []
        listID = doc.cueLists.first?.id
    }

    func open(_ path: String) {
        do {
            let d = try ShowDocument.decode(Data(contentsOf: URL(fileURLWithPath: path)))
            run { e, now in e.panic(now: now, hard: true) }
            filePath = path
            edit { $0 = d }
            listID = d.cueLists.first?.id
            selection = []
            restartOutput()
            refreshFiles()
        } catch {
            lastError = ["text": "\(ShowPaths.basename(path)): \(error)"]
        }
    }

    func save(path: String?) {
        guard let path = path ?? filePath else { return }
        let old = filePath
        filePath = path
        collectMedia(oldShow: old)
        do {
            try doc.encoded().write(to: URL(fileURLWithPath: path), options: .atomic)
            if doc.allCues.count >= 100 { ProfileModule.shared?.record("qtrl.bigShow") }
        } catch {
            filePath = old
            lastError = ["text": "\(ShowPaths.basename(path)): \(error)"]
        }
        refreshFiles()
    }

    private func autosave() {
        guard let data = try? doc.encoded() else { return }
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        try? data.write(to: autosaveURL, options: .atomic)
    }

    // MARK: Playback link

    func run(_ action: (ShowEngine, Int64) -> Void) {
        guard let e = playback.engine else { return }
        action(e, playback.now)
        live.forceEmit = true
    }
}

/// Paths as the Mac stores them (absolute, or relative to the show file with "/"), for Windows paths as well.
enum ShowPaths {
    static func isAbsolute(_ p: String) -> Bool {
        if p.hasPrefix("/") || p.hasPrefix("\\") { return true }
        let u = Array(p.utf8)
        return u.count >= 3 && u[1] == UInt8(ascii: ":") && (u[2] == UInt8(ascii: "\\") || u[2] == UInt8(ascii: "/"))
    }

    /// The separator a path uses ("\" for Windows paths).
    static func separator(_ p: String) -> String { p.contains("\\") && !p.hasPrefix("/") ? "\\" : "/" }

    static func dirname(_ p: String) -> String {
        guard let i = p.lastIndex(where: { $0 == "/" || $0 == "\\" }) else { return "" }
        return String(p[..<i])
    }

    static func basename(_ p: String) -> String {
        guard let i = p.lastIndex(where: { $0 == "/" || $0 == "\\" }) else { return p }
        return String(p[p.index(after: i)...])
    }

    /// File name without its extension.
    static func stem(_ p: String) -> String {
        let b = basename(p)
        guard let dot = b.lastIndex(of: "."), dot != b.startIndex else { return b }
        return String(b[..<dot])
    }

    static func join(_ dir: String, _ rel: String) -> String {
        let sep = separator(dir)
        let r = sep == "\\" ? rel.replacingOccurrences(of: "/", with: "\\") : rel
        return dir.hasSuffix(sep) ? dir + r : dir + sep + r
    }

    static func resolve(_ path: String, show: String?) -> String {
        if isAbsolute(path) { return path }
        if let show { return join(dirname(show), path) }
        return path
    }

    /// The file system's own spelling of a file URL ("C:\…" on Windows).
    static func native(_ u: URL) -> String {
        u.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } } ?? u.path
    }
}

/// What the waveform editor is playing.
struct ShowAudition {
    var cue: UUID
    var from: Double
    var length: Double
    var rate: Double
    var endsAt: Date
}

// MARK: - Progress (achievements), as ShowStore's

/// What the achievements of Qtrl keep between events.
struct ShowProgressState {
    var lastPanicTap: Date?
    var sessionGos = 0
    var pausedSince: Date?
    var loopSince: [UUID: Date] = [:]
    var lastShapeCheck = Date.distantPast
}

extension ShowModule: ProgressSampling {
    /// GO and starts: what kind of cue fired, a clean run of 30 GOs earns the show XP.
    func trackGo() {
        guard let c = ProfileModule.shared else { return }
        if goGuardUntil != nil { c.record("qtrl.doubleGo"); return }
        c.record("qtrl.go")
        if let cue = doc.cue(live.snapshot.playhead) { trackFired(cue) }
        progress.sessionGos += 1
        if progress.sessionGos == 30, live.snapshot.problems.isEmpty {
            c.record("qtrl.cleanShow")
            c.record("qtrl.show")
        }
    }

    func trackFired(_ cue: Cue) {
        switch cue.kind {
        case .fade: ProfileModule.shared?.record("qtrl.fade")
        case .network: ProfileModule.shared?.record("qtrl.osc")
        default: break
        }
    }

    /// Every 5 s: long pauses and long loops.
    func sampleProgress() {
        guard let c = ProfileModule.shared else { return }
        let snapshot = live.snapshot
        if !snapshot.running.isEmpty, snapshot.running.allSatisfy(\.paused) {
            if progress.pausedSince == nil { progress.pausedSince = Date() }
            if let p = progress.pausedSince, Date().timeIntervalSince(p) > 15 * 60 { c.record("qtrl.longPause") }
        } else {
            progress.pausedSince = nil
        }
        let looping = snapshot.running.filter { ($0.iteration ?? 0) > 0 && !$0.paused }.map(\.id)
        progress.loopSince = progress.loopSince.filter { looping.contains($0.key) }
        for id in looping where progress.loopSince[id] == nil { progress.loopSince[id] = Date() }
        if let oldest = progress.loopSince.values.min() { c.recordMax("qtrl.loopMinutes", Int(Date().timeIntervalSince(oldest) / 60)) }
    }

    /// Biggest playlist and timeline group in the show (at most once a second: drags edit many times a second).
    func trackShape() {
        guard Date().timeIntervalSince(progress.lastShapeCheck) > 1 else { return }
        progress.lastShapeCheck = Date()
        let groups = doc.allCues.filter { $0.kind == .group }
        ProfileModule.shared?.recordMax("qtrl.maxPlaylist", groups.filter { $0.groupMode == .playlist }.map(\.children.count).max() ?? 0)
        ProfileModule.shared?.recordMax("qtrl.maxTimelineTracks", groups.filter { $0.groupMode == .simultaneous }.map(\.children.count).max() ?? 0)
    }
}
