// assemble.mjs — build the single-file jam entry web/index.html from
// zig-out/bin/creamery.wasm + web/game.mjs + web/shell.html.
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const wasmB64 = readFileSync(join(root, "zig-out/bin/creamery.wasm")).toString("base64");
const gameMjs = readFileSync(join(root, "web/game.mjs"), "utf8").replace(/^export /gm, "");
const shell = readFileSync(join(root, "web/shell.html"), "utf8");

const out = shell
  .replace("/*__GAME_MJS__*/", () => gameMjs)
  .replace("/*__WASM_B64__*/", () => wasmB64);
if (out === shell) throw new Error("shell placeholders not found — nothing assembled");
writeFileSync(join(root, "web/index.html"), out);
console.log(`assembled web/index.html (${out.length} bytes, wasm ${wasmB64.length} b64 chars)`);
