# Breakage log — Creamery

Every breakage found in playtest or build lands here with: what broke, the
evidence, the bloch attempt id, and the fix or the filed finding. Copied to
bloch at the week's close (the log is the input, bloch is the record).

## 2026-10-30 — v1.0 build (sandbox)

- **B-1: Cycle durations would have broken the sync invariant at the
  wrap.** Caught in design, before the first build: with the draft
  durations (950/850/760 ms strokes, 900/700 ms phases), a cycle is not
  a whole number of 16 ms steps, so the sample-clock-derived animation
  phase and the simulation's cycle position diverge by the remainder
  at every wrap — the exact drift the design exists to exclude. Fix:
  every duration in the cycle is a multiple of the step (strokes
  960/848/768 ms; draw-in 896, peak 704, release 1104, rest 800), the
  wrap subtracts the cycle total instead of zeroing, and a core test
  ("cycle geometry") pins the property. Sync is now exact integer
  arithmetic, asserted per step in the playthrough tests.
- **B-2: Three presentation defects found by D-221 frame inspection.**
  Frames extracted from the first preview MP4s: (1) the hanging lamps
  sat inside the HUD text block, striking through the face-state and
  preset lines; (2) the stroke-flash was a filled disc that swallowed
  the pump rig whole for its 120 ms; (3) the centred phase label ran
  across Alma's white apron and lost its last letters. Fixes: lamps
  hang only on non-play screens, the flash is a ring, and the phase
  label moved to the left column under the rig. All three previews
  re-captured and re-inspected PASS. The shipped page's canvas text
  was never mirrored or broken — these were composition defects in
  the core's draw lists, visible in both renderers.
- **B-3: Scaffold build.zig could not have shipped.** The scaffold's
  build file lacked `export_memory` (the shell reads the draw list out
  of wasm memory) and had no test step. Rewired at the v1.0 build to
  the program's standard shape (same as W1). Recorded because the
  scaffold compiled green while being unshippable — a gate that only
  compiles is not a gate.
- **B-4 (held, not a defect): seahawk playtest pass not run.** Primo is
  unreachable from the sandbox tonight (tunnel outage since 03:15 PDT).
  The sandbox automated playtest (`docs/PLAYTEST-2026-10-30.md`) is the
  record of the moment; the seahawk pass runs when primo returns.
  R-905's verify names the sandbox playtest for this reason.
- **B-5 (held, by design of the jam): GJ-07 live itch checks open.**
  The 18+ flag / content-warning / ToS verification happens live at
  entry time; the entry is not being submitted tonight. R-904 stays
  open. The game's own 18+ gate ships as the first screen regardless.
- **B-6 (design ruling): no mid-run save.** A morning's work is one
  sitting. What persists (shell localStorage): settings (preset,
  flash, text size) + per-level best yield/completion. The book of
  record is a per-sitting ledger held in the core — its persistence
  across sittings is a torogao-side question, filed in the port-back
  (the chart-entry shape is the artifact; the store is not). R-202/
  R-203 are gated on the settings bridge (`tools/settings-check.mjs`),
  and the scoping is recorded here rather than silently narrowing the
  items.
