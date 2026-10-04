import AppKit
import SSMTCore
import SwiftUI
import XCTest
@testable import SSMT

/// Screenshot tests of the key screens and the mini window (spec 10, "UI-проверка").
/// Rendered in a real (borderless, dark) NSWindow so AppKit-backed controls draw correctly.
/// Every run writes PNGs to build/snapshots (uploaded by CI). If a reference exists in
/// App/Tests/Snapshots/References it is compared with a tolerance; otherwise the image is recorded.
@MainActor
final class SnapshotTests: XCTestCase {
    static let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let references = repoRoot.appendingPathComponent("App/Tests/Snapshots/References")
    static let output = repoRoot.appendingPathComponent("build/snapshots")

    static var model: AppModel!
    static var ru: Localizer!
    static var en: Localizer!

    override func setUp() async throws {
        if Self.model == nil {
            let m = AppModel()
            m.wizard = try SimulatedSession.completeWizard()
            Self.model = m
            let ru = Localizer(); ru.language = .ru
            let en = Localizer(); en.language = .en
            Self.ru = ru
            Self.en = en
        }
    }

    // MARK: Instruments

    func testInstruments() throws {
        let view = HStack(spacing: 16) {
            TunerGauge(title: "Задержка сабвуфера", value: 0.45, tolerance: 10.0 / 90, readout: "+1.25",
                       instruction: "Добавьте задержку сабвуферу",
                       scaleLabels: ["−2.8", "−1.4", "0", "+1.4", "+2.8"], unit: "мс")
            TunerGauge(title: "Задержка сабвуфера", value: 0.03, tolerance: 10.0 / 90, readout: "+0.08",
                       instruction: "В строю",
                       scaleLabels: ["−2.8", "−1.4", "0", "+1.4", "+2.8"], unit: "мс")
            TunerGauge(title: "Качество сигнала", value: 0.62, mode: .oneSided, tolerance: 0.91, readout: "64",
                       instruction: "Слабо — тише или громче", scaleLabels: ["30", "44", "58", "71", "85"], unit: "%")
        }
        .padding(16).background(Backdrop())
        try snapshot(view, size: CGSize(width: 1380, height: 340), name: "instruments", loc: Self.ru)
    }

    func testMiniMetersAndPolarity() throws {
        let view = VStack(alignment: .leading, spacing: 10) {
            PolarityLamp(wrong: true)
            PolarityLamp(wrong: false)
            MiniMeter(value: -0.7, tolerance: 0.5 / 6, readout: "−4.2 dB")
            MiniMeter(value: -0.05, tolerance: 0.5 / 6, readout: "−0.3 dB")
            MiniMeter(value: 0.15, tolerance: 0.5 / 6, readout: "+0.9 dB")
        }
        .padding(16).background(Backdrop())
        try snapshot(view, size: CGSize(width: 560, height: 330), name: "mini-meters", loc: Self.ru)
    }

    // MARK: Screens

    func testSplash() throws {
        try snapshot(SplashView(namespace: nil, slow: false, progress: 0.6), size: CGSize(width: 960, height: 600),
                     name: "splash", loc: Self.ru)
    }

    func testMainWindowWizard() throws {
        Self.model.appMode = .wizard
        try snapshot(MainView(), size: CGSize(width: 1400, height: 900), name: "main-wizard", loc: Self.ru)
    }

    func testMainWindowEnglish() throws {
        Self.model.appMode = .wizard
        try snapshot(MainView(), size: CGSize(width: 1400, height: 900), name: "main-wizard-en", loc: Self.en)
    }

    func testMainWindowExpert() throws {
        Self.model.appMode = .expert
        defer { Self.model.appMode = .wizard }
        try snapshot(MainView(), size: CGSize(width: 1400, height: 900), name: "main-expert", loc: Self.ru)
    }

    func testPreparation() throws {
        try snapshot(PreparationStepView().padding(16).background(Backdrop()), size: CGSize(width: 1120, height: 1000), name: "step0-preparation", loc: Self.ru)
    }

    func testTunerScreen() throws {
        try snapshot(ResultsStepView().padding(16).background(Backdrop()), size: CGSize(width: 1000, height: 1300), name: "step4-tuner", loc: Self.ru)
    }

    func testAlignmentCheck() throws {
        try snapshot(AlignmentCheckView().padding(16).background(Backdrop()), size: CGSize(width: 1000, height: 1000), name: "step5-verify", loc: Self.ru)
    }

    func testEQTuning() throws {
        try snapshot(EQTuningView().padding(16).background(Backdrop()), size: CGSize(width: 1100, height: 1300), name: "step7-eq", loc: Self.ru)
    }

    func testFinished() throws {
        try snapshot(FinishedStepView().padding(16).background(Backdrop()), size: CGSize(width: 1000, height: 1250), name: "finished", loc: Self.ru)
    }

    func testMiniWindow() throws {
        try snapshot(MiniDiagnosticsView(), size: CGSize(width: 380, height: 330), name: "mini-window", loc: Self.ru)
    }

    func testReport() throws {
        let report = Self.model.setupReport
        try snapshot(ReportView(report: report, wizard: Self.model.wizard), size: nil, name: "report", loc: Self.ru)
    }

    // MARK: Input list (function #2)

    static var sampleInputList: InputListDocument {
        var d = InputListDocument()
        d.artist = "The Sample Band"
        d.event = "Club show"
        d.venue = "Main hall"
        d.date = Date(timeIntervalSince1970: 1_800_000_000)
        d.engineer = "FOH: A. Engineer"
        d.contact = "+7 900 000-00-00"
        d.notes = "Drum riser 2.4 × 2 m, 4 power drops on stage."
        for t in ["drums", "bass", "guitar", "keys", "leadVocal", "backingVocals", "playback"] {
            d.insert(ChannelTemplate.template(id: t)!)
        }
        d.assignStagebox(prefix: "SB1-")
        for (name, type) in [("Lead vocal", MixType.iem), ("Guitar", .wedge), ("Bass", .wedge), ("Drums", .drumfill), ("Keys", .iem)] {
            d.addMix(type: type)
            d.mixes[d.mixes.count - 1].name = name
            d.mixes[d.mixes.count - 1].stereo = type == .iem
        }
        var p = StagePlan()
        p.width = 10; p.depth = 6
        p.add(.riser, at: (5, 4.6), label: "Riser")
        p.add(.drumKit, at: (5, 4.6), label: "Drums")
        p.add(.bassAmp, at: (2.2, 4.8), label: "Bass")
        p.add(.guitarAmp, at: (7.8, 4.8), label: "Guitar")
        p.add(.keyboard, at: (8.4, 2.6), label: "Keys")
        p.add(.person, at: (5, 1.6), label: "Lead vocal")
        p.add(.vocalMic, at: (5, 1.0))
        for x in [3.0, 5.0, 7.0] { p.add(.wedge, at: (x, 0.4)) }
        p.add(.diBox, at: (8.4, 3.2))
        p.add(.powerDrop, at: (1.0, 5.6))
        p.add(.text, at: (5, 3.0), label: "4 × power 230 V")
        d.stage = p
        return d
    }

    func testInputListWorkspace() throws {
        Self.model.inputList.doc = Self.sampleInputList
        try snapshot(InputListWorkspace().padding(16).background(Backdrop()), size: CGSize(width: 1300, height: 2100),
                     name: "input-list", loc: Self.ru)
    }

    static var sampleShow: (doc: ShowDocument, intro: UUID, group: UUID, preshow: UUID, bell: UUID) {
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

    private func prepareShow() {
        let s = Self.sampleShow // computed: fresh ids on every access, so read it once
        let show = Self.model.show
        show.doc = s.doc
        show.selection = [s.intro]
        let playhead = s.group
        var waves: [String: [Float]] = [:]
        var clips: [String: (duration: Double, channels: Int)] = [:]
        for (i, (name, d)) in [("Preshow loop", 95.0), ("Intro", 41.5), ("Rain", 180), ("Thunder", 6.2), ("Phone", 4), ("Door", 2),
                                  ("Applause", 12), ("Wind", 30), ("Steps", 3), ("Clock", 5)].enumerated() {
            let path = "/show/\(name).wav"
            clips[path] = (d, 2)
            waves[path] = (0..<600).map { k in Float(0.25 + 0.5 * abs(sin(Double(k) * 0.05 + Double(i)) * cos(Double(k) * 0.013))) }
        }
        show.preview(snapshot: ShowSnapshot(listID: s.doc.lists[0].id, playhead: playhead, running: [
            RunningCue(id: s.preshow, phase: .stopping, elapsed: 1.2, duration: 3, paused: false, iteration: 4),
            RunningCue(id: s.intro, phase: .running, elapsed: 12.4, duration: 41.5, paused: false, iteration: nil),
            RunningCue(id: s.bell, phase: .running, elapsed: 1.5, duration: 4, paused: false, iteration: nil),
        ], problems: [:]), clips: clips, meters: [0.5, 0.45, 0.1, 0.1, 0, 0, 0, 0], waveforms: waves)
    }

    func testShowPlayer() throws {
        let show = Self.model.show
        prepareShow()
        show.showSidebar = true
        show.showInspector = true
        show.showTimeline = false
        show.sidebarTab = .pads
        show.showMode = false
        try snapshot(ShowWorkspace().padding(16).background(Backdrop()), size: CGSize(width: 1500, height: 900),
                     name: "show-edit", loc: Self.ru)
        show.showTimeline = true
        show.sidebarTab = .active
        show.showMode = true
        try snapshot(ShowWorkspace().padding(16).background(Backdrop()), size: CGSize(width: 1500, height: 900),
                     name: "show-show", loc: Self.ru)
        show.showMode = false
        show.showTimeline = false
        // A group's own multitrack in its inspector.
        show.selection = [show.doc.lists[0].cues[3].id]
        show.inspectorTab = .multitrack
        try snapshot(ShowWorkspace().padding(16).background(Backdrop()), size: CGSize(width: 1500, height: 900),
                     name: "show-group-multitrack", loc: Self.ru)
        show.inspectorTab = .main
    }

    func testWaveformEditor() throws {
        prepareShow()
        let show = Self.model.show
        var doc = show.doc
        doc.updateCue(show.selection.first!) { c in
            c.audio?.start = 1.2
            c.audio?.end = 38
            c.audio?.fadeIn = 2
            c.audio?.fadeOut = 4
            c.audio?.loopStart = 10
            c.audio?.loopEnd = 22
            c.audio?.plays = 0
        }
        show.doc = doc
        let cue = show.doc.cue(show.selection.first!)!
        try snapshot(WaveformEditor(cue: cue, compact: false).padding(20).frame(width: 1000).background(Backdrop()),
                     size: CGSize(width: 1000, height: 520), name: "show-waveform", loc: Self.ru)
    }

    func testOSCSetup() throws {
        prepareShow()
        let show = Self.model.show
        show.doc.devices = [OSCDevice(name: "Resolume", kind: .resolume, host: "127.0.0.1"),
                            OSCDevice(name: "Eos Ion", kind: .eos, host: "10.101.0.2")]
        try snapshot(OSCDevicesView(), size: CGSize(width: 640, height: 600), name: "osc-devices", loc: Self.ru)
        try snapshot(OSCDevicesView(startWith: .eos), size: CGSize(width: 640, height: 600), name: "osc-setup-eos", loc: Self.ru)
    }

    func testQLabImport() throws {
        prepareShow()
        try snapshot(QLabImportView(), size: CGSize(width: 600, height: 560), name: "qlab-import", loc: Self.ru)
    }

    /// The hidden game's launcher (the game itself is a Mega Drive ROM, screenshots come from an emulator).
    func testHiddenGameLauncher() throws {
        try snapshot(GameLauncherView(), size: CGSize(width: 1030, height: 540), name: "game-launcher", loc: Self.ru)
    }

    func testAssistWorkspace() throws {
        let store = Self.model.assist
        // Before a console is connected: only the console choice and the consoles found on the network.
        store.disconnect()
        store.autoScan = false
        store.family = .x32
        store.showDiscovered([
            DiscoveredConsole(family: .x32, ip: "192.168.1.64", name: "X32-02-4A-53", model: "X32", firmware: "4.06"),
            DiscoveredConsole(family: .x32, ip: "192.168.1.71", name: "M32R-11-0C-2B", model: "M32R", firmware: "4.06"),
        ])
        try snapshot(AssistWorkspace(), size: CGSize(width: 1500, height: 940), name: "assist-connect", loc: Self.ru)
        store.family = .simulator
        store.character = .musical
        store.connect()
        store.tune(.choir)
        store.runNow(steps: 14)
        store.selectedChannel = store.strips.first { store.state(of: $0.id) == .done }?.id
        try snapshot(AssistWorkspace(), size: CGSize(width: 1500, height: 940), name: "assist", loc: Self.ru)
        // Show mode: the guard backs up the engineer.
        store.mode = .show
        store.startGuard()
        store.runGuardNow(steps: 6)
        try snapshot(AssistWorkspace(), size: CGSize(width: 1500, height: 940), name: "assist-show", loc: Self.ru)
        store.stopGuard()
        store.mode = .soundcheck
        store.selectedChannel = nil
        store.disconnect()
    }

    func testInputListPrintSheets() throws {
        let doc = Self.sampleInputList
        try snapshot(ChannelSheet(doc: doc, rows: doc.channelPages(rowsPerPage: InputListPrint.rowsPerPage)[0], page: "1 / 3"),
                     size: InputListPrint.page, name: "input-list-print", loc: Self.ru)
        try snapshot(StageSheet(doc: doc, page: "3 / 3"), size: InputListPrint.page, name: "stage-plan-print", loc: Self.ru)
    }

    // MARK: Rendering and comparison

    private func snapshot<V: View>(_ view: V, size: CGSize?, name: String, loc: Localizer,
                                   file: StaticString = #filePath, line: UInt = #line) throws {
        let framed = Group {
            if let size { view.frame(width: size.width, height: size.height, alignment: .top) } else { view }
        }
        let root = framed
            .ssmtEnvironment(Self.model, loc)
            .environment(\.colorScheme, .dark)
            .background(Theme.background)
        let host = NSHostingView(rootView: root)
        let target = size ?? host.fittingSize
        // Fixed snapshot size: do not let the hosting view resize the window to its content.
        host.sizingOptions = []
        host.frame = CGRect(origin: .zero, size: target)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.contentView = host
        window.orderFrontRegardless()
        // Let SwiftUI lay out, draw and finish spring animations.
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            return XCTFail("Could not render \(name)", file: file, line: line)
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        window.orderOut(nil)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            return XCTFail("PNG encoding failed for \(name)", file: file, line: line)
        }
        try FileManager.default.createDirectory(at: Self.output, withIntermediateDirectories: true)
        try png.write(to: Self.output.appendingPathComponent("\(name).png"))
        XCTAssertGreaterThan(nonBlackFraction(rep), 0.01, "\(name) rendered (almost) empty", file: file, line: line)

        let refURL = Self.references.appendingPathComponent("\(name).png")
        guard let refData = try? Data(contentsOf: refURL), let ref = NSBitmapImageRep(data: refData) else {
            // No reference yet: recorded to build/snapshots (CI artifact) for review and committing.
            return
        }
        guard ref.pixelsWide == rep.pixelsWide, ref.pixelsHigh == rep.pixelsHigh else {
            return XCTFail("\(name): size changed \(ref.pixelsWide)x\(ref.pixelsHigh) → \(rep.pixelsWide)x\(rep.pixelsHigh)", file: file, line: line)
        }
        let diff = differingFraction(ref, rep)
        XCTAssertLessThan(diff, 0.03, "\(name): \(String(format: "%.1f", diff * 100)) % of pixels differ", file: file, line: line)
    }

    private func nonBlackFraction(_ rep: NSBitmapImageRep) -> Double {
        var count = 0, total = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 4) {
                total += 1
                if let c = rep.colorAt(x: x, y: y), c.brightnessComponent > 0.15 { count += 1 }
            }
        }
        return total > 0 ? Double(count) / Double(total) : 0
    }

    private func differingFraction(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Double {
        var diff = 0, total = 0
        for y in stride(from: 0, to: a.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: a.pixelsWide, by: 2) {
                total += 1
                guard let ca = a.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      let cb = b.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let d = max(abs(ca.redComponent - cb.redComponent), abs(ca.greenComponent - cb.greenComponent),
                            abs(ca.blueComponent - cb.blueComponent))
                if d > 0.08 { diff += 1 }
            }
        }
        return total > 0 ? Double(diff) / Double(total) : 0
    }
}

/// Runs the full wizard (alignment + verification + EQ round) in simulation for screenshots.
@MainActor
enum SimulatedSession {
    static func completeWizard() throws -> SetupWizard {
        var system = AppModel.demoSystem()
        system.micNoiseDBFS = -75
        var safety = GeneratorSafety()
        safety.fadeInSeconds = 0.05
        safety.startLevelDBFS = -20
        let backend = SimulatedAudioBackend(system: system, deviceLatency: 512, safety: safety, seed: 21)
        let engine = MeasurementEngine(backend: backend)
        backend.generatorControl.targetLevelDBFS.value = -20
        backend.generatorControl.run.value = true
        func run(_ seconds: Double) {
            for _ in 0..<Int(seconds * 40) { backend.pump(frames: 1200); engine.drainNow() }
        }
        func capture(_ seconds: Double, band: ClosedRange<Double>? = nil) -> Capture? {
            var c: Capture?
            engine.capture(label: "s", duration: seconds, qualityBand: band) { c = $0 }
            run(seconds + 0.5)
            return c
        }
        run(1)
        var delay: DelayEstimate?
        engine.findDelay(seconds: 3) { delay = $0 }
        run(3.5)
        var config = WizardConfiguration()
        config.crossover = 90
        config.captureSeconds = 8
        var w = SetupWizard(configuration: config)
        guard let d = delay else { throw XCTSkip("delay not found") }
        w.lockDelay(d, epoch: backend.discontinuities.value)
        w.start()
        for step in [WizardStep.baseline, .subOnly, .mainsOnly] {
            let g = step.requiredGroups!
            backend.setActiveGroups(sub: g.sub, main: g.mains)
            run(0.5)
            if let c = capture(8, band: step.qualityBand(crossover: 90)) { w.submit(c) }
        }
        guard let a = w.alignment else { throw XCTSkip("no alignment") }
        backend.applyAlignment(delaySeconds: a.roundedDelay, invertPolarity: a.best.invertPolarity, subGainDB: a.subGainDB)
        backend.setActiveGroups(sub: true, main: true)
        w.beginVerification()
        run(0.5)
        if let c = capture(8) { w.submit(c) }
        w.beginEQ()
        for p in 0..<w.configuration.eqPointCount {
            backend.moveMicrophone(toPoint: p)
            run(0.5)
            if let c = capture(6) { w.submit(c) }
        }
        if let r = w.computeEQ() {
            var knobs = backend.processorSettings
            knobs.subEQ = r.filters.filter { $0.group == .sub }
            knobs.mainsEQ = r.filters.filter { $0.group == .mains }
            backend.setProcessor(knobs)
            w.beginEQVerification()
            for p in 0..<w.eqPoints.count {
                backend.moveMicrophone(toPoint: p)
                run(0.5)
                if let c = capture(6) { w.submit(c) }
            }
            // Stay on the EQ tuning data for the screenshots, but keep the verification results.
        }
        return w
    }
}
