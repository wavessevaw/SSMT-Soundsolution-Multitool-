# [CODEX TASK] FOH Assist: X32 / X Air protocol conformance tests

> **Кратко (RU).** Задача для Codex: проверить, что FOH Assist кодирует и читает параметры пульта Behringer X32 /
> Midas M32 и X Air / MR точно по открытому описанию протокола (законы фейдера, гейна, EQ, фильтра, компрессора,
> адреса, типы аргументов), покрыть это таблицами эталонных значений и исправить найденные расхождения.
> FOH Assist сейчас beta именно потому, что протокол не сверен с живым пультом — эта задача уменьшает риск.
> Работа только в этой ветке; поведение ассистента не меняется.

**Kind:** implementation task (tests first, fixes only where a test proves a mismatch).
**Branch:** `codex/x32-protocol-conformance` · **Base:** `main`.
**Order in the queue:** task 2. Task 1 is PR #2 (`codex/assist-dsp-perf-stability`). The two tasks touch different
functions of `MixerProtocol.swift` (task 1: `X32Codec.apply` clamping; task 2: encode laws and addresses). If task 1
is merged first, merge `main` into this branch before starting.
**Owner of integration / releases:** Claude (branch `claude/ssmt-acoustic-setup-wizard-mrvygi`).

## Goal

Every value FOH Assist writes to or reads from the console must match the console's own conversion, so that
"−3 dB" on screen is −3 dB on the console and a value read back is the value that was written.

## Scope

1. **Reference tables** (from the public X32 / X Air OSC documentation — e.g. Patrick-Gilles Maillot, *Unofficial
   X32/M32 OSC Remote Protocol*, and the Behringer X Air OSC parameter list). State the source and version in the
   test file header. For each law, at least 8 points including both ends:
   - fader float ↔ dB (4-segment law: −∞, −60…−30, −30…−10, −10…+10);
   - head-amp gain (X32 `/headamp/NNN/gain` −12…+60 dB; X Air `/ch/NN/preamp/gain` per its range) and trim;
   - low cut frequency (log, 20…400 Hz on X32);
   - EQ frequency (log 20 Hz…20 kHz, 201 steps), gain (−15…+15 dB), Q (10…0.3, log, 72 steps), band types;
   - compressor threshold (−60…0), ratio index table (1.1 … 100), attack, release (log), knee, makeup;
   - bus send / bus fader levels; polarity (`/ch/NN/preamp/invert`); names (`/ch/NN/config/name`, 12 chars).
2. **Tests** `Packages/SSMTCore/Tests/SSMTCoreTests/X32ProtocolConformanceTests.swift`:
   - encode: `X32Codec.messages(from:to:family:)` and `busMessages` produce the documented address, argument type
     (`f` / `i` / `s`) and value (tolerance: one console step) for every parameter, for `.x32` and `.xAir`;
   - decode: `X32Codec.apply` reads documented example packets back to the same dB/Hz values;
   - round trip: write → apply → equal within one step, over a grid of values;
   - quantisation: values written are what the console will store after snapping to its step grid (EQ frequency
     201 steps, Q 72 steps, low cut steps) — compare against the table, not against our own inverse.
3. **Fixes:** only in the encode/decode helpers of `X32Codec` (`faderDB`, `faderPosition`, `ratioIndex`, `gainValue`,
   `gainDB`, `logMap`/`linMap` users, `messages`, `busMessages`, `queryAddresses`, `busQueryAddresses`). Each fix gets
   an entry `A98+` in `docs/ASSUMPTIONS.md` (append only) citing the table.
4. **Report** in the PR: table "parameter → documented → ours → status" and the list of fixes.

## Files

**Codex may change:** the encode/decode functions of `Packages/SSMTCore/Sources/SSMTCore/Assist/MixerProtocol.swift`
listed above; new test files in `Packages/SSMTCore/Tests/SSMTCoreTests/`; `docs/ASSUMPTIONS.md` (append);
`docs/STATUS.md` (one line under function #4).

**Do not edit:** `App/**`, `scripts/strings.py`, `README.md`, release docs, `project.yml`, `ShowGuard.swift`,
`ShowRehearsal.swift`, `GroupTuning.swift`, `ChannelTuning.swift`, `AssistSession.swift`, `ConsoleTest*.swift`,
`PolarityCheck.swift`, `.github/**`. Public API must stay source-compatible.

## Definition of done

- [ ] Conformance tests with cited reference tables for X32 and X Air; all pass.
- [ ] Every mismatch found is fixed or listed as a known deviation with a reason.
- [ ] Full `SSMTCore` suite passes on Linux (`scripts/linux-swift.sh swift test --package-path Packages/SSMTCore`).
- [ ] macOS CI green on this branch.
- [ ] PR description: results table, fixes, and the checks that could not be run.

## Checks Codex cannot run — state them in the PR

- No real X32 / M32 / X Air console: conformance is against documentation, not hardware. The in-app
  «Тест пульта» on a real console remains the final check (done by the owner).
- macOS-only app build and snapshot tests run only in CI.
