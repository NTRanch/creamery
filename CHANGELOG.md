# Changelog — Creamery

All notable changes, newest first. Format: Keep a Changelog.

## [1.0.0] — 2026-10-30

First playable release: the full W8 mechanism group, built and gated in
the sandbox under the Owner's v1.0 jam directive.

- **Pump-cycle rhythm core** (Zig, wasm32-freestanding): each cycle is
  a score — draw-in, counted strokes, a peak window, let-down, rest —
  across three levels (First Draw, The Morning Round, The Full Book)
  escalating in strokes and tempo against a target yield.
- **Audio-reactive sync**: the animation phase derives from a 48 kHz
  sample counter kept by the core (the sokol_audio master-clock design,
  translated to the wasm bridge) — drift is zero by construction and
  asserted per step in the test suite.
- **The Milking Pump + comfort presets (T1)**: GENTLE / STANDARD /
  DEEP trade judge window (320/260/200 ms) against yield rate;
  presets are changeable before play and queue mid-play to the next
  cycle boundary — comfort is never gated behind progression.
- **Yield measurement + charting**: exact integer accounting —
  (base + hits × per-hit) × 125% on a landed peak, × 70% partial —
  booked into an append-only chart (the book of record, stub form)
  and charted as bars on the end screens.
- **Face coupling at cycle peaks**: Alma's face (rest / warming /
  peak / afterglow keyframes over W1's transition timing table) warms
  through the strokes, peaks at the cycle peak, and glows after a
  completed cycle; posture and expression interpolate as one set.
- **Juice**: 96 ms hit-stop (master clock frozen too) and a 240 ms
  three-band flash on full let-down; reduced-flash accessibility mode.
- **Screens**: 18+ gate, title with level + preset pickers, how-to,
  gameplay, pause, settings (preset, flash, text size), victory and
  game over — both end screens chart the book of record.
- **Persistence**: settings and per-level best yield/completion
  persist in the shell (localStorage) and restore into the core at
  boot; safety and accessibility options are reachable before any play.
- **Audio**: generated WebAudio cues (the pump's own voice: stroke
  chuff, peak lift, let-down pour) answering player input only;
  nothing autoplays.
- **Previews**: `docs/previews/level-{1,2,3}-creamery.mp4`, rendered
  from the shipped core in demo mode.
- **Gates**: 17 core tests (validation + adversarial), settings-bridge
  check, performance budget (~0.03 ms/step, ~28 KB wasm), scripted
  playtest completing all three levels, D-221 frame inspection PASS.

## [0.1.0] — 2026-10-30

- Repo scaffolded 2026-10-30: bloch roadmap (kind=game, lane=restricted),
  planning, per-game skill, baseline Zig config, NTRanch-themed mdBook,
  brand assets (header + icon).
