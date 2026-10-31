# Roadmap — creamery (game) — v0.1 → v1.0
<!-- bloch:roadmap schema=1 kind=game lane=restricted baseline=0.1.0 target=1.0.0 -->

How to work this roadmap (any agent): run `bloch task start R-xxx --agent <you>` before working a task, `bloch task done R-xxx` when you believe it is complete — done runs every `verify:` command and flips the task green only if all pass; there is no override. `bloch task fail R-xxx --error "..."` records a failure. Fixes learned the hard way land in `.ai/memory/lessons.md` via the inbox/promote flow and are surfaced in every HANDOFF.

## Phase 1 — Baseline truth
- [x] R-101 Build is green from a clean checkout
  - verify: bash -c "~/.local/bin/zig build"
  - evidence: 1 verify commands, all exit 0 at 2026-10-31T06:04:08Z
- [x] R-102 Existing tests pass at the baseline
  - verify: bash -c "~/.local/bin/zig test src/main.zig"
  - evidence: 1 verify commands, all exit 0 at 2026-10-31T06:04:08Z
- [x] R-103 Repo identity, baseline version, and this roadmap are recorded
  - verify: test -f .ai/roadmap.md
  - evidence: 1 verify commands, all exit 0 at 2026-10-31T06:04:08Z

## Phase 2 — Core complete
- [x] R-201 Core loop is playable from start to finish
  - verify: node tools/playtest.mjs
  - evidence: 1 verify commands, all exit 0 at 2026-10-31T06:04:08Z
- [x] R-202 Save and load round-trips game state
  - verify: node tools/settings-check.mjs
  - evidence: 1 verify commands, all exit 0 at 2026-10-31T06:04:09Z
- [x] R-203 Settings and accessibility options persist across sessions
  - verify: node tools/settings-check.mjs
  - evidence: 1 verify commands, all exit 0 at 2026-10-31T06:04:09Z

## Phase 3 — Tests and gates
- [x] R-301 Validation tests cover the happy path end to end (half the test split)
  - verify: bash -c "~/.local/bin/zig test src/main.zig"
  - evidence: 1 verify commands, all exit 0 at 2026-10-31T06:04:09Z
- [x] R-302 Adversarial tests cover malformed, oversized, and hostile inputs (half the test split)
  - verify: bash -c "~/.local/bin/zig test src/main.zig"
  - evidence: 1 verify commands, all exit 0 at 2026-10-31T06:04:09Z
- [x] R-303 Structured playtest checklist is executed and its record filed
  - verify: bash -c "node tools/playtest.mjs && test -f docs/PLAYTEST-2026-10-30.md"
  - evidence: 1 verify commands, all exit 0 at 2026-10-31T06:04:09Z

## Phase 4 — Hardening
- [x] R-401 Performance budget holds on target hardware
  - verify: node tools/perf.mjs
  - evidence: 1 verify commands, all exit 0 at 2026-10-31T06:04:09Z
- [x] R-402 Platform builds produce runnable artefacts
  - verify: bash -c "node tools/assemble.mjs && test -s web/index.html"
  - evidence: 1 verify commands, all exit 0 at 2026-10-31T06:04:12Z
- [x] R-403 Safety-critical options (stop/safeword-equivalents, accessibility) are never gated behind progression
  - verify: node tools/settings-check.mjs
  - evidence: 1 verify commands, all exit 0 at 2026-10-31T06:04:12Z

## Phase 5 — Docs
- [x] R-501 README documents install, usage, and verification
  - verify: test -f README.md
  - evidence: 1 verify commands, all exit 0 at 2026-10-31T06:04:12Z
- [x] R-502 CHANGELOG records every user-facing change
  - verify: test -f CHANGELOG.md
  - evidence: 1 verify commands, all exit 0 at 2026-10-31T06:04:12Z

## Phase 6 — Release v1
- [x] R-601 Version is bumped to 1.0.0 and the changelog records the release
  - verify: grep -q '1.0.0' CHANGELOG.md
  - evidence: 1 verify commands, all exit 0 at 2026-10-31T06:04:12Z
- [x] R-602 Clean-environment install and run is verified
  - verify: bash -c "rm -rf zig-out && ~/.local/bin/zig build && node tools/assemble.mjs && node tools/playtest.mjs"
  - evidence: 1 verify commands, all exit 0 at 2026-10-31T06:04:12Z
- [x] R-603 Release artefacts are built from a clean checkout and checksummed
  - verify: sha256sum -c SHA256SUMS
  - evidence: 1 verify commands, all exit 0 at 2026-10-31T06:04:12Z


## Phase 9 — Jam program (week 8, D-333)
- [x] R-901 Design chapter complete: mechanism group + canon core recorded
  - verify: test -f book/src/design.md
  - evidence: 1 verify commands, all exit 0 at 2026-10-31T06:04:12Z
- [x] R-902 Engine research pinned for Zig (libraries, versions, licences)
  - verify: test -f book/src/engine-research.md
  - evidence: 1 verify commands, all exit 0 at 2026-10-31T06:04:12Z
- [x] R-903 Single-file index.html assembles and runs offline with all screens
  - verify: bash -c "node tools/assemble.mjs && grep -q CREAMERY web/index.html"
  - evidence: 1 verify commands, all exit 0 at 2026-10-31T06:04:12Z
- [ ] R-904 GJ-07 passed: 18+ flag, warnings listed, itch ToS screen (verified live at entry)
  - verify: test -f book/src/jam.md
- [x] R-905 Seahawk playtest pass recorded; breakage log filed
  - verify: bash -c "node tools/playtest.mjs && test -f docs/PLAYTEST-2026-10-30.md"
  - evidence: 1 verify commands, all exit 0 at 2026-10-31T06:04:13Z
- [x] R-906 Port-back note + Zig language verdict + §9 transfer filing
  - verify: bash -c "test -f book/src/port-back.md && test -f docs/PORT-BACK.md"
  - evidence: 1 verify commands, all exit 0 at 2026-10-31T06:04:13Z
