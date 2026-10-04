# SSMT — user guide

SSMT sets up a sound system for you: it aligns the subwoofers with the mains (delay, polarity, level) and
suggests EQ over the listening area. Every check is shown as a **tuner instrument**: the needle and LEDs go
from red (far from target) to green ("IN TUNE").

## You need

- A Mac (macOS 13+), an audio interface and a **measurement** microphone (ideally with a calibration file).
- Interface output → processor input. No loopback cable: the generated signal is the reference.
- Access to the loudspeaker processor to mute groups and enter delay, polarity, level and EQ.

## Safety

- The noise starts quietly, rises at most 3 dB/s and never above the "Maximum level".
- **STOP** (red button, **Esc** anywhere, mini window button) mutes the output immediately.
- Captures with clipping are rejected.

## Setup wizard

**0. Prepare.** Choose the interface, microphone input and output (or "Simulation" to try). Put the mic at the
main listening position. Checklist: Start audio → Auto level (5 s of silence, then a slow rise to SNR ≥ 20 dB)
→ Find delay (all loudspeakers on). Describe the system (subs, crossover if known, processor steps). Start setup.

**Console / processor** ("Your system"): pick a model or "My console…" and set the maximum delay, PEQ bands on the sub and satellite outputs, gain step and how the width is set (Q or octaves). SSMT never suggests more bands than the output has and warns if a delay exceeds the console maximum.

**1. Whole system** → **2. Subs only** (mute the mains) → **3. Mains only** (mute the subs). Tiles show what must
be ON / MUTED; wait for the green "Signal quality" needle and press Capture (Return).

**4. Tuner.** The cards are the target (e.g. "+7.44 ms on the subs, Invert, −2.5 dB"). Turn the processor knobs
while watching the polarity lamp and the delay/level needles (1–2 s response). If the mains need the delay,
the sub is tuned first, then the mains delay. Ambiguous solutions are flagged with alternatives.

**5. Verify.** All loudspeakers on → Capture. "Crossover dip" (green < 3 dB) and "Matches prediction"; if not,
a concrete hint ("looks like the polarity was not changed").

**6. Zone.** EQ bands use standard centre frequencies (ISO 1/3 octave: 63, 80, 100, 125 … 10k, 12.5k, 16k) in ascending order; the target menu offers 1/6 octave or any frequency. Pick a target curve (Flat, Live/PA, Speech, Club or your own via the editor). Measure the points
shown on the map (5 by default).

**7. EQ by the needles.** Leave the mic at point 1, start the EQ tuner (6 s reference), enter the bands one by
one: band needle ("Cut 3 dB more"), overall "EQ vs plan" needle, plan/entered curves. Narrow dips and areas with
large spread between points are deliberately not corrected.

**8. EQ check** over the same points: deviation from target and quality score (a guide, not a guarantee).
At most two correction rounds in a row.

**Done.** Settings, scores, filter export (text/CSV), **PDF/PNG report**, session save (⌘S).

## Input list and stage plan (function #2)

Sidebar → "Input list & stage plan".
- **Show:** artist, event, venue, date, engineer, contact, notes — printed on every sheet.
- **Channels:** "+ Channel" (after the selection), "Template" (drums, bass, guitars, keys, vocals, BVs, playback…), stereo pair L/R, duplicate, up/down (or drag a row), delete (⌫), renumber, "Stage box…" (SB1-01, SB1-02…). The Mic / DI column suggests models; picking a condenser or active DI turns on +48 V. Problems (number or input used twice, empty source) are listed under the table.
- **Monitor mixes** and the **pull list** (mics, DIs, stands, +48 V).
- **Stage plan:** click a symbol to add it, drag it (25 cm snap), arrows nudge, ⌫ deletes; the inspector sets caption, channels/mix, rotation, size, layer. Text is its own item.
- **Export:** PDF (all sheets), PNG (input list or stage plan), CSV. File: "Save input list" (⌘S) — `.ssmtinput`; undo — ⌘Z.

## Qtrl — Show Control Center (function #3)

Sidebar → "Qtrl". Drop audio files onto the list or use "+ Audio" (⌘I). **GO** (Space) starts the cue on the playhead and moves on; double-click a row to move the playhead; **Stop all** (Esc) fades everything out, a second press cuts at once. Continue modes: wait for GO, next cue after the post-wait, next cue when this one ends. The inspector edits every setting (file region, loops, speed, level, fades, routing matrix; fade, group and control cue options). Show mode locks editing. The gear opens the output patch. "Check show" lists missing targets and files, duplicate numbers and hotkeys; missing files can be relinked from a folder. Layout as in QLab: GO, the cue standing by and its notes, Pause all and Stop all on top; the cue toolbar (edit mode); the cue list with a sidebar (Cue lists · One-shot pads on F1–F12 with start / toggle / restart / hold modes · Active cues and output meters); the inspector and, on demand, the multitrack timeline at the bottom; a status bar with Edit / Show, show name, output, pre-show check, panel toggles, OSC and settings. Groups work as a local multitrack, as in QLab: select cues and press Group to wrap them, drop files or cues on the lower part of a group row to put them inside, and use the group's Multitrack inspector tab (one track per cue, drag to move its start, Add tracks); "All together" plays them as a multitrack. QLab keyboard shortcuts (full list behind the keyboard button in the status bar): Space GO, Esc stop all, [ ] pause / resume all, P S L V on the selected cues, ↑/↓ and ⇧⌘↑/⇧⌘↓, ⌘J jump to cue, ⌘] / ⌘[ Show / Edit, ⌘I / ⌘L inspector / sidebar, ⌘1 audio ⌘0 group ⌘7 fade ⌘8 OSC, N Q E D W C T cue fields, ⌘R ⌘D ⌘C ⌘X ⌘V ⌘A ⌫; letter keys work on any layout. In a group's multitrack, drag a clip to move it, its edges to trim; clips snap (⌘: no snapping). Files: `.ssmtshow`, autosave, undo.

## FOH Assist (function #4, beta)

Sidebar → "FOH Assist". Consoles: Behringer X32 / Midas M32, Behringer X Air / Midas MR; "Simulator" works without one. Put the Mac and the console on the same router (Wi-Fi or cable). Until a console is connected the tab shows only the console choice: X32 / M32 and X Air / MR consoles are found on the network (model, IP, firmware) → Connect; if none is found, enter its IP. The assistant opens once connected; the lamp in the header is green while the console answers and red when the link is lost. Channel signal comes from the console over the network (levels and RTA) or as audio over USB / Dante; the measurement mic (any microphone of the calibration library) goes into the Mac's interface. **Soundcheck:** "Tune" a channel (gain, high-pass, EQ, compressor every 2 s until "Ready"), "Orchestra" (every musical instrument: drums, band, strings, winds, brass) / "Choir" by channel names or a channel range, "Check polarity" for mic pairs, characters Musical / Rock / Classical / Speech, "Undo all changes". **Show:** "Guard the show" — you mix, the assistant notches hall feedback, pulls a ringing monitor down and brings it back, keeps the lead clear in mass scenes and removes proximity boom, a few dB at most, and leaves alone whatever you touch; "Show simulation" demonstrates it. **Console test:** run it first on your console — it plays a made-up show, writes every parameter, reads it back and reports, muting the main output and restoring everything at the end (save a scene first, no musicians on stage). Beta: the X32 protocol comes from public documentation and is not yet verified on a live console.

## Microphone correction

Choose your microphone in the list (Prepare step or "Audio and calibration"); its response is removed from the measurement.

- **Your calibration files** — "Import calibration file…" ("frequency dB [phase]", "Sens Factor" headers accepted). Most accurate.
- **Built-in typical profiles** (22 models: measurement mics, Shure SM81, Soyuz 011/013 FET, Soyuz 022 Bomblet, AKG C414 XLII/XLS, Neumann KM 184 / U 87 Ai, RØDE, Oktava MK-012, SM57/SM58 and more) — the model's response from published charts, ±2–3 dB, mostly at high frequencies.
- Cardioid studio microphones read the top end lower in a room than on axis; an omni measurement mic gives a more honest EQ. Any of them is fine for sub/mains alignment.

## Shortcuts

Esc STOP · Space noise · Return capture · ⌘D find delay · ⌘B start setup · ⌘1 wizard · ⌘E expert ·
⌘L stage · ⇧⌘M mini window · ⌘S/⌘O session · ⇧⌘P PDF report.
