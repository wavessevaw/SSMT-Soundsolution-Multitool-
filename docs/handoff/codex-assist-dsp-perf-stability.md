# [CODEX TASK] FOH Assist: DSP performance, feedback-detector robustness, parser hardening, CI stability

> **Кратко (RU).** Задача на реализацию для Codex: ускорить анализ сигнала и симулятор FOH Assist (с замерами до/после),
> проверить детектор акустической обратной связи на наборе тестовых сигналов (ложные срабатывания / пропуски),
> защитить разбор OSC и метров пульта от повреждённых данных, устранить гонку при записи эталонных снимков в CI.
> Поведение ассистента не меняется, существующие тесты должны проходить. Работа — только в этой ветке.

**Kind:** implementation task — Codex adds code and tests to this branch (`codex/assist-dsp-perf-stability`).
**Base commit:** `bf04f9a33b89a55354ebb144f6942d608c6d9363` (`main`, after merge of PR #1 and README edits).
**Owner of the overall product / integration / releases:** Claude (branch `claude/ssmt-acoustic-setup-wizard-mrvygi`).

## Goal

FOH Assist (function #4) is functionally complete in beta. Its core runs in `Packages/SSMTCore` and is fully testable
on Linux. This task makes it faster, more robust and better tested **without changing its intended behaviour**.

## Scope

### 1. Performance (must be backed by measurements)

Hot paths:

| Path | File | Called |
|---|---|---|
| `FeatureExtractor.analyze(_:gateDB:)` | `Packages/SSMTCore/Sources/SSMTCore/Assist/SignalFeatures.swift` | every 1–2 s per channel (up to 32 ch) |
| `FeedbackDetector.process(_:)`, `analyzeFrame`, `hasHarmonics` | `.../Assist/FeedbackDetector.swift` | every window on the measurement mic |
| `SimulatedConsole.render(seconds:channels:tap:)`, `synth`, `filter` | `.../Assist/SimulatedConsole.swift` | every step in simulator, console test, show simulation, tests |

Baseline (Linux, Docker `swift:6.0-noble`, **debug** build, measured by Claude on this commit — re-measure on your
machine before changing anything and report both):

| Suite | Tests | Wall time |
|---|---|---|
| `AssistTests` | 11 | ≈ 54 s |
| `PolarityTests` | 6 | ≈ 70 s |
| `ShowRehearsalTests` | 1 | ≈ 107 s |
| `ConsoleTestTests` | 2 | ≈ 23 s |
| `PerformanceTests.testAnalyzerIsFarFasterThanRealTime` (not FOH Assist) | 1 | 246 ms vs 200 ms limit in a loaded container — borderline, passes on CI |

Required:
- Add a benchmark (an XCTest that measures and prints ms per call, e.g. `AssistPerformanceTests`) for the three hot
  paths with fixed inputs: 2 s × 48 kHz window for `analyze`, 1 s mic block for `process`, 16 channels × 1 s for
  `render`. Report **before / after** numbers (median of ≥ 5 runs, release and debug) in the PR description.
- Targets: `analyze` ≥ 2× faster in release; `render` ≥ 2× faster; total time of the four suites above ≥ 40 % lower in
  debug. If a target cannot be met, report what was measured and why.
- Allowed techniques: reuse buffers (no per-call allocation of FFT/window arrays), precomputed tables, vDSP behind
  `#if canImport(Accelerate)` with the portable path kept for Linux, cheaper loops in `filter`/`synth`.
- Results must stay numerically equivalent: features within 0.1 dB / 0.5 % of the current implementation on the
  benchmark inputs (add a test that pins this against stored reference values computed **before** the change).

### 2. Feedback detector robustness (tests first, fixes only if tests show a problem)

Build a deterministic test corpus (synthetic, seeded) and measure detection:
- **Must not trigger (music):** sustained notes with vibrato (0.5–2 %), crescendo 6–14 dB over 2–4 s, chords,
  organ/pad with weak vibrato, choir (4 detuned voices), sung vowel with formants, cymbals/noise.
- **Must trigger (feedback):** a pure tone appearing 15–30 dB above the spectrum and growing 10–40 dB/s, at
  250 Hz…8 kHz; also a steady pure tone holding ≥ 1.5 s.
- Report a table: case → detected / not, time to detection. Goal: 0 false positives on the music set, ≥ 95 %
  detection on the feedback set, detection ≤ 1 s for growth ≥ 15 dB/s.
- If you change thresholds or rules in `FeedbackDetector`, all existing tests must still pass, in particular
  `ShowRehearsalTests.testWholeShowEngineerRidesAndGuardReacts` and `ShowGuardTests`, and document the change in
  `docs/ASSUMPTIONS.md` (a new `A98+` entry; do not edit existing entries).

### 3. Parser hardening

- `OSCMessage.decode` (`Packages/SSMTCore/Sources/SSMTCore/Show/OSC.swift`) and `ConsoleMeters.decode`
  (`.../Assist/ConsoleMeters.swift`) must never crash or read out of bounds on truncated, oversized or random data
  (they receive UDP packets from the network). Add fuzz-style tests (seeded random bytes, truncated valid packets,
  wrong blob lengths, negative/huge counts) — expected result `nil` or a well-formed value, never a trap.
- `X32Codec.apply` (`.../Assist/MixerProtocol.swift`): out-of-range values (NaN, ±inf, < 0, > 1) must be clamped,
  not propagated. Only the parsing functions may change in this file.

### 4. CI stability

`.github/workflows/ci.yml`, step **"Record missing snapshot references"**: when another commit lands on the branch
during a run, `git push` is rejected and the whole job turns red although all tests passed. Make the step robust:
`git pull --rebase` (or fetch + rebase) and retry the push a few times; if it still cannot push, emit a warning and
**do not fail the job**. The step must not run on tag pushes or `workflow_dispatch` release runs (it must never
push to a tag). Do not change any other step.

## Files

**Codex may change:**
- `Packages/SSMTCore/Sources/SSMTCore/Assist/SignalFeatures.swift`
- `Packages/SSMTCore/Sources/SSMTCore/Assist/FeedbackDetector.swift`
- `Packages/SSMTCore/Sources/SSMTCore/Assist/SimulatedConsole.swift`
- `Packages/SSMTCore/Sources/SSMTCore/Assist/ConsoleMeters.swift` (decode only)
- `Packages/SSMTCore/Sources/SSMTCore/Assist/MixerProtocol.swift` (`X32Codec.apply` clamping only)
- `Packages/SSMTCore/Sources/SSMTCore/Show/OSC.swift` (`decode` only)
- new test files in `Packages/SSMTCore/Tests/SSMTCoreTests/` (e.g. `AssistPerformanceTests.swift`,
  `FeedbackCorpusTests.swift`, `ParserFuzzTests.swift`)
- `.github/workflows/ci.yml` (the one step above)
- `docs/ASSUMPTIONS.md` (append only), `docs/STATUS.md` (append a short line under function #4)

**Claude is changing at the same time (do not edit):**
- everything under `App/` (UI wording, FOH Assist screens), `scripts/strings.py`, `App/SSMT/Resources/Localizable.xcstrings`
- `README.md`, `docs/RELEASE_NOTES.md`, `docs/CHANGELOG.md`, `docs/USER_GUIDE.*.md`, `docs/INSTALL.md`
- `Packages/SSMTCore/Sources/SSMTCore/Assist/ShowGuard.swift`, `ShowRehearsal.swift`, `GroupTuning.swift`,
  `ChannelTuning.swift`, `AssistSession.swift`, `ConsoleTest*.swift`, `PolarityCheck.swift`
- `project.yml`, version numbers, release tags

Public API of the files Codex changes must stay source-compatible (the app and the files above use it).

## Definition of done

- [ ] Benchmarks added; before/after table (release + debug, median of ≥ 5 runs, machine/OS stated) in the PR.
- [ ] Numerical-equivalence test passes (pinned reference values recorded before the optimisation).
- [ ] Feedback corpus test added; results table in the PR; goals met or deviations explained.
- [ ] Fuzz tests for `OSCMessage.decode`, `ConsoleMeters.decode`, `X32Codec.apply` added and passing.
- [ ] CI record step no longer fails the job on a rejected push; never runs on tags / release dispatch.
- [ ] Full `SSMTCore` suite passes on Linux:
      `swift test --package-path Packages/SSMTCore` (or `scripts/linux-swift.sh swift test ...`).
- [ ] macOS CI (Accelerate backend, app build, snapshot tests) green on this branch.
- [ ] No changes outside the "Codex may change" list.

## Checks Codex cannot run — state them explicitly in the PR

- macOS-only paths (Accelerate/vDSP, the app, snapshot tests) can only be verified by the macOS CI job.
- Real-hardware behaviour (X32/X Air consoles, measurement microphones, a real room) is **not** covered by these
  tests; say so in the PR rather than implying it.

## Dependencies

- Independent of Claude's current work (release 1.2.0, UI terminology). Can be merged before or after it.
- If detector thresholds change, the FOH Assist snapshot references (`App/Tests/Snapshots/References/assist*.png`)
  may need re-recording: CI records missing references, so Claude will delete them when integrating if they differ.
- Claude reviews, runs the full test suite against the integration branch, merges, then prepares the next release.
