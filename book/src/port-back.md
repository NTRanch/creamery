# Port-Back — Creamery

Filed 2026-10-30 at the v1.0 build. The full filing lives in
`docs/PORT-BACK.md`; this chapter carries the verdict and the numbers.

- **Verdict:** plays. The track-is-the-score design holds end to end:
  the pump's cycles are the rhythm, her face couples to the cycle
  peaks, every cycle is booked in the record, and the demo policy
  completes all three levels on the shipped core.
- **Numbers:** sync — animation phase derived from a 48 kHz sample
  counter (768 samples/step), measured drift **0 steps** over full
  demo runs, asserted per step in the core suite. Cycle score —
  draw-in 896 ms, strokes 4/5/6 at 960/848/768 ms, peak 704 ms,
  release 1104 ms, rest 800 ms. Yield — (base + hits × per-hit) ×
  125% on a landed peak, × 70% partial; presets trade window
  320/260/200 ms against per-hit 6/8/11 ml. Juice — hit-stop 96 ms
  (clock frozen too), flash 240 ms in three bands. Demo yields:
  165 / 260 / 450 ml against targets of 150 / 240 / 400. Performance
  — ~0.03 ms/step, wasm ~28 KB.
- **Language verdict (Zig):** second pass confirms W1 and extends it:
  the same integer discipline that made W1's tables total makes W8's
  sync exact — durations as whole steps turn a tolerance problem into
  an equality test. Costs were two one-line strictness fixes. Zig is
  the strongest audio-timing fit in the program so far.
- **Breakage:** `docs/BREAKAGE-LOG.md` B-1…B-6 (two fixed in build,
  one fixed at the D-221 gate, three filed as held/ruling).
- **§9 transfer filing:** items 1–5 of `docs/PORT-BACK.md` (sample-
  clock sync, chart-entry shape, transition table second use, queued
  comfort changes, hit-stop clock freeze) are SFW-labelled technique
  and may transfer to the SFW lane. The game's NSFW-pure design
  content stays in this lane.
