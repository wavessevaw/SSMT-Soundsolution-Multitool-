import AppKit
import Combine
import Foundation
import SSMTAudio
import SSMTCore
import UniformTypeIdentifiers

/// The playback side, confined to one serial queue: engine, mixer clock and audio output.
private final class PlaybackCore: @unchecked Sendable {
    let queue = DispatchQueue(label: "ssmt.show.engine", qos: .userInteractive)
    var engine: ShowEngine?
    var output: ShowAudioOutput?
    var timer: DispatchSourceTimer?
    let clips = ClipCache()
    var ticks = 0
    /// Folder for relative file paths (the show file's URL).
    var showURL: URL?

    /// Sample rate of the backup clock (used while no audio output runs).
    var clockRate: Double = 48000
    private let clockStart = DispatchTime.now().uptimeNanoseconds

    /// Show clock: the output's sample counter; without an output (interface missing) the system
    /// clock keeps OSC cues, waits and auto-continue running.
    var now: Int64 {
        if let out = output { return Int64(out.mixer.framesRendered.value) }
        return Int64(Double(DispatchTime.now().uptimeNanoseconds - clockStart) / 1e9 * clockRate)
    }
}

/// The open show: document with undo, file handling, selection, and the link to the playback engine.
@MainActor
final class ShowStore: ObservableObject {
    @Published var doc: ShowDocument {
        didSet { if doc != oldValue { documentEdited() } }
    }
    @Published private(set) var fileURL: URL? {
        didSet { let u = fileURL; core.queue.async { [core] in core.showURL = u } }
    }
    @Published var selection = Set<Cue.ID>()
    @Published var listID: UUID?
    /// One-shot bank shown in the pad grid.
    @Published var bankID: UUID?
    /// Panels around the cue list (remembered).
    @Published var showSidebar = UserDefaults.standard.object(forKey: "ssmt.show.sidebar") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showSidebar, forKey: "ssmt.show.sidebar") }
    }
    @Published var showInspector = UserDefaults.standard.object(forKey: "ssmt.show.inspector") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showInspector, forKey: "ssmt.show.inspector") }
    }
    @Published var showTimeline = UserDefaults.standard.bool(forKey: "ssmt.show.timeline") {
        didSet { UserDefaults.standard.set(showTimeline, forKey: "ssmt.show.timeline") }
    }
    /// Inspector tab (kept when the selection changes, as in QLab).
    @Published var inspectorTab: InspectorTab = .main
    @Published var sidebarTab = QtrlSidebarTab(rawValue: UserDefaults.standard.string(forKey: "ssmt.show.sidebarTab") ?? "") ?? .active {
        didSet { UserDefaults.standard.set(sidebarTab.rawValue, forKey: "ssmt.show.sidebarTab") }
    }
    /// Timeline shows this group's contents for editing (nil = the live show).
    @Published var timelineGroup: UUID?
    /// File overview (peak per bucket, 0…1) by resolved path, for waveforms.
    @Published private(set) var waveforms: [String: [Float]] = [:]
    @Published var collapsed = Set<Cue.ID>()
    /// Show mode: editing locked, big transport, keyboard GO.
    @Published var showMode = false {
        didSet { updateActivity() }
    }
    @Published var showSettings = false
    /// OSC devices window; `oscWizardKind` opens it straight on a device's setup.
    @Published var showOSC = false
    var oscWizardKind: OSCDeviceKind?
    let osc = OSCHub()
    @Published private(set) var snapshot = ShowSnapshot.empty
    /// When `snapshot` was taken: views move playback cursors on smoothly between snapshots.
    private(set) var snapshotDate = Date()
    @Published private(set) var meters: [Float] = []
    /// Outputs that clipped in the last 1.5 s.
    @Published private(set) var clipping: [Bool] = []
    private var clipUntil: [Int: Date] = [:]
    @Published private(set) var outputName = ""
    @Published private(set) var outputError: String?
    @Published private(set) var sampleRate: Double = 48000
    @Published private(set) var memoryBytes = 0
    /// Times the audio output was interrupted and recovered during this session.
    @Published private(set) var interruptions = 0
    /// Files still being prepared (decoded into the cache) and files that cannot be read.
    @Published private(set) var loadingFiles = 0
    @Published private(set) var unreadableFiles: [String: String] = [:]
    /// Device I/O buffer: larger is safer on slow Macs, smaller has less delay.
    @Published var bufferFrames = UserDefaults.standard.object(forKey: "ssmt.qtrl.buffer") as? Int ?? 512 {
        didSet { UserDefaults.standard.set(bufferFrames, forKey: "ssmt.qtrl.buffer") }
    }
    private var activity: NSObjectProtocol?
    /// Clip lengths (seconds) and channel counts by resolved path, for the list and inspector.
    @Published private(set) var clipInfo: [String: (duration: Double, channels: Int)] = [:]
    @Published private(set) var missingFiles = Set<String>()
    @Published var lastError: String?
    /// The section is visible (keyboard shortcuts active).
    var isActive = false {
        didSet {
            if isActive && !outputStarted { outputStarted = true; restartOutput() }
            updateActivity()
        }
    }

    /// While Qtrl is open the Mac must not sleep, nap or throttle audio; in show mode the display stays on too.
    private func updateActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        guard isActive || showMode, outputStarted, outputName != "Preview" else { return }
        var options: ProcessInfo.ActivityOptions = [.userInitiated, .latencyCritical, .idleSystemSleepDisabled]
        if showMode { options.insert(.idleDisplaySleepDisabled) }
        activity = ProcessInfo.processInfo.beginActivity(options: options, reason: "Qtrl show playback")
    }
    private var outputStarted = false

    weak var undo: UndoManager?
    /// Set by the workspace; used for undo action names and messages.
    weak var localizer: Localizer?
    private let core = PlaybackCore()
    private var autosaveWork: DispatchWorkItem?
    private var keyMonitor: Any?
    private var clickMonitor: Any?

    static let fileType = UTType(filenameExtension: "ssmtshow", conformingTo: .json) ?? .json
    /// Any audio, plus video files (their sound is used).
    static let audioTypes: [UTType] = [.audio, .mp3, .wav, .aiff, .mpeg4Audio, .audiovisualContent, .movie, .mpeg4Movie, .quickTimeMovie]

    nonisolated static func isPlayable(_ url: URL) -> Bool {
        guard let t = UTType(filenameExtension: url.pathExtension) else { return false }
        return t.conforms(to: .audio) || t.conforms(to: .audiovisualContent)
    }

    /// Decoding runs two files at a time so the Mac stays responsive.
    nonisolated private static let loader: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .userInitiated
        return q
    }()

    private static var autosaveURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SSMT", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("show-autosave.json")
    }

    init(startAudio: Bool = true) {
        if let data = try? Data(contentsOf: Self.autosaveURL), let d = try? ShowDocument.decode(data) {
            doc = d
        } else {
            doc = ShowDocument(name: "")
        }
        listID = doc.cueLists.first?.id
        DispatchQueue.global(qos: .background).async { ClipCache.prune() }
        if startAudio { outputStarted = true; restartOutput() }
    }

    /// For previews and snapshot tests: a document without audio output.
    init(document: ShowDocument) {
        doc = document
        listID = document.cueLists.first?.id
        outputStarted = true // never opens an audio device
    }

    var currentList: CueList? { doc.list(listID) }

    /// Snapshot tests: no audio device, and a fixed playback state to render.
    func preview(snapshot: ShowSnapshot, clips: [String: (duration: Double, channels: Int)], meters: [Float],
                 waveforms: [String: [Float]] = [:]) {
        self.waveforms = waveforms
        outputStarted = true
        self.snapshot = snapshot
        clipInfo = clips
        self.meters = meters
        missingFiles = []
        outputName = "Preview"
    }

    // MARK: Editing with undo

    func edit(_ name: String = "", _ change: (inout ShowDocument) -> Void) {
        guard !showMode else { return }
        let before = doc
        change(&doc)
        guard doc != before, let undo else { return }
        undo.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated { store.restore(before) }
        }
        undo.setActionName(name)
    }

    private func restore(_ state: ShowDocument) {
        let current = doc
        doc = state
        undo?.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated { store.restore(current) }
        }
    }

    private func documentEdited() {
        let d = doc
        core.queue.async { [core] in core.engine?.document = d }
        if listID == nil || !doc.cueLists.contains(where: { $0.id == listID }) { listID = doc.cueLists.first?.id }
        if bankID == nil || !doc.banks.contains(where: { $0.id == bankID }) { bankID = doc.banks.first?.id }
        if let g = timelineGroup, doc.cue(g) == nil { timelineGroup = nil }
        scheduleAutosave()
        refreshFiles()
    }

    // MARK: Cue creation

    /// Adds a cue after the selection (targeting the selected cue when the kind needs a target).
    func add(_ kind: CueKind) {
        guard let lid = listID else { return }
        var c = Cue(kind: kind, number: kind == .memo || kind == .group ? "" : doc.nextCueNumber)
        if kind == .group { c.groupMode = .simultaneous }   // QLab 5: new groups are timeline groups
        let anchor = lastSelected
        if kind.needsTarget, let a = anchor, let target = doc.cue(a) {
            if doc.targetCandidates(for: kind, excluding: c.id).contains(where: { $0.id == target.id }) {
                c.target = target.id
            }
        }
        if kind == .group, selection.count > 1 {
            var newID: UUID?
            edit { newID = $0.group(Array(selection), list: lid) }
            selection = newID.map { [$0] } ?? []
            return
        }
        edit { $0.insert([c], after: anchor, list: lid) }
        selection = [c.id]
    }

    /// A fade-in or fade-out aimed at the selected cue.
    func addFade(fadeIn: Bool) {
        add(.fade)
        guard let id = selection.first else { return }
        updateCue(id) { c in
            var f = FadeCueParams.preset(fadeIn: fadeIn)
            f.duration = c.fade?.duration ?? 3
            c.fade = f
            if c.name.isEmpty { c.name = self.loc(fadeIn ? "show.fadecue.in" : "show.fadecue.out") }
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

    /// Adds audio files as cues; they play from where they are and are copied into the show's folder on save.
    func addAudioFiles(_ urls: [URL], after: UUID? = nil, intoGroup: UUID? = nil) {
        insertAudioCues(urls.map(Self.filePath), after: after, intoGroup: intoGroup)
    }

    /// A file reference URL (as some drags deliver) turned into a path URL.
    nonisolated static func filePath(_ url: URL) -> URL { (url as NSURL).filePathURL ?? url }

    private func insertAudioCues(_ urls: [URL], after: UUID?, intoGroup: UUID?) {
        guard let lid = listID, !urls.isEmpty else { return }
        var number = Double(doc.nextCueNumber) ?? 1
        let cues: [Cue] = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }.map {
            defer { number += 1 }
            return Cue.audio(file: storedPath(for: $0), number: String(Int(number)))
        }
        edit {
            if let g = intoGroup { $0.append(cues, toGroup: g) } else { $0.insert(cues, after: after ?? lastSelected, list: lid) }
        }
        selection = Set(cues.map(\.id))
    }

    // MARK: QLab import

    @Published var showQLabImport = false
    /// A QLab file chosen with Open: the import window reads it when it appears.
    var pendingQLabFile: URL?
    /// QLab import is hidden until it is checked on real QLab files (the code and tests stay).
    static let qlabImportEnabled = false
    static let qlabTypes: [UTType] = ["qlab5", "qlab4", "qlab3"].compactMap { UTType(filenameExtension: $0) }

    /// Replaces the show with an imported QLab workspace (one undo step). Keeps this Mac's audio
    /// interface, outputs and OSC devices. Relative file paths are resolved against `baseFolder`.
    func adoptImported(_ lists: [QLabImport.Item], name: String, baseFolder: URL?) -> QLabImport.Report {
        var (imported, report) = QLabImport.makeShow(name: name, lists: lists)
        imported.outputs = doc.outputs
        imported.deviceUID = doc.deviceUID
        imported.devices = doc.devices
        if let base = baseFolder {
            for c in imported.allCues where c.kind == .audio {
                guard let f = c.audio?.file, !f.isEmpty, !f.hasPrefix("/") else { continue }
                imported.updateCue(c.id) { $0.audio?.file = base.appendingPathComponent(f).path }
            }
        }
        run { e, now in e.panic(now: now, hard: true) }
        edit(loc("qlab.title")) { $0 = imported }
        fileURL = nil
        selection = []
        listID = imported.cueLists.first?.id
        bankID = imported.banks.first?.id
        return report
    }

    // MARK: OSC

    /// Sends a Network cue's message now (inspector "Send now").
    func sendNow(_ cue: Cue) {
        guard let p = cue.osc, let id = p.device, let d = doc.devices.first(where: { $0.id == id }) else { return }
        osc.send(p.message, to: d)
    }

    /// Creates a Network cue from a message seen in the monitor (device chosen by sender address).
    func addNetworkCue(from entry: OSCLogEntry) {
        guard let lid = listID else { return }
        var c = Cue(kind: .network, number: doc.nextCueNumber)
        c.osc?.address = entry.message.address
        c.osc?.arguments = entry.message.arguments
        c.osc?.device = doc.devices.first { $0.host == entry.from }?.id ?? doc.devices.first?.id
        c.name = entry.message.address
        let anchor = lastSelected
        edit { $0.insert([c], after: anchor, list: lid) }
        selection = [c.id]
    }

    // MARK: Audition (waveform editor)

    /// What the editor is playing: cue, file position it started from, when, and how long (seconds).
    struct Audition: Equatable {
        var cue: UUID
        var from: Double
        var startedAt: Date
        var length: Double
        var rate: Double
    }
    @Published private(set) var audition: Audition?
    private static let auditionVoice = UUID()

    /// Plays a cue's file from `from` (file seconds) for `length` seconds (nil = to the region end).
    func audition(_ cue: Cue, from: Double, length: Double? = nil) {
        guard let path = resolvedPath(cue), let a = cue.audio, let fileLen = fileLength(cue) else { return }
        let end = min(fileLen, length.map { from + $0 } ?? (a.end ?? fileLen))
        guard end > from else { return }
        let outs = doc.outputs.count
        let voice = Self.auditionVoice
        let core = self.core
        core.queue.async {
            guard let mixer = core.output?.mixer else { return }
            let sr = mixer.sampleRate
            guard let clip = core.clips.cached(path, sampleRate: sr) ?? core.clips.load(path, sampleRate: sr),
                  let setup = ShowEngine.voiceSetup(cue, clip: clip, outputs: outs, from: from, length: end - from) else { return }
            mixer.send(.start(voice, clip: clip, setup: setup, at: core.now + Int64(sr * 0.03)))
        }
        audition = Audition(cue: cue.id, from: from, startedAt: Date().addingTimeInterval(0.03), length: end - from,
                            rate: max(0.05, a.rate))
        let token = audition
        DispatchQueue.main.asyncAfter(deadline: .now() + (end - from) / max(0.05, a.rate) + 0.1) { [weak self] in
            if self?.audition == token { self?.audition = nil }
        }
    }

    func stopAudition() {
        let voice = Self.auditionVoice
        let core = self.core
        core.queue.async {
            guard let mixer = core.output?.mixer else { return }
            mixer.send(.stop(voice, at: core.now, fadeFrames: Int64(mixer.sampleRate * 0.01)))
        }
        audition = nil
    }

    /// Sets start and end at the first and last sound above −50 dBFS.
    func trimSilence(_ cueID: UUID) {
        guard let cue = doc.cue(cueID), let path = resolvedPath(cue) else { return }
        let sr = sampleRate
        let core = self.core
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let clip = core.clips.cached(path, sampleRate: sr) ?? core.clips.load(path, sampleRate: sr) else { return }
            let threshold: Float = 0.00316
            var first = clip.frames, last = 0
            for c in 0..<clip.channelCount {
                let ch = clip.channel(c)
                if let i = ch.firstIndex(where: { abs($0) > threshold }) { first = min(first, i) }
                if let i = ch.lastIndex(where: { abs($0) > threshold }) { last = max(last, i) }
            }
            guard first < last else { return }
            let start = max(0, Double(first) / sr - 0.01)
            let end = min(clip.duration, Double(last) / sr + 0.05)
            Task { @MainActor in
                self?.edit(self?.loc("show.wave.trim") ?? "") { d in
                    d.updateCue(cueID) { c in
                        c.audio?.start = (start * 1000).rounded() / 1000
                        c.audio?.end = end >= clip.duration - 0.001 ? nil : (end * 1000).rounded() / 1000
                    }
                }
            }
        }
    }

    /// Peaks of a file section (file seconds) in `buckets` columns, from the decoded audio; nil if not loaded.
    func waveSlice(path: String, from: Double, to: Double, buckets: Int) async -> [Float]? {
        let sr = sampleRate
        let core = self.core
        return await Task.detached(priority: .userInitiated) { () -> [Float]? in
            guard let clip = core.clips.cached(path, sampleRate: sr), buckets > 0, to > from else { return nil }
            let a = max(0, Int(from * sr)), b = min(clip.frames, Int(to * sr))
            guard b > a else { return nil }
            let per = Double(b - a) / Double(buckets)
            let stride = max(1, Int(per / 64)) // at most ~64 reads per column
            var out = [Float](repeating: 0, count: buckets)
            for c in 0..<clip.channelCount {
                let p = clip.channel(c)
                do {
                    for k in 0..<buckets {
                        let s = a + Int(Double(k) * per), e = min(b, a + Int(Double(k + 1) * per) + 1)
                        var peak: Float = 0
                        var i = s
                        while i < e { peak = max(peak, abs(p[i])); i += stride }
                        out[k] = max(out[k], min(1, peak))
                    }
                }
            }
            return out
        }.value
    }

    // MARK: One-shot pads

    var currentBank: CueList? { doc.banks.first { $0.id == bankID } ?? doc.banks.first }

    /// Adds audio files as pads of the current bank, each on the next free F-key.
    func addPads(_ urls: [URL]) {
        insertPads(urls.map(Self.filePath))
    }

    private func insertPads(_ urls: [URL]) {
        if doc.banks.isEmpty { edit { $0.lists.append(CueList(name: "\(self.loc("show.bank")) 1", isBank: true)) } }
        guard let bank = currentBank, !urls.isEmpty else { return }
        var used = Set(doc.allCues.compactMap(\.hotkey))
        let pads: [Cue] = urls.map { url in
            var c = Cue.audio(file: storedPath(for: url))
            if let key = ShowDocument.functionKeys.first(where: { !used.contains($0) }) {
                c.hotkey = key
                used.insert(key)
            }
            return c
        }
        edit { $0.insert(pads, after: nil, list: bank.id) }
        selection = Set(pads.map(\.id))
    }

    func choosePads() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.audioTypes
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        addPads(panel.urls)
    }

    func addBank() {
        let b = CueList(name: "\(loc("show.bank")) \(doc.banks.count + 1)", isBank: true)
        edit { $0.lists.append(b) }
        bankID = b.id
    }

    func pad(_ id: UUID, pressed: Bool) { run { e, now in e.pad(id, pressed: pressed, now: now) } }

    /// File length of an audio cue in seconds, when loaded.
    func fileLength(_ cue: Cue) -> Double? {
        resolvedPath(cue).flatMap { clipInfo[$0]?.duration }
    }

    func chooseAudioFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.audioTypes
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        addAudioFiles(panel.urls)
    }

    func chooseFile(for cueID: UUID) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.audioTypes
        guard panel.runModal() == .OK, let picked = panel.url else { return }
        setFile(Self.filePath(picked), for: cueID)
    }

    private func setFile(_ url: URL, for cueID: UUID) {
        let path = storedPath(for: url)
        edit { d in
            d.updateCue(cueID) { c in
                c.audio?.file = path
                if c.name.isEmpty { c.name = url.deletingPathExtension().lastPathComponent }
            }
        }
    }

    func deleteSelection() {
        let ids = selection
        edit(loc("action.delete")) { $0.delete(ids) }
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

    func addList() {
        let l = CueList(name: "\(loc("show.list")) \(doc.lists.count + 1)")
        edit { $0.lists.append(l) }
        selectList(l.id)
    }

    func selectList(_ id: UUID) {
        listID = id
        selection = []
        core.queue.async { [core] in core.engine?.selectList(id) }
    }

    func updateCue(_ id: UUID, _ change: @escaping (inout Cue) -> Void) {
        edit { $0.updateCue(id, change) }
    }

    // MARK: Transport

    func go() {
        // QLab: a red border on GO while double-GO protection holds it.
        if doc.doubleGoGuard > 0, goGuarded == false {
            goGuarded = true
            DispatchQueue.main.asyncAfter(deadline: .now() + doc.doubleGoGuard) { [weak self] in self?.goGuarded = false }
        }
        run { e, now in e.go(now: now) }
    }

    /// Double-GO protection is holding GO right now.
    @Published private(set) var goGuarded = false
    /// Seconds across the width of the timelines (⌘= / ⌘− zoom them, as in QLab).
    @Published var timelineSpan: Double = 40
    func panic() { run { e, now in e.panic(now: now) } }
    func pauseAll() { run { e, now in e.pauseAll(now: now) } }
    func resumeAll() { run { e, now in e.resumeAll(now: now) } }
    func start(_ id: UUID) { run { e, now in e.start(id, now: now) } }
    func stop(_ id: UUID) { run { e, now in e.stop(id, now: now) } }
    func togglePause(_ id: UUID) {
        let paused = snapshot.running.first { $0.id == id }?.paused ?? false
        run { e, now in paused ? e.resume(id, now: now) : e.pause(id, now: now) }
    }
    func setPlayhead(_ id: UUID?) { run { e, _ in e.setPlayhead(id) } }

    /// Double click on a cue: it is selected and the inspector opens on its own settings (waveform, fade, multitrack…).
    /// In Show mode, where nothing is edited, it only stands the cue by.
    func openSettings(_ id: UUID) {
        guard let cue = doc.cue(id) else { return }
        guard !showMode else { setPlayhead(id); return }
        selection = [id]
        inspectorTab = InspectorTab.primary(for: cue)
        showInspector = true
    }
    /// Timeline group: playback carries on from `seconds` (or starts there next time when it is not running).
    func seekGroup(_ id: UUID, to seconds: Double) { run { e, now in e.seek(id, to: seconds, now: now) } }

    var anyPaused: Bool { snapshot.running.contains { $0.paused } }

    private func run(_ action: @escaping (ShowEngine, Int64) -> Void) {
        core.queue.async { [core] in
            guard let e = core.engine else { return }
            action(e, core.now)
        }
    }

    // MARK: Audio output

    /// (Re)creates the output on the show's interface and a new engine at its sample rate.
    func restartOutput() {
        let d = doc
        let core = self.core
        let buffer = bufferFrames
        let transport = osc.transport
        core.queue.async {
            core.timer?.cancel()
            core.output?.stop()
            core.output = nil
            var errorText: String?
            do {
                let out = try ShowAudioOutput(deviceUID: d.deviceUID, maxOutputs: 64, bufferFrames: buffer)
                out.onInterruption = { [weak self] problem in
                    MainActor.assumeIsolated {
                        self?.outputError = problem
                        if problem == nil { self?.interruptions += 1 }
                    }
                }
                core.output = out
            } catch {
                errorText = "\(error)"
            }
            let sr = core.output?.sampleRate ?? 48000
            core.clockRate = sr
            let mixer = core.output?.mixer
            mixer?.send(.patch(d.outputs.map { $0.deviceChannel ?? -1 }))
            let clips = core.clips
            let ioBuffer = Double(core.output?.bufferFrames ?? buffer)
            let engine = ShowEngine(document: d, sampleRate: sr, lookahead: Int64(max(sr * 0.03, ioBuffer * 3)),
                                    send: { op in mixer?.send(op) },
                                    clipProvider: { cue in
                                        guard let path = cue.audio.map({ ShowStore.resolve($0.file, showURL: core.showURL) }) else { return nil }
                                        // Never decode on the playback queue: a file not ready yet is reported, and loaded meanwhile.
                                        if let c = clips.cached(path, sampleRate: sr) { return c }
                                        DispatchQueue.global(qos: .userInitiated).async { clips.load(path, sampleRate: sr) }
                                        return nil
                                    })
            engine.clipPending = { cue in
                guard let f = cue.audio?.file, !f.isEmpty else { return false }
                let path = ShowStore.resolve(f, showURL: core.showURL)
                return FileManager.default.fileExists(atPath: path) && clips.failure(path) == nil
            }
            engine.oscSend = { device, message in transport.send(message, to: device) }
            engine.preload = { cue in
                guard let f = cue.audio?.file else { return }
                let path = ShowStore.resolve(f, showURL: core.showURL)
                DispatchQueue.global(qos: .userInitiated).async { clips.load(path, sampleRate: sr)?.prefetch(from: 0, count: Int(sr * 10)) }
            }
            engine.documentChanged = { [weak self] newDoc in
                Task { @MainActor in self?.doc = newDoc }
            }
            core.engine = engine
            let name = core.output?.deviceName ?? ""
            let timer = DispatchSource.makeTimerSource(queue: core.queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in
                guard let e = core.engine else { return }
                e.advance(to: core.now)
                core.output?.mixer.collectGarbage()
                core.ticks += 1
                if core.ticks % 20 == 0 { e.prefetch(now: core.now) }
                if core.ticks % 8 == 0 {
                    let snap = e.snapshot(now: core.now)
                    let peaks = core.output?.mixer.takePeaks() ?? []
                    Task { @MainActor in self?.apply(snap, peaks: peaks) }
                }
            }
            timer.resume()
            core.timer = timer
            Task { @MainActor [weak self] in
                self?.outputName = name
                self?.outputError = errorText
                self?.sampleRate = sr
                self?.refreshFiles(load: true)
            }
        }
    }

    private func apply(_ snap: ShowSnapshot, peaks: [Float]) {
        if snap != snapshot { snapshotDate = Date(); snapshot = snap }
        let used = Array(peaks.prefix(doc.outputs.count))
        // Ballistics as on a console: rises at once, falls about 25 dB/s; clipping (≥ 0 dBFS, the output really
        // overloads) stays lit 1.5 s.
        var shown = meters
        if shown.count != used.count { shown = used }
        for i in used.indices {
            let fall = shown[i] * Float(pow(10, -1.0 / 20))   // −1 dB per update (25 a second)
            shown[i] = max(used[i], fall < 1e-5 ? 0 : fall)
            if used[i] >= 1 { clipUntil[i] = Date().addingTimeInterval(1.5) }
        }
        if shown != meters { meters = shown }
        let clips = used.indices.map { (clipUntil[$0] ?? .distantPast) > Date() }
        if clips != clipping { clipping = clips }
        if let lid = snap.listID, lid != listID, doc.lists.contains(where: { $0.id == lid }) { listID = lid }
    }

    // MARK: Files

    /// Absolute path of a cue's file (relative paths are resolved against the show file's folder).
    nonisolated static func resolve(_ path: String, showURL: URL?) -> String {
        if path.hasPrefix("/") { return path }
        if let base = showURL?.deletingLastPathComponent() { return base.appendingPathComponent(path).path }
        return path
    }

    func resolvedPath(_ cue: Cue) -> String? {
        guard let f = cue.audio?.file, !f.isEmpty else { return nil }
        return Self.resolve(f, showURL: fileURL)
    }

    // MARK: Show media (QLab-style copies)

    /// Where the show's audio is gathered on save (as QLab does): "<show> Audio" next to the show file.
    var mediaFolder: URL? {
        fileURL.map { $0.deletingLastPathComponent().appendingPathComponent($0.deletingPathExtension().lastPathComponent + " Audio", isDirectory: true) }
    }

    /// On save: every audio file outside the show's media folder is copied into it and stored relative to the
    /// show, so the show folder carries everything it plays. `oldShowURL` resolves the current relative paths.
    private func collectMedia(oldShowURL: URL?) {
        guard let folder = mediaFolder else { return }
        var paths: [UUID: String] = [:]
        var failed: [String] = []
        for c in doc.allCues {
            guard let f = c.audio?.file, !f.isEmpty else { continue }
            let src = URL(fileURLWithPath: Self.resolve(f, showURL: oldShowURL))
            let copied: URL?
            if FileManager.default.fileExists(atPath: src.path) {
                let r = ShowMedia.copy([src], into: folder)
                copied = r.copied.first
                failed += r.errors
            } else {
                copied = nil
            }
            // Copied: relative to the show. Not copied (missing, no access): the full old path, so a relative path
            // does not end up pointing into the new show's folder.
            paths[c.id] = copied.map { storedPath(for: $0) } ?? src.path
        }
        if paths.contains(where: { doc.cue($0.key)?.audio?.file != $0.value }) {
            edit { d in for (id, p) in paths { d.updateCue(id) { $0.audio?.file = p } } }
        }
        if !failed.isEmpty { lastError = loc("show.import.failed") + " " + failed.joined(separator: "; ") }
    }

    /// Paths are stored absolute; files next to the show file are stored relative to it.
    private func storedPath(for url: URL) -> String {
        if let base = fileURL?.deletingLastPathComponent().path, url.path.hasPrefix(base + "/") {
            return String(url.path.dropFirst(base.count + 1))
        }
        return url.path
    }

    /// Checks files and (optionally) decodes them in the background so GO never waits for disk.
    private func refreshFiles(load: Bool = true) {
        let paths = Set(doc.allCues.compactMap { resolvedPath($0) })
        missingFiles = Set(paths.filter { !FileManager.default.fileExists(atPath: $0) })
        unreadableFiles = unreadableFiles.filter { paths.contains($0.key) }
        guard load else { return }
        let sr = sampleRate
        let core = self.core
        let todo = paths.subtracting(missingFiles).filter { clipInfo[$0] == nil || core.clips.cached($0, sampleRate: sr) == nil }
        guard !todo.isEmpty else { return }
        // Where each file starts playing: read those seconds in advance so GO is instant.
        var starts: [String: [Double]] = [:]
        for c in doc.allCues where c.kind == .audio {
            if let p = resolvedPath(c), let a = c.audio { starts[p, default: []].append(a.start) }
        }
        loadingFiles += todo.count
        for p in todo {
            let preroll = starts[p] ?? [0]
            Self.loader.addOperation { [weak self] in
                let clip = core.clips.load(p, sampleRate: sr)
                for s in preroll { clip?.prefetch(from: Int(s * sr), count: Int(sr * 10)) }
                let wave = clip.map { Self.overview($0) }
                let failure = clip == nil ? core.clips.failure(p) : nil
                let bytes = core.clips.totalBytes
                Task { @MainActor in
                    guard let self else { return }
                    self.loadingFiles = max(0, self.loadingFiles - 1)
                    if let clip {
                        self.clipInfo[p] = (duration: clip.duration, channels: clip.channelCount)
                        self.waveforms[p] = wave
                        self.unreadableFiles[p] = nil
                    } else if let failure {
                        self.unreadableFiles[p] = failure
                    }
                    self.memoryBytes = bytes
                }
            }
        }
        DispatchQueue.global(qos: .utility).async { core.clips.forget(except: paths) }
    }

    /// Peak overview of a clip (all channels), `buckets` values in 0…1.
    nonisolated static func overview(_ clip: AudioClip, buckets: Int = 1200) -> [Float] {
        let n = clip.frames
        guard n > 0 else { return [] }
        let size = max(1, n / buckets)
        var out = [Float](repeating: 0, count: min(buckets, n))
        for c in 0..<clip.channelCount {
            let p = clip.channel(c)
            do {
                for b in 0..<out.count {
                    var peak: Float = 0
                    let start = b * size, end = min(n, start + size)
                    var i = start
                    while i < end { peak = max(peak, abs(p[i])); i += 4 } // every 4th sample is plenty for display
                    out[b] = max(out[b], min(1, peak))
                }
            }
        }
        return out
    }

    /// Looks for missing files by name inside a folder (recursively) and relinks them.
    func relinkMissing() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        var found: [String: URL] = [:]
        if let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) {
            for case let url as URL in e { found[url.lastPathComponent.lowercased()] = url }
        }
        var relinked = 0
        let missing = missingFiles
        edit(loc("show.relink")) { d in
            for c in d.allCues {
                guard let f = c.audio?.file, missing.contains(Self.resolve(f, showURL: self.fileURL)),
                      let url = found[(f as NSString).lastPathComponent.lowercased()] else { continue }
                let path = self.storedPath(for: url)
                d.updateCue(c.id) { $0.audio?.file = path }
                relinked += 1
            }
        }
        lastError = String(format: loc("show.relink.done"), relinked)
    }

    /// Pre-show check: problems as readable lines.
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
        fileURL = nil
        selection = []
        listID = doc.cueLists.first?.id
    }

    func open() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.fileType, .json] + (Self.qlabImportEnabled ? Self.qlabTypes : [])
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if url.pathExtension.lowercased().hasPrefix("qlab") {
            pendingQLabFile = url
            showQLabImport = true
            return
        }
        do {
            let d = try ShowDocument.decode(Data(contentsOf: url))
            run { e, now in e.panic(now: now, hard: true) }
            fileURL = url
            edit { $0 = d }
            listID = d.cueLists.first?.id
            selection = []
            restartOutput()
        } catch {
            lastError = "\(url.lastPathComponent): \(error)"
        }
    }

    func save(as: Bool = false) {
        var url = fileURL
        if url == nil || `as` {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [Self.fileType]
            panel.nameFieldStringValue = (doc.name.isEmpty ? "Show" : doc.name) + ".ssmtshow"
            guard panel.runModal() == .OK, let u = panel.url else { return }
            url = u
        }
        guard let url else { return }
        let oldURL = fileURL
        fileURL = url
        collectMedia(oldShowURL: oldURL)
        do {
            try doc.encoded().write(to: url, options: .atomic)
        } catch {
            fileURL = oldURL
            lastError = "\(url.lastPathComponent): \(error)"
        }
    }

    private func scheduleAutosave() {
        autosaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let data = try? self.doc.encoded() else { return }
            try? data.write(to: Self.autosaveURL, options: .atomic)
        }
        autosaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    // MARK: Keyboard

    /// Space = GO, Esc = panic (twice = cut), cue hotkeys; ignored while typing in a text field.
    func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.handleKey(event) ? nil : event }
        }
        // A click anywhere but a text input ends typing (notes, names), so Space is GO again.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self else { return event }
            MainActor.assumeIsolated { self.leaveTextFieldIfClickedOutside(event) }
            return event
        }
    }

    private static func isTyping(in window: NSWindow?) -> Bool {
        guard let r = window?.firstResponder else { return false }
        return r is NSText || r is NSTextView
    }

    private func leaveTextFieldIfClickedOutside(_ event: NSEvent) {
        guard isActive, let w = event.window, Self.isTyping(in: w), let content = w.contentView else { return }
        var v = content.hitTest(content.convert(event.locationInWindow, from: nil))
        while let view = v {
            if view is NSTextField || view is NSTextView || view is NSText { return }
            v = view.superview
        }
        w.makeFirstResponder(nil)
    }

    private static let functionKeyCodes: [UInt16: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    private func handleKey(_ event: NSEvent) -> Bool {
        guard isActive else { return false }
        // Keys typed into a sheet, an open/save panel or an alert belong to it, not to the show.
        if NSApp.modalWindow != nil { return false }
        if let w = NSApp.keyWindow, w.sheetParent != nil || w.attachedSheet != nil || w is NSPanel { return false }
        if Self.isTyping(in: NSApp.keyWindow) {
            // Esc ends typing in a field (the next Esc is Stop all as usual).
            if event.type == .keyDown && event.keyCode == 53 { NSApp.keyWindow?.makeFirstResponder(nil); return true }
            return false
        }
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        if mods == [.command], event.type == .keyDown { return commandKey(event) }
        // ⌥← / ⌥→ (QLab): pre-wait of the selected cues −/+ 0.1 s, which moves them on a group timeline.
        if mods == [.option], event.type == .keyDown, !showMode, event.keyCode == 123 || event.keyCode == 124 {
            nudgePreWait(event.keyCode == 124 ? 0.1 : -0.1)
            return true
        }
        guard mods.isEmpty else { return false }
        // One-shot pads on F-keys: press and release (for "hold" pads).
        if let fkey = Self.functionKeyCodes[event.keyCode] {
            guard let cue = doc.allCues.first(where: { $0.hotkey == fkey }) else { return false }
            if event.isARepeat { return true }
            pad(cue.id, pressed: event.type == .keyDown)
            return true
        }
        guard event.type == .keyDown else { return false }
        switch event.keyCode {
        case 49: if !event.isARepeat { go() }; return true   // space (held down = one GO)
        case 53: panic(); return true         // esc
        default: break
        }
        guard let ch = event.charactersIgnoringModifiers?.lowercased(), !ch.isEmpty else { return false }
        // Hotkeys the user gave to cues come first.
        if let cue = doc.allCues.first(where: { ($0.hotkey ?? "").lowercased() == ch }) {
            if doc.banks.contains(where: { $0.cues.findCue(cue.id) != nil }) { pad(cue.id, pressed: true) } else { start(cue.id) }
            return true
        }
        return plainKey(event)
    }

    // MARK: QLab keyboard shortcuts (by physical key, so they work on any layout, Russian included)

    private enum Key {
        static let a: UInt16 = 0, s: UInt16 = 1, d: UInt16 = 2, c: UInt16 = 8, v: UInt16 = 9, q: UInt16 = 12, w: UInt16 = 13
        static let e: UInt16 = 14, r: UInt16 = 15, t: UInt16 = 17, one: UInt16 = 18, seven: UInt16 = 26, eight: UInt16 = 28
        static let zero: UInt16 = 29, rightBracket: UInt16 = 30, leftBracket: UInt16 = 33, i: UInt16 = 34, p: UInt16 = 35
        static let l: UInt16 = 37, j: UInt16 = 38, n: UInt16 = 45, x: UInt16 = 7, delete: UInt16 = 51, forwardDelete: UInt16 = 117
        static let up: UInt16 = 126, down: UInt16 = 125
    }

    /// Keys without modifiers (Space, Esc and F-keys are handled before).
    private func plainKey(_ event: NSEvent) -> Bool {
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case Key.leftBracket: pauseAll(); return true                       // [  Pause all
        case Key.rightBracket: resumeAll(); return true                     // ]  Resume all
        case Key.p: selectedCues.forEach(togglePause); return true          // P  pause / resume selected
        case Key.s: stopSelected(); return true                             // S  stop selected (S S: at once)
        case Key.l: selectedCues.forEach(load); return true                 // L  load selected
        case Key.v: selectedCues.forEach(start); return true                // V  preview selected
        case Key.up where !shift: moveCursor(by: -1); return true           // ↑ / ↓  previous / next cue
        case Key.down where !shift: moveCursor(by: 1); return true
        default: break
        }
        guard !showMode else { return false }
        switch event.keyCode {
        case Key.delete, Key.forwardDelete:                                 // ⌫  delete selected
            guard !selection.isEmpty else { return false }
            deleteSelection(); return true
        case Key.n: editSelected(.number); return true                      // N  number
        case Key.q: editSelected(.name); return true                        // Q  name
        case Key.e: editSelected(.preWait); return true                     // E  pre-wait
        case Key.d: editSelected(.duration); return true                    // D  duration
        case Key.w: editSelected(.postWait); return true                    // W  post-wait
        case Key.c: cycleContinueMode(); return true                        // C  continue mode
        case Key.t: inspectorTab = selection.first.flatMap { doc.cue($0) }?.kind == .fade ? .fade : .action; showInspector = true; return true // T  target
        default: return false
        }
    }

    /// ⌘ shortcuts of the cue list. ⌘S / ⌘O / ⌘Z stay with the app menu.
    private func commandKey(_ event: NSEvent) -> Bool {
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case Key.rightBracket: showMode = true; return true                 // ⌘]  Show mode
        case Key.leftBracket: showMode = false; return true                 // ⌘[  Edit mode
        case Key.i: showInspector.toggle(); return true                     // ⌘I  inspector
        case Key.l: showSidebar.toggle(); return true                       // ⌘L  lists, one-shot, active
        case Key.j: jumpToCue(); return true                                // ⌘J  jump to cue
        case Key.t: loadSelectedToTime(); return true                       // ⌘T  load to time
        case 24: timelineSpan = max(5, timelineSpan / 1.5); return true     // ⌘=  zoom the timeline in
        case 27: timelineSpan = min(600, timelineSpan * 1.5); return true   // ⌘−  zoom out
        case Key.up where shift: movePlayhead(by: -1); return true          // ⇧⌘↑ / ⇧⌘↓  playhead
        case Key.down where shift: movePlayhead(by: 1); return true
        default: break
        }
        guard !showMode else { return false }
        switch event.keyCode {
        case Key.zero: add(.group); return true                             // ⌘0  group (wraps the selection)
        case Key.one: chooseAudioFiles(); return true                       // ⌘1  audio
        case Key.seven: addFade(fadeIn: false); return true                 // ⌘7  fade (out)
        case Key.eight: add(.network); return true                          // ⌘8  network (OSC)
        case Key.r: renumberSelection(); return true                        // ⌘R  renumber
        case Key.d: duplicateSelection(); return true                       // ⌘D  duplicate
        case Key.a: selection = Set(currentList?.cues.flattened().map(\.cue.id) ?? []); return true // ⌘A
        case Key.c: copySelection(); return true                            // ⌘C / ⌘X / ⌘V  cues
        case Key.x: copySelection(); deleteSelection(); return true
        case Key.v: pasteCues(); return true
        default: return false
        }
    }

    private var selectedCues: [UUID] { orderedSelection.isEmpty ? Array(selection) : orderedSelection }

    private func nudgePreWait(_ delta: Double) {
        let ids = selectedCues
        guard !ids.isEmpty else { return }
        edit(loc("show.preWait")) { d in
            for id in ids { d.updateCue(id) { $0.preWait = max(0, (($0.preWait + delta) * 100).rounded() / 100) } }
        }
    }

    func load(_ id: UUID) { run { e, _ in e.load(id) } }

    private var lastStop: Date?

    /// S: stops the selected cues with the panic fade; S again within a second stops them at once.
    private func stopSelected() {
        let hard = lastStop.map { Date().timeIntervalSince($0) < 1 } ?? false
        lastStop = hard ? nil : Date()
        let fade = hard ? 0 : doc.panicFade
        for id in selectedCues { run { e, now in e.stop(id, now: now, fade: fade) } }
    }

    /// ↑ / ↓: the previous / next row is selected and gets the playhead where it can stand (as a click does).
    private func moveCursor(by delta: Int) {
        let rows = currentList?.cues.flattened(collapsed: collapsed) ?? []
        guard !rows.isEmpty else { return }
        let current = rows.lastIndex { selection.contains($0.cue.id) } ?? (delta > 0 ? -1 : rows.count)
        let i = max(0, min(rows.count - 1, current + delta))
        selection = [rows[i].cue.id]
        setPlayhead(rows[i].cue.id)
    }

    /// ⇧⌘↑ / ⇧⌘↓: the playhead to the previous / next top-level cue.
    private func movePlayhead(by delta: Int) {
        guard let cues = currentList?.cues, !cues.isEmpty else { return }
        let ph = snapshot.playhead
        let i = ph.flatMap { id in cues.firstIndex { $0.id == id } } ?? (delta > 0 ? -1 : cues.count)
        let j = i + delta
        setPlayhead(cues.indices.contains(j) ? cues[j].id : nil)
    }

    /// ⌘J: asks for a cue number, selects it and puts the playhead on it.
    private func jumpToCue() {
        guard let n = prompt(loc("show.key.jump"), value: "") else { return }
        guard let cue = doc.allCues.first(where: { $0.number == n.trimmingCharacters(in: .whitespaces) }) else { NSSound.beep(); return }
        if let l = doc.cueLists.first(where: { $0.cues.findCue(cue.id) != nil }), l.id != listID { selectList(l.id) }
        selection = [cue.id]
        setPlayhead(cue.id)
    }

    /// ⌘T: the selected audio cue's next start begins this many seconds in.
    private func loadSelectedToTime() {
        guard selection.count == 1, let id = selection.first, let c = doc.cue(id),
              c.kind == .audio || (c.kind == .group && c.groupMode == .simultaneous) else { NSSound.beep(); return }
        guard let v = prompt(loc("show.key.loadToTime"), value: "0"),
              let s = Double(v.replacingOccurrences(of: ",", with: ".")) else { return }
        run { e, _ in e.loadToTime(id, seconds: s) }
    }

    private enum Field { case number, name, preWait, duration, postWait }

    /// N, Q, E, D, W: edit the number, name, pre-wait, duration or post-wait of the selected cue.
    private func editSelected(_ f: Field) {
        guard selection.count == 1, let id = selection.first, let cue = doc.cue(id) else { return }
        let title: String, value: String
        switch f {
        case .number: title = loc("show.key.number"); value = cue.number
        case .name: title = loc("show.key.name"); value = cue.name
        case .preWait: title = loc("show.key.preWait"); value = String(cue.preWait)
        case .duration:
            guard cue.kind == .wait || cue.kind == .fade else { inspectorTab = cue.kind == .audio ? .wave : .main; showInspector = true; return }
            title = loc("show.key.duration"); value = String(cue.kind == .fade ? cue.fade?.duration ?? 0 : cue.duration)
        case .postWait: title = loc("show.key.postWait"); value = String(cue.postWait)
        }
        guard let v = prompt(title, value: value) else { return }
        let seconds = Double(v.replacingOccurrences(of: ",", with: "."))
        edit { d in
            d.updateCue(id) { c in
                switch f {
                case .number: c.number = v
                case .name: c.name = v
                case .preWait: if let s = seconds { c.preWait = max(0, s) }
                case .duration: if let s = seconds { if c.kind == .fade { c.fade?.duration = max(0, s) } else { c.duration = max(0, s) } }
                case .postWait: if let s = seconds { c.postWait = max(0, s) }
                }
            }
        }
    }

    /// C: no continue → auto-continue → auto-follow → no continue.
    private func cycleContinueMode() {
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

    private var cueClipboard: [Cue] = []

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

    private func prompt(_ title: String, value: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = value
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: loc("action.cancel"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    private func loc(_ key: String) -> String { localizer?.t(key) ?? key }
}
