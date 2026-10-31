# Creamery — task recipes (wired at the v1.0 build, 2026-10-30).
# Zig 0.15.1 lives at ~/.local/bin/zig in the sandbox; on primo use the
# toolchain of record for the estate.

ZIG := env_var_or_default("ZIG", join(home_dir(), ".local/bin/zig"))

# Assemble the single-file jam entry: zig build + inline wasm into web/index.html
build:
    {{ZIG}} build
    node tools/assemble.mjs

# Run every gate: format, unit tests (validation + adversarial), settings
# bridge, performance budget, scripted playtest of all three levels
check:
    {{ZIG}} fmt --check src/main.zig build.zig
    {{ZIG}} test src/main.zig
    {{ZIG}} build
    node tools/assemble.mjs
    node tools/settings-check.mjs
    node tools/perf.mjs
    node tools/playtest.mjs

# Render the per-level preview videos from the shipped core (demo mode)
previews:
    node tools/capture.mjs 0 20261
    node tools/capture.mjs 1 20261
    node tools/capture.mjs 2 20261

# Build the planning book
book:
    mdbook build book
