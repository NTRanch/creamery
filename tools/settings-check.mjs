// settings-check.mjs — gates R-202/R-203/R-403: the settings bridge
// round-trips (preset + flash + text), a wild preset value is ignored,
// and the settings screen is reachable from boot with no progression
// (comfort/accessibility options are never gated).
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { createGame, INPUT } from "../web/game.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const wasmBytes = readFileSync(join(root, "zig-out/bin/creamery.wasm"));
const game = await createGame(wasmBytes, { seed: 7, level: 0, demo: false });

function steps(n, bits = 0) { for (let i = 0; i < n; i++) game.step(bits); }
function fail(msg) { console.error(`settings-check: ${msg}`); process.exit(1); }

if (game.screen() !== 0) fail("boot screen is not the 18+ gate");
game.applySettings(2, true, false);
if (game.settingsBits() !== (2 | 4)) fail("apply_settings(deep, flash_reduced) did not round-trip");
game.applySettings(9, true, false);
if (game.settingsBits() !== (2 | 4)) fail("wild preset value moved the stored settings");
game.applySettings(2, true, true);
if (game.settingsBits() !== (2 | 4 | 8)) fail("apply_settings(deep, flash, text) did not round-trip");

// Navigate gate -> title -> settings with plain input, no play first.
steps(1, INPUT.confirm);
if (game.screen() !== 1) fail("confirm did not leave the gate");
steps(1, INPUT.down); steps(1, INPUT.down);
steps(1, INPUT.confirm);
if (game.screen() !== 5) fail(`settings not reachable from title (screen=${game.screen()})`);
steps(2);
if (!game.frameText().includes("DEEP")) fail("settings screen does not show restored DEEP preset");
if (!game.frameText().includes("REDUCED")) fail("settings screen does not show restored REDUCED flash");
if (!game.frameText().includes("LARGE")) fail("settings screen does not show restored LARGE text");
console.log("settings-check: bridge round-trips; wild preset ignored; settings reachable ungated; restored values render");
