import AppKit
import AVFoundation
import Foundation
import SSMTAudio
import SSMTCore
import SwiftUI

/// Signal source for the measurement session.
enum SignalSource: Hashable {
    case simulation
    /// One duplex interface.
    case device(uid: String)
    /// Microphone and output on different interfaces → private aggregate device (drift-compensated).
    case split(inputUID: String, outputUID: String)
}

enum AutoLevelState: Equatable {
    case idle
    case measuringNoise
    case raising
    case done(AutoLevelController.Outcome, level: Double)
}

/// Noise types offered in the UI (index into the generator bank).
enum NoiseChoice: Int, CaseIterable, Identifiable {
    case pink = 0, white = 1, periodicPink = 2
    var id: Int { rawValue }
    var key: String {
        switch self {
        case .pink: return "noise.pink"
        case .white: return "noise.white"
        case .periodicPink: return "noise.periodic"
        }
    }
}

/// Top-level functions of the app.
enum AppSection: String, CaseIterable, Identifiable {
    /// Function #1: automatic system setup.
    case setup
    /// Function #2: input list and stage plan.
    case inputList
    /// Function #3: Qtrl, show control center.
    case show
    /// Function #4: FOH Assist, automatic channel and group tuning on the console.
    case assist
    /// Function #5: handbook — calculators, pinouts, how-to guides, consoles, glossary.
    case handbook
    var id: String { rawValue }
}

enum AppMode: String, CaseIterable, Identifiable {
    case wizard, expert
    var id: String { rawValue }
}

enum GraphKind: String, CaseIterable, Identifiable {
    case magnitude, phase, coherence
    var id: String { rawValue }
}

/// Application state. The measurement engine lives here (not in a view), so minimizing or
/// closing windows never interrupts averaging.
@MainActor
final class AppModel: ObservableObject {
    // Setup
    @Published var devices: [AudioDeviceInfo] = []
    @Published var source: SignalSource = .simulation
    @Published var microphoneChannel = 0
    @Published var referenceChannel = 1
    @Published var outputChannel = 0
    @Published var referenceMode: ReferenceMode = .internalSignal
    @Published var temperatureCelsius: Double = 20

    // Generator
    @Published var noise: NoiseChoice = .pink
    @Published var levelDBFS: Double = -40
    @Published var maximumLevelDBFS: Double = -12
    @Published private(set) var noiseOn = false

    // Live state
    @Published private(set) var isRunning = false
    /// Live snapshot, stored in `live` so it does not invalidate every view of the model.
    let live = LiveData()
    private(set) var snapshot: LiveSnapshot? {
        get { live.snapshot }
        set { live.snapshot = newValue }
    }
    @Published private(set) var delay: DelayEstimate?
    @Published private(set) var delaySearchRunning = false
    @Published var lastError: String?
    @Published private(set) var microphonePermission: AVAuthorizationStatus = .notDetermined

    // Calibration
    @Published private(set) var calibration = CalibrationLibrary.load()
    @Published private(set) var autoLevelState: AutoLevelState = .idle
    @Published private(set) var noiseFloor: [Double]?

    // Wizard
    @Published var appMode: AppMode = .wizard
    @Published var wizard = SetupWizard()
    @Published private(set) var wizardCaptureRunning = false
    @Published private(set) var wizardDelaySearch = false
    @Published private(set) var lastAcceptance: CaptureAcceptance?
    @Published private(set) var simulationSettingsApplied = false

    // Tuner (live alignment needle)
    @Published private(set) var tunerActive = false
    @Published private(set) var tunerStage: AlignmentTuner.Stage = .adjustSub
    /// Tuner readings, stored in `tuning` (see `LiveData`).
    let tuning = TuningData()
    private(set) var tunerReading: AlignmentTuner.Reading? {
        get { tuning.alignment }
        set { tuning.alignment = newValue }
    }
    /// Virtual processor knobs (simulation only) — turned by the user like a real processor.
    @Published var simProcessor = VirtualProcessorSettings() {
        didSet {
            simulationBackend?.setProcessor(simProcessor)
            // The simulated knob change is known exactly: restart averaging so the needle reacts fast.
            if tunerActive { engine?.resetLiveAverages() }
        }
    }
    private var tuner: AlignmentTuner?
    private var lastTunerUpdate = Date.distantPast
    /// A tuner reading is being computed off the main thread; new snapshots are skipped meanwhile.
    private var tunerBusy = false

    // EQ tuner
    private(set) var eqTunerReading: EQTuner.Reading? {
        get { tuning.eq }
        set { tuning.eq = newValue }
    }
    @Published private(set) var eqReferenceCapturing = false
    @Published var eqSelectedBand = 0
    private var eqTuner: EQTuner?

    // Display
    @Published var smoothing: SmoothingResolution = .oct12
    @Published var coherenceThreshold: Double = 0.6
    @Published var visibleGraphs: Set<GraphKind> = [.magnitude, .phase, .coherence]
    @Published var stageMode = false
    @Published var section: AppSection = .setup
    /// Function #2 document (input list + stage plan).
    let inputList = InputListStore()
    /// Function #3 document and player (audio output starts when the section is first opened).
    let show = ShowStore(startAudio: false)
    /// Function #4 (console link and audio input start on Connect).
    let assist = AssistStore()
    /// Reduced graphics effects (automatic on Intel / low-core Macs; see `GraphicsQuality`).
    @Published var reducedEffects = GraphicsQuality.initialReduced {
        didSet { UserDefaults.standard.set(reducedEffects, forKey: GraphicsQuality.defaultsKey) }
    }
    /// Audio and calibration settings sheet (wizard mode).
    @Published var showSettings = false

    // Simulation controls (stand-in for muting groups on the processor)
    @Published var simulationSubOn = true { didSet { applySimulationGroups() } }
    @Published var simulationMainOn = true { didSet { applySimulationGroups() } }

    private(set) var engine: MeasurementEngine?
    private var simulationBackend: SimulatedAudioBackend?
    private var aggregate: AggregateDevice?

    init() {
        refreshDevices()
        microphonePermission = AVCaptureDevice.authorizationStatus(for: .audio)
        // FOH Assist measures with any microphone of the function #1 library and its SPL calibration.
        assist.micLibrary = { [weak self] in
            (self?.calibration.microphones ?? [], self?.calibration.selectedMicrophoneID, self?.calibration.spl)
        }
    }

    var selectedDevice: AudioDeviceInfo? {
        switch source {
        case .device(let uid): return devices.first { $0.uid == uid }
        default: return nil
        }
    }

    var inputDevice: AudioDeviceInfo? {
        switch source {
        case .device(let uid), .split(let uid, _): return devices.first { $0.uid == uid }
        case .simulation: return nil
        }
    }

    var outputDevice: AudioDeviceInfo? {
        switch source {
        case .device(let uid), .split(_, let uid): return devices.first { $0.uid == uid }
        case .simulation: return nil
        }
    }

    var isSplitSource: Bool {
        if case .split = source { return true }
        return false
    }

    var safety: GeneratorSafety {
        var s = GeneratorSafety()
        s.maximumLevelDBFS = maximumLevelDBFS
        return s
    }

    func refreshDevices() {
        devices = DeviceCatalog.allDevices().filter { $0.inputChannels > 0 || $0.outputChannels > 0 }
    }

    // MARK: - Engine lifecycle

    func startEngine() {
        guard !isRunning else { return }
        lastError = nil
        let backend: AudioIOBackend
        switch source {
        case .simulation:
            let sim = SimulatedAudioBackend(system: Self.demoSystem(), deviceLatency: 512, safety: safety)
            simulationBackend = sim
            backend = sim
            applySimulationGroups()
        case .device, .split:
            guard microphonePermission == .authorized else {
                requestMicrophoneAccess()
                return
            }
            do {
                backend = try makeHardwareBackend()
            } catch {
                aggregate = nil
                lastError = String(describing: error)
                return
            }
            simulationBackend = nil
        }
        var config = MeasurementEngine.Configuration()
        config.referenceMode = referenceMode
        let engine = MeasurementEngine(backend: backend, configuration: config)
        engine.setSnapshotHandler { [weak self] snap in
            Task { @MainActor in self?.receive(snap) }
        }
        do {
            try engine.start()
        } catch {
            lastError = String(describing: error)
            return
        }
        engine.setSPLCalibration(calibration.spl)
        self.engine = engine
        isRunning = true
        delay = nil
        noiseFloor = nil
        autoLevelState = .idle
        simulationSettingsApplied = false
        simProcessor = VirtualProcessorSettings()
        stopTuner()
        wizard = SetupWizard(configuration: wizard.configuration)
    }

    private func receive(_ snap: LiveSnapshot) {
        guard isRunning else { return }
        // The interface stopped delivering audio (unplugged, driver stopped): stop cleanly
        // instead of waiting forever in a capture.
        if snap.secondsSinceAudio > 1.5 {
            handleAudioLoss()
            return
        }
        snapshot = snap
        guard let tf = snap.transfer, !tunerBusy, snap.timestamp.timeIntervalSince(lastTunerUpdate) >= 0.25 else { return }
        // Tuner readings run the full alignment / EQ comparison: computed off the main thread so the
        // interface stays fluid on older Macs; a new reading starts only when the previous one is done.
        if tunerActive, let tuner {
            lastTunerUpdate = snap.timestamp
            tunerBusy = true
            Task.detached(priority: .userInitiated) { [weak self] in
                let reading = tuner.read(live: tf)
                await MainActor.run {
                    guard let self else { return }
                    self.tunerBusy = false
                    if self.tunerActive, self.tuner?.stage == tuner.stage { self.tunerReading = reading }
                }
            }
        } else if let eqTuner {
            lastTunerUpdate = snap.timestamp
            tunerBusy = true
            Task.detached(priority: .userInitiated) { [weak self] in
                let reading = eqTuner.read(live: tf)
                await MainActor.run {
                    guard let self else { return }
                    self.tunerBusy = false
                    if self.eqTuner != nil { self.eqTunerReading = reading }
                }
            }
        }
    }

    private func handleAudioLoss() {
        wizardCancelCapture()
        stopEQTuner()
        stopTuner()
        stopEngine()
        // A localization key; the error banner translates keys starting with "error.".
        lastError = "error.audioLost"
    }

    private func makeHardwareBackend() throws -> AudioIOBackend {
        let refChannel = referenceMode == .internalSignal ? nil : referenceChannel
        switch source {
        case .device(let uid):
            return try HALAudioBackend(routing: HALRouting(deviceUID: uid, microphoneChannel: microphoneChannel,
                                                           referenceChannel: refChannel,
                                                           outputChannels: [outputChannel]), safety: safety)
        case .split(let inUID, let outUID):
            let agg = try AggregateDevice(inputUID: inUID, outputUID: outUID)
            aggregate = agg
            return try HALAudioBackend(
                routing: HALRouting(deviceUID: agg.uid,
                                    microphoneChannel: agg.inputChannelOffset + microphoneChannel,
                                    referenceChannel: refChannel.map { agg.inputChannelOffset + $0 },
                                    outputChannels: [agg.outputChannelOffset + outputChannel]),
                safety: safety)
        case .simulation:
            fatalError("not a hardware source")
        }
    }

    func stopEngine() {
        // Nothing that waits for audio may stay "running" once the audio is gone.
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
        aggregate = nil
        isRunning = false
        noiseOn = false
        snapshot = nil
        autoLevelState = .idle
    }

    // MARK: - Generator

    func setNoise(on: Bool) {
        guard let engine else { return }
        let c = engine.backend.generatorControl
        c.kindIndex.value = UInt64(noise.rawValue)
        c.targetLevelDBFS.value = Float(min(levelDBFS, maximumLevelDBFS))
        c.run.value = on
        noiseOn = on
    }

    func toggleNoise() {
        if !isRunning { startEngine() }
        setNoise(on: !noiseOn)
    }

    func applyLevel() {
        engine?.backend.generatorControl.targetLevelDBFS.value = Float(min(levelDBFS, maximumLevelDBFS))
    }

    func applyNoiseKind() {
        engine?.backend.generatorControl.kindIndex.value = UInt64(noise.rawValue)
    }

    /// STOP: mutes the output on the next audio buffer, from any state.
    func emergencyStop() {
        engine?.emergencyStop()
        noiseOn = false
    }

    // MARK: - Measurement

    func findDelay() {
        guard let engine, noiseOn else { return }
        delaySearchRunning = true
        engine.findDelay(seconds: 3) { [weak self] estimate in
            Task { @MainActor in
                self?.delay = estimate
                self?.delaySearchRunning = false
            }
        }
    }

    /// Measures the room noise (generator silent), then raises the level until SNR ≥ 20 dB
    /// or the user maximum is reached.
    func runAutoLevel() {
        guard let engine else { return }
        autoLevelState = .measuringNoise
        noiseOn = false
        engine.measureNoiseFloor(seconds: 5) { [weak self] floor in
            Task { @MainActor in
                guard let self, let engine = self.engine else { return }
                self.noiseFloor = floor
                self.autoLevelState = .raising
                self.noiseOn = true
                var settings = AutoLevelController.Settings()
                settings.maximumLevelDBFS = self.maximumLevelDBFS
                engine.runAutoLevel(settings: settings, noiseFloor: floor) { level, outcome in
                    Task { @MainActor in
                        self.levelDBFS = level
                        self.autoLevelState = .done(outcome, level: level)
                        if outcome == .clipped { self.noiseOn = true }
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

    // MARK: - Calibration

    func importMicrophoneCalibration(from url: URL) {
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let mic = try MicrophoneCalibration.parse(text, name: url.deletingPathExtension().lastPathComponent)
            calibration.microphones.append(mic)
            calibration.selectedMicrophoneID = mic.id
            calibration.save()
        } catch {
            lastError = "\(url.lastPathComponent): \(error)"
        }
    }

    func selectMicrophone(_ id: UUID?) {
        calibration.selectedMicrophoneID = id
        calibration.save()
    }

    func removeMicrophone(_ id: UUID) {
        calibration.microphones.removeAll { $0.id == id }
        if calibration.selectedMicrophoneID == id { calibration.selectedMicrophoneID = nil }
        calibration.save()
    }

    func setSPLCalibration(dBFSAt94: Double?) {
        calibration.spl = dBFSAt94.map { SPLCalibration(dBFSAt94dBSPL: $0) }
        calibration.save()
        engine?.setSPLCalibration(calibration.spl)
        engine?.resetSoundLevel()
    }

    /// Uses the current microphone RMS (calibrator on the mic, test signal off) as the reference.
    func calibrateWithCalibrator(level: Double) {
        guard let rms = snapshot?.microphone.rmsDBFS, rms > -100 else { return }
        emergencyStop()
        let c = SPLCalibration.fromCalibrator(measuredDBFS: rms, calibratorSPL: level)
        setSPLCalibration(dBFSAt94: c.dBFSAt94dBSPL)
    }

    func resetSoundLevel() { engine?.resetSoundLevel() }

    /// Transfer function for display: microphone response removed when a calibration is selected.
    var displayTransfer: TransferFunction? {
        guard let tf = snapshot?.transfer else { return nil }
        return calibration.selectedMicrophone?.apply(to: tf) ?? tf
    }

    // MARK: - Wizard

    var isSimulation: Bool { source == .simulation }

    /// Step 0: finds and locks the delay on the full system (noise must be on).
    func wizardLockDelay() {
        guard let engine else { return }
        if !noiseOn { setNoise(on: true) }
        wizardDelaySearch = true
        engine.findDelay(seconds: 3) { [weak self] estimate in
            let epoch = engine.backend.discontinuities.value
            Task { @MainActor in
                guard let self else { return }
                self.wizardDelaySearch = false
                self.delay = estimate
                if let e = estimate, e.isReliable { self.wizard.lockDelay(e, epoch: epoch) }
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

    /// Captures the current step with the step's quality band; the wizard decides acceptance.
    func wizardCapture() {
        guard let engine, wizard.step.requiredGroups != nil, !wizardCaptureRunning else { return }
        if !noiseOn { setNoise(on: true) }
        wizardCaptureRunning = true
        lastAcceptance = nil
        let step = wizard.step
        engine.capture(label: "\(step)", duration: wizard.configuration.captureSeconds,
                       qualityBand: step.qualityBand(crossover: wizard.configuration.crossover)) { [weak self] capture in
            Task { @MainActor in
                guard let self else { return }
                self.wizardCaptureRunning = false
                self.lastAcceptance = self.wizard.submit(capture)
                if case .accepted = self.lastAcceptance, self.isSimulation {
                    self.simulateGroupsForStep()
                    if step == .eqPoints || step == .eqVerification { self.simulateMoveToNextPoint() }
                }
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
        let config = wizard.configuration
        wizard = SetupWizard(configuration: config)
        if let d = delay, d.isReliable, let engine {
            wizard.lockDelay(d, epoch: engine.backend.discontinuities.value)
        }
    }

    // MARK: - Tuner

    /// Whether the mains need a second tuner stage (the subs arrive late).
    var tunerNeedsMainsStage: Bool { wizard.alignment?.delayTarget == .mains }

    /// Starts the live needle: all groups on, mains are the fixed reference, the user turns the sub knobs.
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
        }
        engine.setLiveAveraging(seconds: 1.0)
        engine.resetLiveAverages()
    }

    /// Sub is done; it becomes the fixed reference and the needle now shows the mains delay.
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

    // MARK: - EQ steps

    func wizardBeginEQ() {
        stopTuner()
        lastAcceptance = nil
        wizard.beginEQ()
        if isSimulation { simulateGroupsForStep(); simulationBackend?.moveMicrophone(toPoint: 0) }
    }

    /// Simulation only: move the virtual microphone to the next point to measure.
    func simulateMoveToNextPoint() {
        let index = wizard.step == .eqVerification ? wizard.eqVerificationPoints.count : wizard.eqPoints.count
        simulationBackend?.moveMicrophone(toPoint: index)
        engine?.resetLiveAverages()
    }

    func wizardComputeEQ() {
        lastAcceptance = nil
        wizard.computeEQ(microphone: calibration.selectedMicrophone)
        eqSelectedBand = 0
        if isSimulation { simulationBackend?.moveMicrophone(toPoint: 0) }
    }

    /// EQ tuner: captures a short reference at the current microphone position (nothing entered yet),
    /// then compares the live response with it to show what has been entered on the processor.
    func startEQTuner() {
        guard let engine, let r = wizard.eqResult, !eqReferenceCapturing else { return }
        if !noiseOn { setNoise(on: true) }
        eqReferenceCapturing = true
        eqTuner = nil
        eqTunerReading = nil
        engine.setLiveAveraging(seconds: 1.0)
        engine.capture(label: "eq-reference", duration: 6) { [weak self] c in
            Task { @MainActor in
                guard let self else { return }
                self.eqReferenceCapturing = false
                self.eqTuner = EQTuner(reference: c.transfer, filters: r.filters, workingRange: r.workingRange)
                self.engine?.resetLiveAverages()
            }
        }
    }

    var eqTunerReady: Bool { eqTuner != nil }

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
        eqSelectedBand = 0
        if isSimulation { simulationBackend?.moveMicrophone(toPoint: 0) }
    }

    func wizardFinish() {
        stopEQTuner()
        wizard.finish()
    }

    /// Simulation only: enter (or remove) one planned EQ band on the virtual processor, exactly.
    func simulateToggleBand(_ filter: PEQFilter) {
        var p = simProcessor
        if filter.group == .sub {
            if let i = p.subEQ.firstIndex(where: { $0.id == filter.id }) { p.subEQ.remove(at: i) } else { p.subEQ.append(filter) }
        } else {
            if let i = p.mainsEQ.firstIndex(where: { $0.id == filter.id }) { p.mainsEQ.remove(at: i) } else { p.mainsEQ.append(filter) }
        }
        simProcessor = p
    }

    func simulatedBandEntered(_ filter: PEQFilter) -> PEQFilter? {
        (simProcessor.subEQ + simProcessor.mainsEQ).first { $0.id == filter.id }
    }

    /// Simulation only: change the gain of an entered band (to watch the needle move).
    func simulateSetBandGain(_ filter: PEQFilter, gain: Double) {
        var p = simProcessor
        if let i = p.subEQ.firstIndex(where: { $0.id == filter.id }) { p.subEQ[i].gainDB = gain }
        if let i = p.mainsEQ.firstIndex(where: { $0.id == filter.id }) { p.mainsEQ[i].gainDB = gain }
        simProcessor = p
    }

    // MARK: - Report & session

    var interfaceName: String {
        switch source {
        case .simulation: return "Simulation"
        default: return inputDevice?.name ?? "—"
        }
    }

    var setupReport: SetupReport {
        SetupReport(wizard: wizard, interfaceName: interfaceName, sampleRate: 48000,
                    microphone: calibration.selectedMicrophone)
    }

    func exportReport(pdf: Bool, localizer: Localizer) {
        let view = ReportView(report: setupReport, wizard: wizard).ssmtEnvironment(self, localizer)
        do { try ReportExporter.export(view, pdf: pdf) } catch { lastError = error.localizedDescription }
    }

    func copyReportText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(setupReport.plainText, forType: .string)
    }

    func saveSession() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "SSMT-session.ssmtsession"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let file = SessionFile(wizard: wizard, interfaceName: interfaceName, sampleRate: 48000,
                               microphoneCalibrationName: calibration.selectedMicrophone?.name,
                               appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")
        do { try file.encoded().write(to: url, options: .atomic) } catch { lastError = error.localizedDescription }
    }

    func openSession() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let file = try SessionFile.decode(Data(contentsOf: url))
            stopTuner()
            stopEQTuner()
            wizard = file.wizard
            appMode = .wizard
        } catch {
            lastError = "\(url.lastPathComponent): \(error)"
        }
    }

    // MARK: - Export

    var exportText: String {
        PEQExport.filterSettingsText(wizard.enteredFilters.isEmpty ? (wizard.eqResult?.filters ?? []) : wizard.enteredFilters,
                                     title: "SSMT Filter Settings · \(wizard.configuration.processor.name)",
                                     widthInOctaves: wizard.configuration.processor.bandwidthInOctaves)
    }
    var exportCSV: String { PEQExport.csv(wizard.enteredFilters.isEmpty ? (wizard.eqResult?.filters ?? []) : wizard.enteredFilters) }

    func saveExport(csv: Bool) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = csv ? "SSMT-filters.csv" : "SSMT-filters.txt"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try (csv ? exportCSV : exportText).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func copyExportToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(exportText, forType: .string)
    }

    /// Simulation only: mute/unmute the virtual groups as the current step asks the user to.
    func simulateGroupsForStep() {
        guard isSimulation, let g = wizard.step.requiredGroups else { return }
        simulationSubOn = g.sub
        simulationMainOn = g.mains
    }

    /// Simulation only: enter the recommendation on the virtual processor (once).
    func simulateApplyRecommendation() {
        guard isSimulation, !simulationSettingsApplied, let a = wizard.alignment else { return }
        var p = simProcessor
        if a.roundedDelay >= 0 { p.subDelayMs += a.roundedDelay * 1000 } else { p.mainsDelayMs -= a.roundedDelay * 1000 }
        if a.best.invertPolarity { p.subPolarityInverted.toggle() }
        p.subGainDB += a.subGainDB
        simProcessor = p
        simulationSettingsApplied = true
    }

    func setReferenceMode(_ mode: ReferenceMode) {
        referenceMode = mode
        engine?.setReferenceMode(mode)
    }

    func resetAverages() { engine?.resetLiveAverages() }
    func resetClips() { engine?.resetClipIndicators() }

    func requestMicrophoneAccess() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in
                self.microphonePermission = granted ? .authorized : .denied
                if granted { self.startEngine() }
            }
        }
    }

    // MARK: - Simulation

    private func applySimulationGroups() {
        simulationBackend?.setActiveGroups(sub: simulationSubOn, main: simulationMainOn)
    }

    /// Demo room with a deliberately misaligned sub (2.5 m closer, polarity inverted, +3 dB),
    /// coloured mains, a floor bounce and two LF modes — gives the wizard something to fix.
    static func demoSystem() -> VirtualSystem {
        let fs = 48000.0
        let room = VirtualRoom(
            reflections: [VirtualReflection(delaySamples: 168, gain: 0.35),
                          VirtualReflection(delaySamples: 1900, gain: 0.2)],
            modes: [Biquad.design(.peaking, frequency: 63, q: 6, gainDB: 7, sampleRate: fs),
                    Biquad.design(.peaking, frequency: 160, q: 5, gainDB: 4, sampleRate: fs)])
        var sys = VirtualSystem.typicalPA(sampleRate: fs, crossover: 90, subDistance: 7, mainDistance: 9.5,
                                          subGainDB: 3, subInverted: true, room: room, micNoiseDBFS: -75)
        // Mains with a honky mid and a bright top, so the EQ steps have something to correct.
        sys.main.filters += [Biquad.design(.peaking, frequency: 1800, q: 1.2, gainDB: 5, sampleRate: fs),
                             Biquad.design(.peaking, frequency: 9000, q: 0.8, gainDB: 3, sampleRate: fs)]
        return sys
    }
}
