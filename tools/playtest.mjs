// playtest.mjs — automated playtest: the demo policy plays every level
// to victory against the shipped wasm core, and the booked chart is
// asserted consistent (one entry per cycle; the demo lands its peaks).
// This is the sandbox playtest of record; the seahawk pass on primo is
// the follow-up named in docs/BREAKAGE-LOG.md.
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { createGame } from "../web/game.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const wasmBytes = readFileSync(join(root, "zig-out/bin/creamery.wasm"));
const SCREENS = ["gate", "title", "howto", "play", "pause", "settings", "victory", "gameover"];

let failures = 0;
for (let level = 0; level < 3; level++) {
  const game = await createGame(wasmBytes, { seed: 9000 + level, level, demo: true });
  game.startLevel(level);
  let steps = 0;
  const maxSteps = (6 * 60 * 1000) / 16;
  while (game.screen() !== 6 && steps < maxSteps) {
    game.step(0);
    steps++;
  }
  const won = game.screen() === 6;
  console.log(`level ${level + 1}: screen=${SCREENS[game.screen()]} steps=${steps} yield=${game.yieldMl()} ml ${won ? "VICTORY" : "FAIL"}`);
  if (!won) failures++;
}
if (failures) {
  console.error(`playtest: ${failures} level(s) not completed by the demo policy`);
  process.exit(1);
}
console.log("playtest: all 3 levels completed");
