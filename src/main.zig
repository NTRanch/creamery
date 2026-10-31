// creamery/src/main.zig — Creamery core (Zig, wasm32-freestanding).
// Tiger Style (tiger-style-zig): explicit contracts, bounded work, no hidden
// behaviour. Fixed-step evaluation only; the shell calls step() at 60 Hz.

/// One fixed simulation step. dt is fixed by the shell (1/60 s); never read
/// a wall clock inside the core.
export fn step() void {}

/// Bytes of the serialised state snapshot (persistence bridge).
export fn state_len() usize {
    return 0;
}
