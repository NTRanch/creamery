# Build & Delivery — Creamery

**Language:** Zig (tiger-style-zig)

**Delivery shape:** Compile to wasm32, inline the module (base64) in the single index.html; JS is loader and DOM bridge only. Toolchain home: sandbox.

**Jam rule:** one self-contained `index.html`, ≥6 screens (Title / Pause /
How to Play / Gameplay / Settings / Game Over-or-Victory), documented
process (GAMEOTRON orchestrates; the language build chain is part of the
documentation).

**Book:** `mdbook build book` renders this planning book to `book/html/`
with the NTRanch theme (dark background, hot pink).
