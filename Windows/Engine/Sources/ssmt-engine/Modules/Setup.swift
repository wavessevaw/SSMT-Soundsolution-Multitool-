import Foundation
import SSMTCore

// Function #1, automatic system setup: the engine side of App/SSMT/Model/AppModel.swift (measurement engine,
// generator, delay lock, auto level, calibration, wizard, alignment and EQ tuners, simulation, report and
// session). The interface (sections/setup.js) sends {cmd:'setup', do:<action>, …} and draws two events:
//   setupState  everything that changes on an action (sent when it changed, at most 10 times a second)
//   setupLive   the live measurement (meters, levels, curves, tuner readings), about 10 times a second
// Audio comes from the simulation (as on the Mac) or from the interface's 'setup' stream (Modules/AudioIO.swift).

final class SetupModule: EngineModule, @unchecked Sendable {
    // Setup
    var simulationSource = true
    var interfaceName = "Simulation"
    var microphoneChannel = 0
    var referenceChannel = 1
    var outputChannel = 0
    var referenceMode: ReferenceMode = .internalSignal
    var temperatureCelsius = 20.0 {
        didSet {
            if temperatureCelsius < 5 { ProfileModule.shared?.record("setup.cold") }
            if temperatureCelsius > 35 { ProfileModule.shared?.record("setup.hot") }
        }
    }

    // Generator
    var noise = 0
    var levelDBFS = -40.0
    var maximumLevelDBFS = -12.0
    var noiseOn = false

    // Live state
    var isRunning = false
    var snapshot: LiveSnapshot?
    var delay: DelayEstimate?
    var delaySearchRunning = false
    var lastError: String?

    // Calibration
    var calibration = CalibrationLibrary()
    enum AutoLevelState { case idle, measuringNoise, raising, done(AutoLevelController.Outcome, level: Double) }
    var autoLevelState: AutoLevelState = .idle
    var noiseFloor: [Double]?

    // Wizard
    var wizard = SetupWizard()
    var wizardCaptureRunning = false
    var wizardDelaySearch = false
    var lastAcceptance: CaptureAcceptance?
    var simulationSettingsApplied = false

    // Tuners
    var tunerActive = false
    var tunerStage: AlignmentTuner.Stage = .adjustSub
    var tunerReading: AlignmentTuner.Reading?
    var simProcessor = VirtualProcessorSettings()
    var tuner: AlignmentTuner?
    var lastTunerUpdate = Date.distantPast
    var tunerBusy = false
    var eqTunerReading: EQTuner.Reading?
    var eqReferenceCapturing = false
    var eqTuner: EQTuner?

    // Display
    var smoothing: SmoothingResolution = .oct12
    var coherenceThreshold = 0.6

    // Simulation
    var simulationSubOn = true
    var simulationMainOn = true

    var engine: MeasurementEngine?
    var simulationBackend: SimulatedAudioBackend?
    var streamBackend: StreamAudioBackend?
    var streamGeneration: UInt64 = 0

    var dataDir: URL?
    var dirty = true
    var nextState = Date()
    var liveDirty = false
    let grid = FrequencyGrid(pointsPerOctave: 24, minFrequency: 20, maxFrequency: 20000).frequencies

    /// Work handed back to the main loop from the measurement queue (completions, snapshots).
    private let lock = NSLock()
    private var inbox: [() -> Void] = []
    private func post(_ f: @escaping () -> Void) {
        lock.lock(); inbox.append(f); lock.unlock()
    }

    var isSimulation: Bool { simulationSource }

    var safety: GeneratorSafety {
        var s = GeneratorSafety()
        s.maximumLevelDBFS = maximumLevelDBFS
        return s
    }

    // MARK: commands

    func handle(_ c: Command, engine e: Engine) -> Bool {
        guard c.name == "setup" else { return false }
        if dataDir != e.dataDir {
            dataDir = e.dataDir
            calibration = CalibrationLibrary.load(from: calibrationURL)
        }
        let v = c.double("value")
        switch c.str("do") ?? "" {
        case "state": dirty = true; emitStatic()
        case "source":
            guard !isRunning else { break }
            simulationSource = c.str("kind") ?? "simulation" == "simulation"
            interfaceName = simulationSource ? "Simulation" : (c.str("name") ?? "—")
        case "channels":
            guard !isRunning else { break }
            microphoneChannel = c.int("mic") ?? microphoneChannel
            referenceChannel = c.int("ref") ?? referenceChannel
            outputChannel = c.int("out") ?? outputChannel
        case "startEngine":
            if let k = c.str("kind") { simulationSource = k == "simulation" }
            if let n = c.str("name") { interfaceName = simulationSource ? "Simulation" : n }
            microphoneChannel = c.int("mic") ?? microphoneChannel
            referenceChannel = c.int("ref") ?? referenceChannel
            outputChannel = c.int("out") ?? outputChannel
            startEngine(split: c.bool("split") ?? false)
        case "stopEngine": stopEngine()
        case "toggleNoise": toggleNoise()
        case "noise":
            noise = min(max(c.int("value") ?? 0, 0), 2)
            engine?.backend.generatorControl.kindIndex.value = UInt64(noise)
        case "level": if let v { levelDBFS = v.rounded(); applyLevel() }
        case "maxLevel": if let v { maximumLevelDBFS = v.rounded(); applyLevel() }
        case "stop": emergencyStop()
        case "findDelay": findDelay()
        case "autoLevel": runAutoLevel()
        case "cancelAutoLevel": cancelAutoLevel()
        case "referenceMode":
            referenceMode = ReferenceMode(rawValue: c.str("value") ?? "") ?? .internalSignal
            engine?.setReferenceMode(referenceMode)
        case "temperature": if let v { temperatureCelsius = min(max(v, -20), 50) }
        case "resetAverages": engine?.resetLiveAverages()
        case "resetClips": engine?.resetClipIndicators()
        case "resetSPL": engine?.resetSoundLevel()
        case "smoothing": smoothing = SmoothingResolution(rawValue: c.int("value") ?? 12) ?? .oct12
        case "coherenceThreshold": if let v { coherenceThreshold = min(max((v * 20).rounded() / 20, 0.3), 0.95) }
        // Calibration
        case "importMic": importMicrophoneCalibration(text: c.str("text") ?? "", name: c.str("name") ?? "")
        case "selectMic": selectMicrophone(c.str("id").flatMap(UUID.init(uuidString:)))
        case "removeMic": if let id = c.str("id").flatMap(UUID.init(uuidString:)) { removeMicrophone(id) }
        case "splText":
            setSPLCalibration(dBFSAt94: Double((c.str("text") ?? "").replacingOccurrences(of: ",", with: ".")))
        case "calibrator": calibrateWithCalibrator(level: v ?? 94)
        // Wizard
        case "lockDelay": wizardLockDelay()
        case "wizardStart": wizardStart()
        case "capture": wizardCaptureRunning ? wizardCancelCapture() : wizardCapture()
        case "cancelCapture": wizardCancelCapture()
        case "beginVerification": wizardBeginVerification()
        case "back": wizardBack()
        case "restart": wizardRestart()
        case "tunerStart": startTuner()
        case "tunerStop": stopTuner()
        case "tunerAdvance": tunerAdvanceToMains()
        case "beginEQ": wizardBeginEQ()
        case "simMovePoint": simulateMoveToNextPoint()
        case "computeEQ": wizardComputeEQ()
        case "startEQTuner": startEQTuner()
        case "stopEQTuner": stopEQTuner()
        case "beginEQVerification": wizardBeginEQVerification()
        case "iterateEQ": wizardIterateEQ()
        case "finish": wizardFinish()
        case "simGroups": simulateGroupsForStep()
        case "simApply": simulateApplyRecommendation()
        case "simSub": simulationSubOn = c.bool("value") ?? true; applySimulationGroups()
        case "simMain": simulationMainOn = c.bool("value") ?? true; applySimulationGroups()
        case "simProcessor":
            var p = simProcessor
            if let x = c.double("subDelayMs") { p.subDelayMs = min(max(x, 0), 20) }
            if let x = c.double("mainsDelayMs") { p.mainsDelayMs = min(max(x, 0), 20) }
            if let x = c.double("subGainDB") { p.subGainDB = min(max(x, -12), 6) }
            if let x = c.bool("subPolarityInverted") { p.subPolarityInverted = x }
            setSimProcessor(p)
        case "simToggleBand": if let f = filter(c.int("id")) { simulateToggleBand(f) }
        case "simBandGain": if let f = filter(c.int("id")), let v { simulateSetBandGain(f, gain: v) }
        case "config": configure(c)
        case "targetPreview":
            let pts = c.decode([TargetPoint].self, "points") ?? []
            let curve = TargetCurve(preset: .custom, name: "", points: pts)
            Out.emit("setupTargetPreview", ["db": nums(grid.map { curve.value(at: $0) })])
        // Report, session and export
        case "saveSession": saveSession(path: c.str("path") ?? "", appVersion: c.str("appVersion") ?? engineVersion)
        case "openSession": openSession(path: c.str("path") ?? "")
        case "saveExport": saveExport(path: c.str("path") ?? "", csv: c.bool("csv") ?? false)
        case "error": lastError = c.str("text")
        case "dismissError": lastError = nil
        case "fixture":
            // The Mac snapshot tests' state: the wizard after a complete simulated session.
            if let w = SimulatedSetupSession.completeWizard() { wizard = w }
        default:
            Out.emit("error", ["key": "unknownCommand", "detail": "setup." + (c.str("do") ?? "")])
            return true
        }
        dirty = true
        return true
    }

    private func filter(_ id: Int?) -> PEQFilter? {
        guard let id else { return nil }
        return wizard.eqResult?.filters.first { $0.id == id }
    }

    private func configure(_ c: Command) {
        var cfg = wizard.configuration
        if let x = c.bool("hasSubwoofer") { cfg.hasSubwoofer = x }
        if let x = c.bool("fastMode") { cfg.fastMode = x }
        if let x = c.bool("knownCrossover") { cfg.crossover = x ? 90 : nil }
        if let x = c.double("crossover"), cfg.crossover != nil { cfg.crossover = min(max(x, 40), 250) }
        if let x = c.double("delayStep") { cfg.delayStep = x }
        if let x = c.double("levelStep") { cfg.levelStep = x }
        if let x = c.int("eqPointCount") { cfg.eqPointCount = min(max(x, 3), 9) }
        if let x = c.str("grid"), let g = EQFrequencyGrid(rawValue: x) { cfg.eq.frequencyGrid = g }
        if let x = c.str("targetPreset"), let p = TargetCurve.Preset(rawValue: x), p != .custom { cfg.target = .preset(p) }
        if let pts = c.decode([TargetPoint].self, "targetPoints") {
            cfg.target = TargetCurve(preset: .custom, name: c.str("targetName") ?? "custom", points: pts)
        }
        if let id = c.str("processorPreset"), let p = ProcessorProfile.profile(id: id) { cfg.processor = p }
        if c.bool("processorCustom") == true, !cfg.processor.isCustom { cfg.processor = .customDefault }
        if let p = c.decode(ProcessorProfile.self, "processor") { cfg.processor = p }
        wizard.configuration = cfg
    }

    // MARK: engine lifecycle

    var calibrationURL: URL {
        let dir = dataDir ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/SSMT")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("calibration.json")
    }

    func startEngine(split: Bool) {
        guard !isRunning else { return }
        lastError = nil
        let backend: AudioIOBackend
        if isSimulation {
            let sim = SimulatedAudioBackend(system: VirtualSystem.demo(), deviceLatency: 512, safety: safety)
            simulationBackend = sim
            streamBackend = nil
            backend = sim
            applySimulationGroups()
        } else {
            let stream = AudioBridge.shared.stream("setup")
            guard stream.isOpen, stream.inChannels > 0, stream.outChannels > 0 else {
                lastError = StreamAudioError.notOpen.description
                return
            }
            do {
                let b = try StreamAudioBackend(
                    sampleRate: stream.sampleRate, inputChannels: stream.inChannels, outputChannels: stream.outChannels,
                    routing: .init(microphoneChannel: microphoneChannel,
                                   referenceChannel: referenceMode == .internalSignal ? nil : referenceChannel,
                                   outputChannels: [outputChannel]),
                    displayName: interfaceName, splitClock: split, hostEchoesPlayed: stream.loopChannel == outputChannel,
                    safety: safety)
                b.reportedRoundTripLatency = Int((stream.latency * stream.sampleRate).rounded())
                stream.setSource { out, frames, channels in b.render(into: &out, frames: frames, channels: channels) }
                stream.setSink { [weak stream] samples, frames, channels in
                    b.capture(samples, frames: frames, channels: channels, played: stream?.played, frameIndex: stream?.frame)
                }
                streamGeneration = stream.generation
                streamBackend = b
                backend = b
            } catch {
                lastError = String(describing: error)
                return
            }
            simulationBackend = nil
        }
        var config = MeasurementEngine.Configuration()
        config.referenceMode = referenceMode
        let m = MeasurementEngine(backend: backend, configuration: config)
        m.setSnapshotHandler { [weak self] snap in self?.post { self?.receive(snap) } }
        do {
            try m.start()
        } catch {
            lastError = String(describing: error)
            detachStream()
            return
        }
        m.setSPLCalibration(calibration.spl)
        engine = m
        isRunning = true
        delay = nil
        noiseFloor = nil
        autoLevelState = .idle
        simulationSettingsApplied = false
        setSimProcessor(VirtualProcessorSettings())
        stopTuner()
        wizard = SetupWizard(configuration: wizard.configuration)
    }

    private func detachStream() {
        let s = AudioBridge.shared.stream("setup")
        s.setSource(nil)
        s.setSink(nil)
        streamBackend = nil
    }

    private func receive(_ snap: LiveSnapshot) {
        guard isRunning else { return }
        // The interface stopped delivering audio (device unplugged, driver stopped): stop cleanly.
        if snap.secondsSinceAudio > 1.5 {
            handleAudioLoss()
            return
        }
        snapshot = snap
        liveDirty = true
        guard let tf = snap.transfer, !tunerBusy, snap.timestamp.timeIntervalSince(lastTunerUpdate) >= 0.25 else { return }
        // Tuner readings run the full alignment / EQ comparison off the main loop; one at a time.
        if tunerActive, let tuner {
            lastTunerUpdate = snap.timestamp
            tunerBusy = true
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let reading = tuner.read(live: tf)
                self?.post {
                    guard let self else { return }
                    self.tunerBusy = false
                    if self.tunerActive, self.tuner?.stage == tuner.stage { self.tunerReading = reading; self.dirty = true }
                }
            }
        } else if let eqTuner {
            lastTunerUpdate = snap.timestamp
            tunerBusy = true
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let reading = eqTuner.read(live: tf)
                self?.post {
                    guard let self else { return }
                    self.tunerBusy = false
                    if self.eqTuner != nil { self.eqTunerReading = reading; self.dirty = true }
                }
            }
        }
    }

    private func handleAudioLoss() {
        wizardCancelCapture()
        stopEQTuner()
        stopTuner()
        stopEngine()
        lastError = "error.audioLost"
    }

    func stopEngine() {
        stopTuner()
        stopEQTuner()
        tunerBusy = false
        if wizardCaptureRunning { engine?.cancelCapture() }
        wizardCaptureRunning = false
        wizardDelaySearch = false
        delaySearchRunning = false
        eqReferenceCapturing = false
        engine?.stop()
        engine = nil
        simulationBackend = nil
        detachStream()
        isRunning = false
        noiseOn = false
        snapshot = nil
        autoLevelState = .idle
        liveDirty = true
    }

    // MARK: generator

    func setNoise(on: Bool) {
        guard let engine else { return }
        let c = engine.backend.generatorControl
        c.kindIndex.value = UInt64(noise)
        c.targetLevelDBFS.value = Float(min(levelDBFS, maximumLevelDBFS))
        c.run.value = on
        noiseOn = on
    }

    func toggleNoise() {
        if !isRunning { startEngine(split: false) }
        setNoise(on: !noiseOn)
    }

    func applyLevel() {
        engine?.backend.generatorControl.targetLevelDBFS.value = Float(min(levelDBFS, maximumLevelDBFS))
    }

    func emergencyStop() {
        if noiseOn { ProfileModule.shared?.record("setup.stop") }
        engine?.emergencyStop()
        if streamBackend != nil { AudioBridge.shared.stream("setup").flush() }
        noiseOn = false
    }

    // MARK: measurement

    func findDelay() {
        guard let engine, noiseOn else { return }
        delaySearchRunning = true
        engine.findDelay(seconds: 3) { [weak self] estimate in
            self?.post {
                self?.delay = estimate
                self?.delaySearchRunning = false
                self?.dirty = true
                if estimate?.isReliable == true { ProfileModule.shared?.record("setup.delayFound") }
            }
        }
    }

    func runAutoLevel() {
        guard let engine else { return }
        autoLevelState = .measuringNoise
        noiseOn = false
        engine.measureNoiseFloor(seconds: 5) { [weak self] floor in
            self?.post {
                guard let self, let engine = self.engine else { return }
                self.noiseFloor = floor
                self.autoLevelState = .raising
                self.noiseOn = true
                self.dirty = true
                var settings = AutoLevelController.Settings()
                settings.maximumLevelDBFS = self.maximumLevelDBFS
                engine.runAutoLevel(settings: settings, noiseFloor: floor) { level, outcome in
                    self.post {
                        self.levelDBFS = level
                        self.autoLevelState = .done(outcome, level: level)
                        if outcome == .clipped { self.noiseOn = true }
                        self.dirty = true
                    }
                }
            }
        }
    }

    func cancelAutoLevel() {
        engine?.cancelAutoLevel()
        engine?.cancelCapture()
        autoLevelState = .idle
    }

    // MARK: calibration

    func importMicrophoneCalibration(text: String, name: String) {
        let base = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        do {
            let mic = try MicrophoneCalibration.parse(text, name: base)
            calibration.microphones.append(mic)
            calibration.selectedMicrophoneID = mic.id
            calibration.save(to: calibrationURL)
            ProfileModule.shared?.record("setup.calibration")
        } catch {
            lastError = "\(name): \(error)"
        }
    }

    func selectMicrophone(_ id: UUID?) {
        calibration.selectedMicrophoneID = id
        calibration.save(to: calibrationURL)
    }

    func removeMicrophone(_ id: UUID) {
        calibration.microphones.removeAll { $0.id == id }
        if calibration.selectedMicrophoneID == id { calibration.selectedMicrophoneID = nil }
        calibration.save(to: calibrationURL)
    }

    func setSPLCalibration(dBFSAt94: Double?) {
        calibration.spl = dBFSAt94.map { SPLCalibration(dBFSAt94dBSPL: $0) }
        calibration.save(to: calibrationURL)
        engine?.setSPLCalibration(calibration.spl)
        engine?.resetSoundLevel()
    }

    func calibrateWithCalibrator(level: Double) {
        guard let rms = snapshot?.microphone.rmsDBFS, rms > -100 else { return }
        emergencyStop()
        let c = SPLCalibration.fromCalibrator(measuredDBFS: rms, calibratorSPL: level)
        setSPLCalibration(dBFSAt94: c.dBFSAt94dBSPL)
    }

    /// Transfer function for display: microphone response removed when a calibration is selected.
    var displayTransfer: TransferFunction? {
        guard let tf = snapshot?.transfer else { return nil }
        return calibration.selectedMicrophone?.apply(to: tf) ?? tf
    }

    // MARK: wizard

    func wizardLockDelay() {
        guard let engine else { return }
        if !noiseOn { setNoise(on: true) }
        wizardDelaySearch = true
        engine.findDelay(seconds: 3) { [weak self] estimate in
            let epoch = engine.backend.discontinuities.value
            self?.post {
                guard let self else { return }
                self.wizardDelaySearch = false
                self.delay = estimate
                if let e = estimate, e.isReliable {
                    self.wizard.lockDelay(e, epoch: epoch)
                    ProfileModule.shared?.record("setup.delayFound")
                }
                self.dirty = true
            }
        }
    }

    func wizardStart() {
        wizard.configuration.temperatureCelsius = temperatureCelsius
        wizard.configuration.coherenceThreshold = coherenceThreshold
        lastAcceptance = nil
        simulationSettingsApplied = false
        wizard.start()
        if isSimulation { simulateGroupsForStep() }
    }

    func wizardCapture() {
        guard let engine, wizard.step.requiredGroups != nil, !wizardCaptureRunning else { return }
        if !noiseOn { setNoise(on: true) }
        wizardCaptureRunning = true
        lastAcceptance = nil
        let step = wizard.step
        engine.capture(label: "\(step)", duration: wizard.configuration.captureSeconds,
                       qualityBand: step.qualityBand(crossover: wizard.configuration.crossover)) { [weak self] capture in
            self?.post {
                guard let self, self.wizardCaptureRunning else { return }
                self.wizardCaptureRunning = false
                let hadAlignment = self.wizard.alignment != nil
                self.lastAcceptance = self.wizard.submit(capture)
                if !hadAlignment, let a = self.wizard.alignment {
                    ProfileModule.shared?.record("setup.aligned")
                    if a.best.invertPolarity { ProfileModule.shared?.record("setup.polarityFixed") }
                }
                if case .accepted = self.lastAcceptance, self.isSimulation {
                    self.simulateGroupsForStep()
                    if step == .eqPoints || step == .eqVerification { self.simulateMoveToNextPoint() }
                }
                self.dirty = true
            }
        }
    }

    func wizardCancelCapture() {
        engine?.cancelCapture()
        wizardCaptureRunning = false
    }

    func wizardBeginVerification() {
        stopTuner()
        lastAcceptance = nil
        wizard.beginVerification()
        if isSimulation { simulateGroupsForStep() }
    }

    func wizardBack() {
        stopTuner()
        wizardCancelCapture()
        lastAcceptance = nil
        wizard.goBack()
        if isSimulation { simulateGroupsForStep() }
    }

    func wizardRestart() {
        stopEQTuner()
        stopTuner()
        wizardCancelCapture()
        lastAcceptance = nil
        simulationSettingsApplied = false
        wizard = SetupWizard(configuration: wizard.configuration)
        if let d = delay, d.isReliable, let engine {
            wizard.lockDelay(d, epoch: engine.backend.discontinuities.value)
        }
    }

    var tunerNeedsMainsStage: Bool { wizard.alignment?.delayTarget == .mains }

    func startTuner() {
        guard let engine, let a = wizard.alignment, let mains = wizard.mainsResponse else { return }
        tuner = AlignmentTuner(stage: .adjustSub, fixed: mains, alignment: a, settings: wizard.configuration.alignmentSettings)
        tunerStage = .adjustSub
        tunerReading = nil
        tunerActive = true
        if !noiseOn { setNoise(on: true) }
        if isSimulation {
            simulationSubOn = true
            simulationMainOn = true
            applySimulationGroups()
        }
        engine.setLiveAveraging(seconds: 1.0)
        engine.resetLiveAverages()
    }

    func tunerAdvanceToMains() {
        guard let t = tuner, let tf = snapshot?.transfer, let a = wizard.alignment else { return }
        let adjustedSub = t.changingResponse(live: tf)
        tuner = AlignmentTuner(stage: .adjustMainsDelay, fixed: adjustedSub, alignment: a,
                               settings: wizard.configuration.alignmentSettings)
        tunerStage = .adjustMainsDelay
        tunerReading = nil
        engine?.resetLiveAverages()
    }

    func stopTuner() {
        guard tunerActive else { return }
        tunerActive = false
        tuner = nil
        tunerReading = nil
        engine?.setLiveAveraging(seconds: 1.5)
    }

    func wizardBeginEQ() {
        stopTuner()
        lastAcceptance = nil
        wizard.beginEQ()
        if isSimulation { simulateGroupsForStep(); simulationBackend?.moveMicrophone(toPoint: 0) }
    }

    func simulateMoveToNextPoint() {
        let index = wizard.step == .eqVerification ? wizard.eqVerificationPoints.count : wizard.eqPoints.count
        simulationBackend?.moveMicrophone(toPoint: index)
        engine?.resetLiveAverages()
    }

    func wizardComputeEQ() {
        lastAcceptance = nil
        wizard.computeEQ(microphone: calibration.selectedMicrophone)
        ProfileModule.shared?.record("setup.eqBands", count: wizard.eqResult?.filters.count ?? 0)
        if isSimulation { simulationBackend?.moveMicrophone(toPoint: 0) }
    }

    func startEQTuner() {
        guard let engine, let r = wizard.eqResult, !eqReferenceCapturing else { return }
        if !noiseOn { setNoise(on: true) }
        eqReferenceCapturing = true
        eqTuner = nil
        eqTunerReading = nil
        engine.setLiveAveraging(seconds: 1.0)
        engine.capture(label: "eq-reference", duration: 6) { [weak self] c in
            self?.post {
                guard let self, self.eqReferenceCapturing else { return }
                self.eqReferenceCapturing = false
                self.eqTuner = EQTuner(reference: c.transfer, filters: r.filters, workingRange: r.workingRange)
                self.engine?.resetLiveAverages()
                self.dirty = true
            }
        }
    }

    func stopEQTuner() {
        eqTuner = nil
        eqTunerReading = nil
        engine?.setLiveAveraging(seconds: 1.5)
    }

    func wizardBeginEQVerification() {
        stopEQTuner()
        lastAcceptance = nil
        wizard.beginEQVerification()
        if isSimulation { simulationBackend?.moveMicrophone(toPoint: 0) }
    }

    func wizardIterateEQ() {
        lastAcceptance = nil
        wizard.iterateEQ(microphone: calibration.selectedMicrophone)
        if isSimulation { simulationBackend?.moveMicrophone(toPoint: 0) }
    }

    func wizardFinish() {
        stopEQTuner()
        wizard.finish()
        ProfileModule.shared?.record("setup.finished")
        if isSimulation { ProfileModule.shared?.record("setup.simFinished") }
    }

    // MARK: simulation

    func setSimProcessor(_ p: VirtualProcessorSettings) {
        simProcessor = p
        simulationBackend?.setProcessor(p)
        // The simulated knob change is known exactly: restart averaging so the needle reacts fast.
        if tunerActive { engine?.resetLiveAverages() }
    }

    func simulateToggleBand(_ filter: PEQFilter) {
        var p = simProcessor
        if filter.group == .sub {
            if let i = p.subEQ.firstIndex(where: { $0.id == filter.id }) { p.subEQ.remove(at: i) } else { p.subEQ.append(filter) }
        } else {
            if let i = p.mainsEQ.firstIndex(where: { $0.id == filter.id }) { p.mainsEQ.remove(at: i) } else { p.mainsEQ.append(filter) }
        }
        setSimProcessor(p)
    }

    func simulatedBandEntered(_ filter: PEQFilter) -> PEQFilter? {
        (simProcessor.subEQ + simProcessor.mainsEQ).first { $0.id == filter.id }
    }

    func simulateSetBandGain(_ filter: PEQFilter, gain: Double) {
        let g = min(max((gain * 2).rounded() / 2, -12), 3)
        var p = simProcessor
        if let i = p.subEQ.firstIndex(where: { $0.id == filter.id }) { p.subEQ[i].gainDB = g }
        if let i = p.mainsEQ.firstIndex(where: { $0.id == filter.id }) { p.mainsEQ[i].gainDB = g }
        setSimProcessor(p)
    }

    func simulateGroupsForStep() {
        guard isSimulation, let g = wizard.step.requiredGroups else { return }
        simulationSubOn = g.sub
        simulationMainOn = g.mains
        applySimulationGroups()
    }

    func simulateApplyRecommendation() {
        guard isSimulation, !simulationSettingsApplied, let a = wizard.alignment else { return }
        var p = simProcessor
        if a.roundedDelay >= 0 { p.subDelayMs += a.roundedDelay * 1000 } else { p.mainsDelayMs -= a.roundedDelay * 1000 }
        if a.best.invertPolarity { p.subPolarityInverted.toggle() }
        p.subGainDB += a.subGainDB
        setSimProcessor(p)
        simulationSettingsApplied = true
    }

    func applySimulationGroups() {
        simulationBackend?.setActiveGroups(sub: simulationSubOn, main: simulationMainOn)
    }

    // MARK: report, session and export

    var setupReport: SetupReport {
        SetupReport(wizard: wizard, interfaceName: interfaceName, sampleRate: 48000, microphone: calibration.selectedMicrophone)
    }

    var exportFilters: [PEQFilter] { wizard.enteredFilters.isEmpty ? (wizard.eqResult?.filters ?? []) : wizard.enteredFilters }

    var exportText: String {
        PEQExport.filterSettingsText(exportFilters, title: "SSMT Filter Settings · \(wizard.configuration.processor.name)",
                                     widthInOctaves: wizard.configuration.processor.bandwidthInOctaves)
    }

    func saveSession(path: String, appVersion: String) {
        guard !path.isEmpty else { return }
        let file = SessionFile(wizard: wizard, interfaceName: interfaceName, sampleRate: 48000,
                               microphoneCalibrationName: calibration.selectedMicrophone?.name, appVersion: appVersion)
        do { try file.encoded().write(to: URL(fileURLWithPath: path), options: .atomic) } catch { lastError = "\(error)" }
    }

    func openSession(path: String) {
        guard !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        do {
            let file = try SessionFile.decode(Data(contentsOf: url))
            stopTuner()
            stopEQTuner()
            wizard = file.wizard
            Out.emit("setupSessionOpened")
        } catch {
            lastError = "\(url.lastPathComponent): \(error)"
        }
    }

    func saveExport(path: String, csv: Bool) {
        guard !path.isEmpty else { return }
        do {
            try (csv ? PEQExport.csv(exportFilters) : exportText).write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
        } catch {
            lastError = "\(error)"
        }
    }

    // MARK: clock

    func tick(_ now: Date, engine e: Engine) {
        lock.lock()
        let work = inbox
        inbox = []
        lock.unlock()
        for f in work { f() }
        // A restarted or reformatted interface stream breaks the output→input offset.
        if let b = streamBackend {
            let s = AudioBridge.shared.stream("setup")
            if s.generation != streamGeneration {
                streamGeneration = s.generation
                b.markDiscontinuity()
            }
        }
        if liveDirty {
            liveDirty = false
            emitLive()
        }
        if dirty && now >= nextState {
            dirty = false
            nextState = now.addingTimeInterval(0.1)
            emitState()
        }
    }

    // MARK: events

    func nums(_ v: [Double], _ scale: Double = 100) -> [Any] {
        v.map { x -> Any in
            guard x.isFinite else { return NSNull() }
            return (x * scale).rounded() / scale
        }
    }

    func num(_ v: Double?, _ scale: Double = 1000) -> Any {
        guard let v, v.isFinite else { return NSNull() }
        return (v * scale).rounded() / scale
    }

    func range(_ r: ClosedRange<Double>?) -> Any {
        guard let r else { return NSNull() }
        return [num(r.lowerBound), num(r.upperBound)]
    }

    /// Magnitude (dB) of a transfer function on its grid, invalid points null.
    func magnitude(_ tf: TransferFunction?, smoothing: SmoothingResolution = .none) -> Any {
        guard let tf else { return NSNull() }
        let s = Smoothing.smooth(tf, resolution: smoothing)
        return nums(s.frequencies.indices.map { s.isValid($0) ? Decibel.fromAmplitude(s.response[$0].magnitude) : .nan })
    }

    /// A dB curve 1/6-octave smoothed, as ComparisonPlotView draws relative plots (zero phase, full coherence).
    func smoothedDB(_ db: [Double], _ f: [Double]) -> Any {
        guard db.count == f.count, !f.isEmpty else { return NSNull() }
        let tf = TransferFunction(frequencies: f,
                                  response: db.map { $0.isFinite ? Complex(Decibel.toAmplitude($0)) : Complex(.nan, .nan) },
                                  coherence: db.map { _ in 1 }, measurementPower: db.map { _ in 1 },
                                  referencePower: db.map { _ in 1 }, averages: 1)
        return magnitude(tf, smoothing: .oct6)
    }

    func filterJSON(_ f: PEQFilter) -> [String: Any] {
        ["id": f.id, "frequency": num(f.frequency), "gainDB": num(f.gainDB), "q": num(f.q), "group": f.group.rawValue,
         "label": f.frequencyLabel, "width": f.widthLabel(inOctaves: wizard.configuration.processor.bandwidthInOctaves)]
    }

    func emitStatic() {
        Out.emit("setupStatic", [
            "frequencies": nums(grid, 1000),
            "processors": Out.json(ProcessorProfile.presets),
            "customProcessor": Out.json(ProcessorProfile.customDefault),
            "targetPresets": TargetCurve.Preset.allCases.map(\.rawValue),
            "targets": Dictionary(uniqueKeysWithValues: TargetCurve.Preset.allCases.map { ($0.rawValue, Out.json(TargetCurve.preset($0).points)) }),
            "grids": EQFrequencyGrid.allCases.map(\.rawValue),
            "microphones": MicrophoneProfile.Kind.allCases.map { kind -> [String: Any] in
                ["kind": kind.rawValue, "items": MicrophoneProfiles.all.filter { $0.kind == kind }.map { ["id": $0.uuid.uuidString, "name": $0.displayName] }]
            },
        ])
    }

    func autoLevelJSON() -> [String: Any] {
        switch autoLevelState {
        case .idle: return ["state": "idle"]
        case .measuringNoise: return ["state": "measuringNoise"]
        case .raising: return ["state": "raising"]
        case let .done(outcome, level):
            switch outcome {
            case let .targetReached(snr): return ["state": "done", "outcome": "targetReached", "level": num(level), "snr": num(snr)]
            case let .maximumReached(snr): return ["state": "done", "outcome": "maximumReached", "level": num(level), "snr": num(snr)]
            case .clipped: return ["state": "done", "outcome": "clipped", "level": num(level)]
            }
        }
    }

    func acceptanceJSON() -> Any {
        switch lastAcceptance {
        case .none: return NSNull()
        case let .some(.accepted(q)): return ["kind": "accepted", "quality": q.rawValue]
        case let .some(.rejected(reasons)): return ["kind": "rejected", "reasons": reasons.map(\.rawValue)]
        case .some(.streamRestarted): return ["kind": "streamRestarted"]
        }
    }

    func calibrationJSON() -> [String: Any] {
        var c: [String: Any] = [
            "files": calibration.microphones.map { ["id": $0.id.uuidString, "name": $0.name] },
            "selected": calibration.selectedMicrophoneID?.uuidString ?? NSNull(),
            "spl": num(calibration.spl?.dBFSAt94dBSPL),
        ]
        if let mic = calibration.selectedMicrophone {
            var f = 20.0, curve: [Double] = []
            while f <= 20000 { curve.append(mic.deviation(at: f)); f *= pow(2, 1.0 / 12) }
            c["mic"] = ["name": mic.name, "points": mic.frequencies.count, "header": mic.sensitivityHeader ?? NSNull(),
                        "curve": nums(curve)] as [String: Any]
            if let p = calibration.selectedProfile {
                c["profile"] = ["name": p.displayName, "flat": p.isNominallyFlat, "cardioid": p.pattern == .cardioid] as [String: Any]
            }
        }
        return c
    }

    func wizardJSON() -> [String: Any] {
        let w = wizard
        let cfg = w.configuration
        var j: [String: Any] = [
            "step": "\(w.step)", "stepIndex": w.step.rawValue, "prepared": w.isPrepared,
            "config": [
                "hasSubwoofer": cfg.hasSubwoofer, "fastMode": cfg.fastMode, "crossover": num(cfg.crossover),
                "delayStep": cfg.delayStep, "levelStep": cfg.levelStep, "eqPointCount": cfg.eqPointCount,
                "target": Out.json(cfg.target), "grid": cfg.eq.frequencyGrid.rawValue, "processor": Out.json(cfg.processor),
            ] as [String: Any],
            "qualityBand": range(w.step.qualityBand(crossover: cfg.crossover)),
            "requiredGroups": w.step.requiredGroups.map { ["sub": $0.sub, "mains": $0.mains] as [String: Any] } ?? NSNull(),
            "eqPoints": w.eqPoints.map { $0.assessment.quality.rawValue },
            "eqVerificationPoints": w.eqVerificationPoints.map { $0.assessment.quality.rawValue },
            "canComputeEQ": w.canComputeEQ, "canIterateEQ": w.canIterateEQ,
            "alignmentError": w.alignmentError ?? NSNull(),
            "hasMains": w.mainsResponse != nil,
        ]
        j["cards"] = w.actionCards.map { card -> [String: Any] in
            switch card {
            case let .delaySub(s, m): return ["kind": "delaySub", "seconds": num(s, 1e6), "meters": num(m)]
            case let .delayMains(s, m): return ["kind": "delayMains", "seconds": num(s, 1e6), "meters": num(m)]
            case .noDelayChange: return ["kind": "noDelayChange"]
            case let .polarity(invert): return ["kind": "polarity", "invert": invert]
            case let .subLevel(db): return ["kind": "subLevel", "dB": num(db)]
            }
        }
        if let a = w.alignment {
            j["alignment"] = ["ambiguous": a.isAmbiguous, "roundedDelay": num(a.roundedDelay, 1e7), "crossover": num(a.crossover),
                              "overlapBand": range(a.overlapBand), "invert": a.best.invertPolarity, "subGainDB": num(a.subGainDB),
                              "delayTarget": a.delayTarget.rawValue,
                              "canEnter": cfg.processor.canEnter(delaySeconds: a.roundedDelay),
                              "maxDelayMs": num(cfg.processor.maxDelayMs)] as [String: Any]
        }
        if let r = w.report {
            j["report"] = ["verdict": r.verdict.rawValue, "advice": r.advice.rawValue,
                           "dipBefore": num(r.before?.dipDepthDB), "dipAfter": num(r.after?.dipDepthDB),
                           "predictionError": num(r.predictionErrorDB)] as [String: Any]
        }
        // Comparison curves (1/6-octave smoothed, as ComparisonPlotView draws them).
        j["curves"] = [
            "baseline": magnitude(w.baseline?.transfer, smoothing: .oct6),
            "prediction": magnitude(w.prediction, smoothing: .oct6),
            "verification": magnitude(w.verification?.transfer, smoothing: .oct6),
            "eqAfter": w.eqAfterAverage.map { nums($0.levelDB) } ?? NSNull(),
            "eqAfterSmoothed": magnitude(w.eqAfterAverage?.asTransferFunction, smoothing: .oct6),
            "eqAfterFrequencies": w.eqAfterAverage.map { nums($0.frequencies, 1000) } ?? NSNull(),
        ] as [String: Any]
        if let r = w.eqResult {
            j["eqResult"] = ["filters": r.filters.map(filterJSON), "workingRange": range(r.workingRange),
                             "measuredDB": nums(r.measuredDB), "targetDB": nums(r.targetDB), "predictedDB": nums(r.predictedDB),
                             "filterResponseDB": nums(r.filterResponseDB), "frequencies": nums(r.frequencies, 1000),
                             "smoothed": [
                                "measured": smoothedDB(r.measuredDB, r.frequencies),
                                "target": smoothedDB(r.targetDB, r.frequencies),
                                "predicted": smoothedDB(r.predictedDB, r.frequencies),
                             ] as [String: Any]] as [String: Any]
        }
        if let s = w.eqScores(microphone: calibration.selectedMicrophone) {
            let before: [String: Any] = ["deviation": num(s.before.rmsDeviationDB), "score": s.before.score]
            var after: Any = NSNull()
            if let a = s.after { after = ["deviation": num(a.rmsDeviationDB), "score": a.score] as [String: Any] }
            j["eqScores"] = ["before": before, "after": after] as [String: Any]
        }
        return j
    }

    func reportJSON() -> [String: Any] {
        let r = setupReport
        var j: [String: Any] = [
            "date": r.date.timeIntervalSince1970 * 1000, "interfaceName": r.interfaceName, "sampleRate": r.sampleRate,
            "temperature": r.temperatureCelsius, "microphone": r.microphoneCalibrationName ?? NSNull(),
            "referenceDelayMs": num(r.referenceDelayMs), "plainText": r.plainText,
        ]
        if let a = r.alignment {
            j["alignment"] = ["delayMs": num(a.delayMs), "delayMeters": num(a.delayMeters), "delayTarget": a.delayTarget.rawValue,
                              "invert": a.invertPolarity, "subLevelDB": num(a.subLevelDB), "crossover": num(a.crossover),
                              "ambiguous": a.ambiguous] as [String: Any]
        }
        if let v = r.verification {
            j["verification"] = ["dipBefore": num(v.dipBeforeDB), "dipAfter": num(v.dipAfterDB),
                                 "sumBefore": num(v.summationBeforeDB), "sumAfter": num(v.summationAfterDB),
                                 "predictionError": num(v.predictionErrorDB), "verdict": v.verdict.rawValue] as [String: Any]
        }
        if let e = r.eq {
            j["eq"] = ["filters": e.filters.map(filterJSON), "target": e.targetName, "points": e.points, "iterations": e.iterations,
                       "deviationBefore": num(e.deviationBeforeDB), "deviationAfter": num(e.deviationAfterDB),
                       "scoreBefore": e.scoreBefore, "scoreAfter": e.scoreAfter ?? NSNull()] as [String: Any]
        }
        return j
    }

    func emitState() {
        var tunerJSON: Any = NSNull()
        if let r = tunerReading {
            tunerJSON = ["delayError": num(r.delayError, 1e7), "delayPhaseError": num(r.delayPhaseError), "polarityWrong": r.polarityWrong,
                         "levelError": num(r.levelError), "delayInTune": r.delayInTune, "levelInTune": r.levelInTune,
                         "allInTune": r.allInTune, "reliable": r.isReliable] as [String: Any]
        }
        var eqJSON: Any = NSNull()
        if let r = eqTunerReading {
            eqJSON = ["bands": r.bands.map { ["index": $0.bandIndex, "remaining": num($0.remainingGainDB), "shape": num($0.shapeErrorDB),
                                              "inTune": $0.inTune] as [String: Any] },
                      "overall": num(r.overallErrorDB), "applied": nums(r.appliedDB), "planned": nums(r.plannedDB),
                      "confidence": num(r.confidence), "allInTune": r.allInTune] as [String: Any]
        }
        let entered: [String: Any] = Dictionary(uniqueKeysWithValues: (simProcessor.subEQ + simProcessor.mainsEQ).map { ("\($0.id)", num($0.gainDB) as Any) })
        Out.emit("setupState", [
            "running": isRunning, "simulation": isSimulation, "interfaceName": interfaceName,
            "displayName": engine?.backend.displayName ?? "", "split": streamBackend?.splitClock ?? false,
            "latencySamples": streamBackend?.reportedRoundTripLatency ?? 0,
            "channels": ["mic": microphoneChannel, "ref": referenceChannel, "out": outputChannel],
            "referenceMode": referenceMode.rawValue, "temperature": temperatureCelsius,
            "noise": noise, "level": levelDBFS, "maxLevel": maximumLevelDBFS, "noiseOn": noiseOn,
            "delay": delay.map { ["ms": num($0.milliseconds), "reliable": $0.isReliable] as [String: Any] } ?? NSNull(),
            "delaySearch": delaySearchRunning, "wizardDelaySearch": wizardDelaySearch,
            "autoLevel": autoLevelJSON(), "noiseFloor": noiseFloor != nil,
            "lastError": lastError ?? NSNull(),
            "smoothing": smoothing.rawValue, "coherenceThreshold": coherenceThreshold,
            "simSub": simulationSubOn, "simMain": simulationMainOn, "simApplied": simulationSettingsApplied,
            "simProcessor": ["subDelayMs": num(simProcessor.subDelayMs), "mainsDelayMs": num(simProcessor.mainsDelayMs),
                             "subGainDB": num(simProcessor.subGainDB), "subPolarityInverted": simProcessor.subPolarityInverted,
                             "entered": entered] as [String: Any],
            "captureRunning": wizardCaptureRunning, "lastAcceptance": acceptanceJSON(),
            "tunerActive": tunerActive, "tunerStage": tunerStage.rawValue, "tunerNeedsMains": tunerNeedsMainsStage,
            "tuner": tunerJSON, "eqTuner": eqJSON,
            "eqReferenceCapturing": eqReferenceCapturing, "eqTunerReady": eqTuner != nil,
            "calibration": calibrationJSON(),
            "wizard": wizardJSON(),
            "exportText": exportText,
            "report": reportJSON(),
        ])
    }

    func emitLive() {
        guard let s = snapshot else {
            Out.emit("setupLive", ["running": false])
            return
        }
        func meter(_ m: ChannelMeter) -> [String: Any] {
            ["rms": num(m.rmsDBFS, 10), "peak": num(m.peakDBFS, 10), "clipped": m.clipped]
        }
        func medianCoherence(_ tf: TransferFunction?, _ band: ClosedRange<Double>) -> Double? {
            guard let tf else { return nil }
            let v = tf.frequencies.indices.filter { band.contains(tf.frequencies[$0]) && tf.coherence[$0].isFinite }
                .map { tf.coherence[$0] }.sorted()
            return v.isEmpty ? nil : v[v.count / 2]
        }
        var j: [String: Any] = [
            "running": true, "mic": meter(s.microphone), "ref": meter(s.referenceInput),
            "generator": num(s.generatorLevelDBFS, 10), "referenceDelayMs": num(s.referenceDelaySeconds * 1000, 100),
            "averages": s.transfer.map { $0.averages as Any } ?? NSNull(),
            "capture": s.capture.map { ["fraction": num($0.fraction), "label": $0.label] as [String: Any] } ?? NSNull(),
            "spl": ["laeq": num(s.soundLevel.laeq, 10), "lceq": num(s.soundLevel.lceq, 10), "lpeak": num(s.soundLevel.lpeak, 10),
                    "lmax": num(s.soundLevel.lmax, 10), "calibrated": s.soundLevel.isCalibrated] as [String: Any],
            "autoLevelRunning": s.autoLevelRunning, "discontinuities": Int(s.discontinuities),
            "stepQuality": num(medianCoherence(s.transfer, wizard.step.qualityBand(crossover: wizard.configuration.crossover))),
            "coherence": num(medianCoherence(displayTransfer, 40...16000)),
        ]
        // Live signal-to-noise against the measured room noise.
        if noiseOn, let nf = noiseFloor, let tf = s.transfer, nf.count == tf.measurementPower.count {
            let snr = SNREstimator.snr(measurementPower: tf.measurementPower, noiseFloor: nf)
            j["snr"] = num(SNREstimator.medianSNR(snr, frequencies: tf.frequencies, band: 50...12000))
        }
        if let tf = displayTransfer {
            let d = Smoothing.smooth(tf, resolution: smoothing)
            j["graph"] = [
                "mag": nums(d.frequencies.indices.map { d.isValid($0) ? Decibel.fromAmplitude(d.response[$0].magnitude) : .nan }),
                "phase": nums(d.frequencies.indices.map { d.isValid($0) ? d.response[$0].phase * 180 / .pi : .nan }),
                "coh": nums(d.coherence, 1000),
            ] as [String: Any]
            // Mini window: 1/3-octave response against the target, and the RMS deviation 63 Hz – 12.5 kHz.
            let sm = Smoothing.smooth(tf, resolution: .oct3)
            let target = wizard.configuration.target
            let idx = sm.frequencies.indices.filter { sm.frequencies[$0] >= 63 && sm.frequencies[$0] <= 12500 && sm.isValid($0) }
            var deviation: Double?
            if idx.count > 4 {
                let dv = idx.map { Decibel.fromAmplitude(sm.response[$0].magnitude) - target.value(at: sm.frequencies[$0]) }
                let m = dv.reduce(0, +) / Double(dv.count)
                deviation = (dv.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(dv.count)).squareRoot()
            }
            j["mini"] = [
                "mag": nums(sm.frequencies.indices.map { sm.isValid($0) ? Decibel.fromAmplitude(sm.response[$0].magnitude) : .nan }),
                "target": nums(sm.frequencies.map { target.value(at: $0) }),
                "deviation": num(deviation),
            ] as [String: Any]
        }
        Out.emit("setupLive", j)
    }
}

extension SetupModule: ProgressSampling {
    /// Every 5 s while signed in: time-based setup achievements read the live state (AppModel.sampleProgress).
    func sampleProgress() {
        guard let center = ProfileModule.shared, noiseOn else { return }
        center.record("setup.noiseSeconds", count: 5)
        if levelDBFS <= -79.5 { center.record("secret.quietSeconds", count: 5) }
        if let s = snapshot {
            if s.microphone.rmsDBFS > -6 { center.record("setup.micHot") }
            if let c = s.transfer?.coherence, c.count > 8 {
                let mean = c.reduce(0, +) / Double(c.count)
                if mean < 0.5 { center.record("setup.lowCoherence") }
            }
        }
    }
}
