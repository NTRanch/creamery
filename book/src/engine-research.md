# Zig — W1 *Trancefall* (face-state machine) + W8 *Creamery* (audio-reactive sync)

**Language:** Zig (estate pin: 0.15.1 in the sandbox).
**Role in this program:** Pass 1, W1 *Trancefall* — a deterministic F-code face-state machine with zero runtime, built on comptime transition tables. Pass 2, W8 *Creamery* — audio-reactive animation sync on Alma's Milking Pump, where sample-level timing control is the whole test.
**Delivery shape:** Zig core compiled to `wasm32`, the module base64-inlined into ONE self-contained `index.html`; JS is loader and DOM bridge only. Native desktop build of the same core is the development harness.
**Port-back target:** the transition-timing table (W1) and the audio-sync tolerances (W8) land in Torogao's Rust/Bevy rig runtime; the Zig code itself is evidence, not the shipping stack.

**Headline verdict:** Zig has exactly one mature, wasm-first stack — **sokol-zig** — and it covers windowing, 2D rendering, audio streaming, and text well enough for both weeks. Everything above that layer (animation system, face states, arousal engine, scene staging) does not exist as a library in Zig and is ours to write — which is the point of these two weeks: Zig's comptime makes the *tables* those systems run on a compile-time artifact instead of a runtime interpreter.

---

## Parts matrix

### (a) Windowing / rendering 2D

| Choice | What | License | Maturity |
|---|---|---|---|
| **PRIMARY: sokol-zig** — https://github.com/floooh/sokol-zig | Official Zig bindings for the sokol headers (https://github.com/floooh/sokol): `sokol_app` (window, events, main loop), `sokol_gfx` (GPU API; WebGL2 backend under wasm), `sokol_gl` (immediate-mode 2D drawing: textured quads, lines, transforms — the sprite layer), `sokol_fetch` (async asset loading, if not embedding). Bindings are auto-generated from the C headers and track upstream continuously. | zlib (sokol is zlib/libpng; bindings zlib) | The most mature option in Zig gamedev. Actively maintained by sokol's author; wasm is a first-class sokol target — the build system pulls the Emscripten SDK (`emsdk`) as a lazy dependency and builds with `-Dtarget=wasm32-emscripten`. Shipped commercial games exist on this stack. |
| ALT: raylib via raylib-zig — https://github.com/Not-Nik/raylib-zig | Manually tweaked, auto-generated bindings for raylib (https://github.com/raysan5/raylib, zlib). Batteries included: textures, sprites, text, audio in one API. | Bindings MIT; raylib zlib | Widely used, but the binding tracks raylib/Zig versions on `devel`; the wasm path goes through raylib's own Emscripten build and is heavier and less exercised than sokol's. Keep as fallback only. |
| ALT: zsdl (zig-gamedev) — https://github.com/zig-gamedev/zig-gamedev | SDL2/SDL3 bindings from the zig-gamedev toolbox. | MIT | Desktop-proven; SDL-on-wasm means Emscripten's SDL port — an extra compatibility layer with no advantage over sokol here. Not chosen. |
| REJECTED: Mach — https://github.com/hexops/mach | Zig-native engine: own `sysgpu`/`sysaudio`, object system, sprite/text modules. Dual MIT/Apache-2.0. | MIT / Apache-2.0 | **Disqualified for the jam:** Mach's own platform page states the browser target's WebGPU is "not working" (audio/input work) — https://machengine.org/about/platforms/ . Mach is also explicitly experimental/pre-1.0 and mid-restructure (v0.5 was the last version whose graphics mirrored WebGPU). Revisit for native work, not for a single-file wasm deadline. |
| REJECTED: raw WebGL via zgl / zopengl | Thin OpenGL bindings (ziglibs/zgl, zig-gamedev/zopengl). | MIT | You would hand-roll window, events, and the JS glue anyway; sokol already did that work. |

2D drawing detail: `sokol_gl` gives an immediate-mode context (begin/end, texture binding, matrix stack, vertex colours) that maps directly onto a sprite-batching renderer: one atlas texture, quads per part, transforms per bone — all we need for layered 2.5D character rendering. Shaders are compiled at build time with sokol-shdc (GLSL in, backend code out), so the web build's GLSL ES 3.00 shaders are generated, not hand-ported.

### (b) Sprite animation & skeletal / 2.5D rig playback

| Choice | Verdict |
|---|---|
| Sprite-sheet / layered-part playback | **NONE — write it (small).** No Zig library provides a VN-grade layered-part animator. This is deliberate: our playback model is a deterministic fixed-step evaluator over part transforms (position/rotation/scale/opacity per part, eased between keyframes), which is ~a screen of Zig over `sokol_gl`. See the write-from-scratch register. |
| Spine skeletal data | **spine-c via C ABI — conditional.** The official Spine Runtimes ship a plain-C runtime (`spine-c`) — https://github.com/EsotericSoftware/spine-runtimes — and Zig's `@cImport` consumes C directly, so playback of Spine-editor exports (bones, meshes, IK, animation mixing) is technically available. **License catch:** the runtimes are under the Spine Runtimes License Agreement; distributing software containing them requires a Spine editor license held at integration time (see the repo README). It also imports an authoring-tool dependency (the Spine editor) the estate pipeline does not otherwise use, and its animation model is wall-clock delta-based, which fights our fixed-step determinism unless wrapped. Verdict: available, not adopted for W1/W8; the estate's own lumen-rig format is the rig of record. |
| Live2D Cubism | **NONE (practical).** Cubism Core is a proprietary, closed-source binary library with a C API, distributed under the Live2D Proprietary Software License (https://github.com/pixhaus-app/pixhaus/blob/HEAD/docs/planning/skeletal-animation/Live2D-Cubism.md); the higher framework is C++. No Zig binding exists, and hand-binding a proprietary binary blob for a one-week jam is out of scope. |
| Tween/easing helpers | **NONE needed as a library.** Easing curves are comptime-generated lookup tables or closed-form functions in our evaluator; DVUI (below) has an easing module but importing a UI toolkit for easing functions is unjustified. |

### (c) Audio playback + reactive sync (sample-accurate timing)

| Choice | What | License | Maturity |
|---|---|---|---|
| **PRIMARY: `sokol_audio`** (in sokol-zig) | Streaming audio: the app renders/pushes PCM samples into a ring buffer; on web it sits on WebAudio. Crucially, the API exposes the stream's expected frame count and sample rate, so **the audio stream position is a usable master clock**: W8 schedules pump-cycle animation events against samples-rendered counts, not against `requestAnimationFrame`. | zlib | Part of the mature sokol core; used by shipped sokol games. Limits: sokol_audio is a *stream*, not a mixer/decoder — mixing and decoding are ours (below). |
| Decode + mix: miniaudio via zaudio — https://github.com/zig-gamedev/zaudio | Zig bindings for miniaudio (https://github.com/mackron/miniaudio): decoding WAV/MP3/Ogg Vorbis/FLAC, mixing, effects, an engine API. | miniaudio is MIT-0 / public-domain dual; zaudio MIT | miniaudio itself is extremely mature (single-file C, everywhere). zaudio is desktop-first: its wasm behaviour is far less proven than sokol's, and zig-gamedev libraries track a pinned Zig nightly (`.zigversion` in their repo), which can fight the estate's 0.15.1 pin. **Plan:** use miniaudio's *decoder* compiled through `@cImport` directly (skip the zaudio wrapper) if sokol_audio's push model needs decoded buffers; spike it in the W8 preflight, not mid-week. |
| ALT: raylib audio | Comes free with the raylib fallback. | zlib | Music-stream position queries exist but are coarser than a raw sample clock. Fallback only. |

Sync design (W8): one decoded stereo buffer for the pump track; a sample-counter read each frame converts to cycles/phase; animation phase is *derived from* the audio clock, so drift is impossible by construction — the ±25 ms sync criterion becomes a measurement of WebAudio output latency, not of two clocks disagreeing.

### (d) UI / text rendering — dialogue boxes, fonts

| Choice | What | License | Maturity |
|---|---|---|---|
| **PRIMARY (in-game text): `sokol_fontstash`** (sokol util, via sokol-zig) | Font atlas rendering over `sokol_gfx` using fontstash + stb_truetype (both bundled with sokol): TTF loading, glyph atlas, draw-text calls. This renders dialogue and names. | zlib (sokol); stb public domain/MIT | Ships with sokol; proven in sokol samples. Limits: no complex text shaping (no HarfBuzz) — Latin-script dialogue is fine; combining marks/RTL are not. Our dialogue is Latin-script, so this is a fit, stated honestly. |
| Debug text: `sokol_debugtext` (sokol util) | Built-in bitmap fonts, zero assets. | zlib | For debug overlays/HUD metrics only — character set and look are not presentation-grade. |
| **UI widgets (menus, settings, jam screens): DVUI** — https://github.com/david-vanderson/dvui | Immediate-mode GUI written in pure Zig, 30+ widgets, with a **Web backend** (WebAssembly + WebGL) alongside SDL/raylib backends. Good fit for Title/Pause/How-to-Play/Settings screens. | MIT | Actively developed and genuinely used, but it tracks recent Zig — current docs test against Zig 0.16 while the estate pin is 0.15.1. **Seam:** pin a DVUI commit that builds on 0.15.1, or hand-roll the six jam screens with sokol_gl + fontstash (they are mostly static layouts + buttons). Decide at preflight; do not discover it in build week. |
| Debug UI: `sokol_imgui` | Dear ImGui via sokol. | zlib / ImGui MIT | Dev tooling only (gate evidence screenshots, channel readouts); never shipped UI. |
| Text shaping (HarfBuzz-class) | **NONE mature in Zig.** Mach's freetype/harfbuzz packages exist inside the Mach ecosystem but inherit Mach's experimental status. Not needed for Latin dialogue; recorded so nobody promises shaped text. | — | — |

### (e) State machines / data tables

**No library — this is Zig's home ground and the reason W1 is a Zig week.**
- Transition tables are **comptime values**: a `comptime` block builds the F-code transition table (state × event → next state + timing + easing) from a compact declarative description, and the compiler folds it into a static array. Zero runtime cost, zero parsing, and the table is type-checked — an invalid state name is a compile error, not a runtime surprise.
- `std.meta`, tagged unions, and exhaustive `switch` give the rest: the face-state machine is an enum + exhaustive switch, so adding a state without handling it fails compilation.
- Data authoring format: `.zon` (Zig Object Notation, parsed by `std.zon` at comptime or runtime) for editable tables (tier durations, channel curves as point lists) — the same file is data for the author and a typed struct for the compiler.
- Math: `std.math` suffices; zig-gamedev's `zmath` (SIMD) is unnecessary at VN scale.

### (f) Persistence (localStorage via JS bridge)

**No library; ~40 lines of bridge, ours.**
- Under `wasm32-emscripten` (the sokol path), Zig declares the JS functions it needs as `extern` imports; a small JS snippet in the shell implements them against `localStorage`. Save payloads are serialized with `std.json` (stringify a typed struct — the ledger/save schema is a Zig type, so a malformed save fails to parse loudly).
- Version the save struct from day one (`version` field + migration-on-load); the jam's persistence elements (W1's Revelation state, W8's yield chart) are small structs, so this stays trivial.
- Failure mode to design for: itch.io serves the game in an iframe; localStorage is partitioned per origin in modern browsers — saves persist on the itch embed origin, which is acceptable for a jam entry and must be stated on the page.

### (g) Asset pipeline

| Need | Tool | Notes |
|---|---|---|
| Image decode (PNG/JPEG) | **zstbi** — https://github.com/zig-gamedev/zstbi (stb_image wrapper), or stb_image via `@cImport` directly | zlib/MIT-family (stb is public domain/MIT). Direct `@cImport` of stb_image avoids the zig-gamedev version-pin risk entirely; zstbi is the nicer API if its pinned Zig matches ours. |
| Pure-Zig image option | zigimg — https://github.com/zigimg/zigimg | MIT, pure Zig decode/encode (PNG/JPEG/etc.). Useful for *build-time* tooling (atlas packing) where C deps are friction. |
| Texture atlases | **Write the packer in Zig as a build step** (shelf/rect packing is an afternoon; stb_rect_pack via `@cImport` if preferred) | Atlas + JSON/zon manifest generated at build time; runtime loads one texture. Deterministic packing (sorted input) keeps builds reproducible. |
| Audio formats | Ship **Ogg Vorbis** for music/loops, WAV for short one-shots | Decode via miniaudio (see (c)). Ogg keeps the single-file size survivable; no MP3 (licensing-clean and gapless-loop behaviour is worse). |
| Embedding | `@embedFile` | Assets can be compiled straight into the wasm binary — for a single-file deliverable this is the cleanest pipeline of any language in the program: no fetch, no separate asset requests, base64 inflates everything uniformly at the end. |
| Keeper art | Estate keeper PNGs only (D-292: no new character generation); missing art = abstract stand-in, logged | The pipeline ingests existing art; it generates none. |

### (h) Build tooling — wasm, single-file inlining, testing, CI

- **Build:** `zig build` with `-Dtarget=wasm32-emscripten`; sokol-zig's build helper fetches the Emscripten SDK into the Zig cache on first web build. Native target builds the same core for the dev harness. All from `build.zig` — no Makefile, no npm.
- **Single-file inlining:** a `build.zig` step (or a tiny Zig pack tool) reads the `.wasm`, base64-encodes it (`std.base64`), and substitutes it into the HTML shell template, which instantiates it via `WebAssembly.instantiate` with the emscripten/sokol glue. The shell is ours and is ~100 lines; there is no off-the-shelf Zig "single-file jam packer" — **this packer is a write-it item, shared by all Zig/Odin/Rust weeks' shells.**
- **Size:** Binaryen `wasm-opt -Oz` (https://github.com/WebAssembly/binaryen, Apache-2.0) as a post-step; asset budget enforced by a build-step assertion (fail the build over the itch size ceiling rather than discovering it at upload).
- **Testing:** `zig test` on the **native** target for the pure core — the face-state machine, tier engine, and table validation are platform-free, so the deterministic gates (fixed-step replay, transition-table completeness, exactly-once culmination) run headless in CI. Comptime assertions validate tables at build time for free.
- **CI:** GitHub Actions with a Zig setup step running `zig build test` + both target builds; pin the exact Zig version in the workflow (ecosystem libraries drift against compiler versions — the pin is load-bearing, see Risks).

---

## Write-from-scratch register

Nothing below exists as a library in Zig (or, for most, in any language). Each entry: why, which layer, what it rides on.

1. **Face-state system (F-code expressions, gaze/blush channels)** — *W1's whole subject.*
   Why no library: F-codes are estate canon (F-03 edge, F-05 peak, F-10 daze, the Marsha N-variants); no library on Earth knows our expression taxonomy, and generic "facial animation" libraries animate meshes, not a channelled 2D part/gaze/blush model.
   Layer: **pure core** (state machine + channel curves) with a thin presentation mapper (core outputs channel values; presentation turns them into part transforms, iris offsets, blush opacity).
   Rides on: comptime transition tables (e) over `sokol_gl` rendering (a); gaze scored under the ratified §1.7 full-disc definition — the *definition* is ours, the renderer just obeys it.

2. **Arousal engine (tiered T1–T4, exactly-once culmination)**
   Why no library: it is a game-specific rules engine with estate-canon tier durations and an exactly-once culmination invariant; generic state-machine libraries don't encode domain invariants, and ours is a table + a small evaluator.
   Layer: **pure core**, deterministic fixed-step; presentation only reads tier/phase.
   Rides on: the same comptime table machinery as (1); W8 drives its inputs from the audio clock (c). Zig-specific win: the exactly-once property is testable as a pure function over input traces in `zig test`, no renderer involved.

3. **Sex-scene staging / contact & two-body animation**
   Why no library: believable two-body staging — occlusion order, contact points, guided-hand poses — is the estate's named research problem, not a solved library feature. Spine-class runtimes animate *one* skeleton's bones; they know nothing about two characters in contact.
   Layer: **presentation** (part ordering, contact anchors, occlusion) driven by core scene state.
   Rides on: layered-part sprite playback (b) over `sokol_gl`; anchors are data (points on parts), authored per scene. W1/W8 are single-character weeks — this register entry is written so the Zig verdict can state honestly that Zig offers *nothing* here beyond fast quad rendering, and the W4 Rust week inherits the same gap.

4. **Lactation / fluid simulation (W8 Creamery: pump cycle, yield, charting)**
   Why no library: the fluid timeline is a stateful anatomy model with estate specificity floors (yield accumulates, let-down lands in the active method, the record names it); fluid-sim libraries (SPH/Navier-Stokes) solve physics we don't need at VN presentation fidelity and would be non-deterministic overkill.
   Layer: **pure core** — a small deterministic reservoir/rate model (volumes, rates, cycle phase) integrated at fixed step; presentation maps levels to part scale/opacity and the chart UI.
   Rides on: fixed-step core + the audio clock (the pump cycle *is* the track's phase); chart persistence via (f). Zig's comptime tables hold the per-method rate curves.

5. **Signature-tool mechanics (W8: Milking Pump core + comfort presets + T1 modes)**
   Why no library: a signature tool is canon content — modes, presets, and unlock tiers are game design, not middleware.
   Layer: core state (mode/preset/unlock) + presentation (device rendering, hit-stop/flash juice at cycle completion).
   Rides on: face-state coupling (the tool's peaks drive F-code inputs through (1)'s event interface — tools *emit events*, faces *consume* them; that one-way interface is the design that keeps tools and faces decoupled).

6. **Development / exposure ledgers (W8: yield chart as book-of-record stub)**
   Why no library: ledger semantics are canon (entries are witnessed events; movement lands at appraisal, nowhere else). A generic save system stores bytes; it does not know what an entry *means*.
   Layer: **pure core** (append-only entry list, derived totals) + persistence (f).
   Rides on: `std.json` serialization + the JS localStorage bridge; the chart UI is fontstash text over sokol_gl quads.

---

## Quality bar — Laplace3D-class minimum, per criterion

The bar (estate-measured): 60 fps presentation; motion on every frame; secondary-motion lag ≤17 ms; humanized timing jitter, never metronomic; expression readability at presentation size; seamless loops (seam ratio ≤1.1); audio/reaction sync ≈ +12 ms ±25 ms; deterministic fixed-step evaluation.

| Criterion | Zig: helps / fights |
|---|---|
| 60 fps presentation | **Helps.** sokol_gl batching renders a layered character in a handful of draw calls; Zig compiles to tight wasm with no GC pauses. Nothing in the stack should threaten 60 fps at VN scene complexity. |
| Motion on every frame | **Helps, by forcing the issue.** There is no engine idle animation to lean on — our evaluator emits part transforms every tick, so "always moving" is a property of our breathing/sway layers, authored once and reused. |
| Secondary-motion lag ≤17 ms | **Helps.** Secondary motion (hair, sleeves, pump tubing) is a damped-follow integrator in the fixed-step core — lag is a tunable constant in ticks (1 tick at 60 Hz = 16.7 ms), so the criterion is met by choosing the constant, and verified by replay tests. |
| Humanized jitter, never metronomic | **Mixed.** Determinism helps (jitter is a seeded PRNG in the core — same seed, same performance, testable). Fights: comptime tables tempt perfectly regular timing; the jitter must be *designed into* the tables as per-cycle variation bands, or W1 will feel like a metronome with extra steps. |
| Expression readability at presentation size | **Neutral-to-helps.** Nothing in Zig renders faces; readability is art + the §1.7 gaze definition + channel ranges. fontstash text is crisp at dialogue size. The risk is ours, not the language's. |
| Seamless loops (seam ratio ≤1.1) | **Helps.** Loop phase derives from an integer tick counter (and in W8 from the audio sample clock), so a loop's last frame and first frame are adjacent samples of the same function — seams come from art, not from clock wrap. |
| Audio/reaction sync ≈ +12 ms ±25 ms | **Helps — W8's reason to exist.** Deriving animation phase from `sokol_audio`'s stream position removes inter-clock drift entirely. Fights: WebAudio output latency varies by browser/device and is *not* under our control; the +12 ms target is a calibration offset we set per the measured stream latency, and the ±25 ms window is the honest bound. Measure it in the preflight on real browsers; do not promise tighter. |
| Deterministic fixed-step evaluation | **Helps — the strongest fit in the program.** Pure core, no threads, no wall-clock reads inside the sim, comptime tables, replay tests in `zig test`. Zig's explicit allocator/no-hidden-behaviour discipline is exactly this criterion's native language. The Bevy port-back reads the tables, not the code. |

---

## Risks / seams (honest)

1. **Emscripten is in the build.** sokol's wasm path needs the Emscripten SDK (auto-fetched into the Zig cache). It works, but it means the "pure Zig" story has a large C++ toolchain in the basement; first build on a clean machine is slow, and emsdk version drift is a real CI failure mode. Pin and cache it.
2. **Zig is pre-1.0; the ecosystem tracks moving compilers.** zig-gamedev pins a nightly via `.zigversion`; DVUI's docs test against 0.16 vs our 0.15.1 pin. Every dependency is a version-negotiation. Mitigation: prefer sokol-zig (tracks releases) + `@cImport` of single-file C libraries (stb, miniaudio) over wrapper packages; vendor what we take.
3. **The single-file packer is ours.** Base64 inlining inflates the payload ~33% before gzip; with keeper art at presentation size the budget is real. `wasm-opt -Oz`, Ogg over WAV for music, and atlas discipline are not optional optimizations — they are the size gate.
4. **sokol_audio is a stream, not an engine.** Mixing, decoding, ducking, and voice-line management are our code. For two jam weeks this is a feature (full control of the sync clock); priced honestly, it is a few hundred lines we would not write in raylib.
5. **No shaped text.** fontstash draws glyphs; it does not shape. Latin dialogue: fine. Any future script complexity (or fancy ligature-dependent display font) breaks the assumption — recorded now so it is a known wall, not a surprise.
6. **Two-body/contact remains unsolved by the stack** (see register #3). Zig's W1/W8 weeks don't need it; nobody should cite a Zig week as evidence the contact problem got easier.
7. **Port-back is tables-and-tolerances, not code.** The Bevy runtime gains the transition table format, the sync-clock design, and measured tolerances. The Zig implementation itself is disposable by design — that is the program's deal, stated in the repo so no one mistakes the jam code for a shipping branch.


## How the research applies to Creamery

- Language: **Zig** under tiger-style-zig.
- Canon core: A rhythm game on her signature tool.
- The parts matrix in the dossier names, for every part of the full game
  (rendering, animation, audio, dialogue/UI, state, persistence, assets,
  build), the library or tool this entry pins — or states plainly that the
  part is written from scratch (see the next chapter).
