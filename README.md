> **Game page:** the full storefront page for this game lives at [docs/GAME-PAGE.md](docs/GAME-PAGE.md).

# Creamery

**Nice Thoughts Ranch** · Torogao Jam Program week 8 (Wave B — Sound) · Alma · **Zig**

A rhythm game on her signature tool.

An 18+ game built for the weekly Gameotron jam on itch.io (NTRanch), as one
rung of the 14-week Torogao system-validation program (D-333/D-334/D-335/D-336).
The full planning book lives in [`book/`](book/) (mdBook, NTRanch theme);
this repo's bloch roadmap is [`.ai/roadmap.md`](.ai/roadmap.md).

- **Delivery:** one self-contained `index.html` (see `docs` in the book).
- **Cast/art law (D-292):** existing keeper art only; a missing asset is an
  abstract stand-in, logged — never a generation job.
- **Quality bar:** Laplace3D-class animation or the medium's equivalent
  (book chapter: Quality Bar).
- **Audio:** nothing is ever played aloud by an agent; the Owner presses play.

## Play

Open [`web/index.html`](web/index.html) in a browser — it runs fully
offline. The pump runs in cycles: it draws in, counts its strokes, and
opens a peak window at the top. Tap (click or SPACE) on each stroke
beat and again on the peak. Hit strokes fill the cycle; a hit peak lets
the whole cycle down at full rate. Every cycle is written into the book
of record — reach the target yield before the morning's time runs out.

- **Level 1 — First Draw:** learn the cycle (4 strokes at 960 ms, target 150 ml).
- **Level 2 — The Morning Round:** the full round (5 strokes at 848 ms, target 240 ml).
- **Level 3 — The Full Book:** the fastest tempo (6 strokes at 768 ms, target 400 ml).

The pump's comfort presets trade a wide judge window for a slower yield
(GENTLE) against a narrow window and a faster yield (DEEP). Change the
preset on the title screen or in Settings, or queue a new one mid-play
with UP/DOWN — it applies at the next cycle, never mid-cycle. Settings
(preset, flash reduction, text size) and your best yield per level
persist in the browser. Settings are reachable before any play.

The sync design is the week's experiment: the core keeps a 48 kHz
sample clock and derives the pump's animation phase from it, so what
you see and what you hear can never drift apart.

## Preview videos (rendered from the shipped core, demo mode)

- [Level 1 — First Draw](docs/previews/level-1-creamery.mp4)
- [Level 2 — The Morning Round](docs/previews/level-2-creamery.mp4)
- [Level 3 — The Full Book](docs/previews/level-3-creamery.mp4)

## Build & verify

```sh
just build   # zig build + assemble web/index.html
just check   # fmt, 17 core tests, settings bridge, perf budget, playtest
just previews
```

Status: **v1.0.0** (2026-10-30) — playable, gated, tagged. The seahawk
playtest pass on primo and the live itch.io entry checks (GJ-07) remain
scheduled follow-ups; both are recorded in `docs/BREAKAGE-LOG.md`.
