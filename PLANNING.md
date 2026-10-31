# Planning — Creamery

- **Program:** Torogao Jam Program (D-333), week 8 of 14, Wave B — Sound
- **Cast:** Alma
- **Language:** Zig (tiger-style-zig)
- **Canon core:** A rhythm game on her signature tool.

## Mechanism group (D-334: primary + coupled + persistence/revelation + feel)

- Audio-reactive animation sync — the track is the score, her animation locks to the pump's cycle
- The Milking Pump core + comfort presets (T1)
- Yield measurement with charting in stub form (the book of record begins here)
- Face coupling at cycle peaks
- Juice — hit-stop and flash on cycle completion

## Validates

Sound-led game feel and tool/chart coupling — whether the numbers the game keeps feel like her record.

## Port-back

Sync tolerances for Torogao's audio-driven scenes; chart-entry shape for the book of record; Zig verdict, second pass (audio timing vs W1's state machines).

## Delivery

Compile to wasm32, inline the module (base64) in the single index.html; JS is loader and DOM bridge only. Toolchain home: sandbox.

## Open preflight items

- GJ-06-class start gate for this week's toolchain (later weeks gate their
  own preflight; only W1's gate covers the program start).
- GJ-07: 18+ flag, content warnings listed, itch ToS screen — verified live
  at entry (the NSFW allowance clause is Owner-reported; re-verify on page).
- Engine-research chapter in the book: confirm the pinned library versions
  before the first build commit.
