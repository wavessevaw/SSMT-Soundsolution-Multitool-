# Codex task queue

Tasks prepared by Claude for Codex. Pick the first open one; each has its own branch, draft PR `[CODEX TASK]`
and handoff document. Claude reviews, integrates and releases.

| # | Task | Branch | Handoff | Status |
|---|---|---|---|---|
| 1 | FOH Assist: DSP performance, feedback-detector robustness, parser hardening, CI stability | `codex/assist-dsp-perf-stability` (PR #2) | `docs/handoff/codex-assist-dsp-perf-stability.md` on that branch | started (baseline commit `50afca3`), paused: Codex out of tokens |
| 2 | FOH Assist: X32 / X Air protocol conformance tests | `codex/x32-protocol-conformance` | `docs/handoff/codex-x32-protocol-conformance.md` | open |

Rules for every task: work only in the task branch; do not touch `App/**`, strings, README, release docs or
versions; report measurements and the checks that could not be run (macOS-only, real hardware).
