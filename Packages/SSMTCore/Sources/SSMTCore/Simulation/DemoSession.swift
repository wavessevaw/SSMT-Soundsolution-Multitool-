import Foundation

extension VirtualSystem {
    /// Demo room of the app's simulation source: a deliberately misaligned sub (2.5 m closer, polarity
    /// inverted, +3 dB), coloured mains, a floor bounce and two LF modes. Gives the wizard something to fix.
    /// Shared by the macOS app and the Windows engine so both simulate the same system.
    public static func demo() -> VirtualSystem {
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

/// Runs the full setup wizard (alignment + verification + one EQ round) in simulation, synchronously.
/// Used for the screenshots of both apps (Mac snapshot tests, Windows parity fixtures).
public enum SimulatedSetupSession {
    /// The wizard after the EQ verification round, or nil if the simulation could not lock or align.
    public static func completeWizard() -> SetupWizard? {
        var system = VirtualSystem.demo()
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
        guard let d = delay else { return nil }
        w.lockDelay(d, epoch: backend.discontinuities.value)
        w.start()
        for step in [WizardStep.baseline, .subOnly, .mainsOnly] {
            guard let g = step.requiredGroups else { continue }
            backend.setActiveGroups(sub: g.sub, main: g.mains)
            run(0.5)
            if let c = capture(8, band: step.qualityBand(crossover: 90)) { w.submit(c) }
        }
        guard let a = w.alignment else { return nil }
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
