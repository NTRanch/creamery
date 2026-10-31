// raster.mjs — draw-list rasteriser for jam-game preview capture.
// Input: a frame = { palette: ["#rrggbb", ...], ops: [...] } on a 960x960
// logical canvas. Ops: ["r",x,y,w,h,ci] rect, ["c",x,y,r,ci] circle,
// ["l",x1,y1,x2,y2,w,ci] line, ["p",x1,y1,x2,y2,x3,y3,ci] triangle,
// ["t",x,y,size,ci,"text"] bitmap text (5x7 font, uppercase set).
// Output: PNG file written via node:zlib (no dependencies).
import { deflateSync } from "node:zlib";
import { writeFileSync } from "node:fs";

const FONT = {
  A: [0x7e, 0x09, 0x09, 0x09, 0x7e], B: [0x7f, 0x49, 0x49, 0x49, 0x36],
  C: [0x3e, 0x41, 0x41, 0x41, 0x22], D: [0x7f, 0x41, 0x41, 0x22, 0x1c],
  E: [0x7f, 0x49, 0x49, 0x49, 0x41], F: [0x7f, 0x48, 0x48, 0x48, 0x40],
  G: [0x3e, 0x41, 0x49, 0x49, 0x2e], H: [0x7f, 0x08, 0x08, 0x08, 0x7f],
  I: [0x41, 0x41, 0x7f, 0x41, 0x41], J: [0x02, 0x01, 0x41, 0x7e, 0x40],
  K: [0x7f, 0x08, 0x14, 0x22, 0x41], L: [0x7f, 0x01, 0x01, 0x01, 0x01],
  M: [0x7f, 0x20, 0x10, 0x20, 0x7f], N: [0x7f, 0x20, 0x10, 0x08, 0x7f],
  O: [0x3e, 0x41, 0x41, 0x41, 0x3e], P: [0x7f, 0x48, 0x48, 0x48, 0x30],
  Q: [0x3e, 0x41, 0x51, 0x62, 0x5e], R: [0x7f, 0x48, 0x4c, 0x4a, 0x39],
  S: [0x32, 0x49, 0x49, 0x49, 0x26], T: [0x40, 0x40, 0x7f, 0x40, 0x40],
  U: [0x7e, 0x01, 0x01, 0x01, 0x7e], V: [0x7c, 0x02, 0x01, 0x02, 0x7c],
  W: [0x7e, 0x01, 0x0e, 0x01, 0x7e], X: [0x63, 0x14, 0x08, 0x14, 0x63],
  Y: [0x70, 0x08, 0x07, 0x08, 0x70], Z: [0x43, 0x45, 0x49, 0x51, 0x61],
  "0": [0x3e, 0x51, 0x49, 0x45, 0x3e], "1": [0x10, 0x30, 0x7f, 0x01, 0x01],
  "2": [0x62, 0x51, 0x49, 0x45, 0x46], "3": [0x41, 0x49, 0x49, 0x49, 0x36],
  "4": [0x0c, 0x14, 0x24, 0x7f, 0x04], "5": [0x72, 0x49, 0x49, 0x49, 0x31],
  "6": [0x3e, 0x49, 0x49, 0x49, 0x26], "7": [0x60, 0x50, 0x48, 0x7f, 0x40],
  "8": [0x36, 0x49, 0x49, 0x49, 0x36], "9": [0x30, 0x49, 0x49, 0x49, 0x3e],
  " ": [0, 0, 0, 0, 0], ".": [0x00, 0x01, 0x01, 0x00, 0x00],
  ",": [0x00, 0x01, 0x02, 0x00, 0x00], "!": [0x00, 0x00, 0x5f, 0x00, 0x00],
  "?": [0x20, 0x40, 0x4d, 0x48, 0x30], "-": [0x08, 0x08, 0x08, 0x08, 0x08],
  "+": [0x08, 0x08, 0x3e, 0x08, 0x08], ":": [0x00, 0x14, 0x00, 0x00, 0x00],
  "'": [0x00, 0x00, 0x40, 0x00, 0x00], "/": [0x03, 0x04, 0x08, 0x10, 0x60],
  "(": [0x00, 0x1c, 0x22, 0x41, 0x00], ")": [0x00, 0x41, 0x22, 0x1c, 0x00],
  "&": [0x36, 0x49, 0x55, 0x22, 0x05], "%": [0x62, 0x64, 0x08, 0x13, 0x23],
};

function hexRGB(hex) {
  const n = parseInt(hex.slice(1), 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
}

export function rasterise(frame, outW = 480, outH = 480) {
  const scale = outW / 960;
  const px = new Uint8Array(outW * outH * 3);
  const pal = frame.palette.map(hexRGB);
  const bg = pal[0] ?? [13, 2, 8];
  for (let i = 0; i < outW * outH; i++) {
    px[i * 3] = bg[0]; px[i * 3 + 1] = bg[1]; px[i * 3 + 2] = bg[2];
  }
  const set = (x, y, ci) => {
    x |= 0; y |= 0;
    if (x < 0 || y < 0 || x >= outW || y >= outH) return;
    const c = pal[ci] ?? [255, 46, 136];
    const o = (y * outW + x) * 3;
    px[o] = c[0]; px[o + 1] = c[1]; px[o + 2] = c[2];
  };
  for (const op of frame.ops) {
    const kind = op[0];
    if (kind === "r") {
      const [, x, y, w, h, ci] = op;
      const X = x * scale, Y = y * scale, W = w * scale, H = h * scale;
      for (let j = Y; j < Y + H; j++) for (let i = X; i < X + W; i++) set(i, j, ci);
    } else if (kind === "c") {
      const [, x, y, r, ci] = op;
      const X = x * scale, Y = y * scale, R = r * scale;
      for (let j = Y - R; j <= Y + R; j++)
        for (let i = X - R; i <= X + R; i++)
          if ((i - X) ** 2 + (j - Y) ** 2 <= R * R) set(i, j, ci);
    } else if (kind === "l") {
      const [, x1, y1, x2, y2, w, ci] = op;
      const X1 = x1 * scale, Y1 = y1 * scale, X2 = x2 * scale, Y2 = y2 * scale;
      const steps = Math.max(Math.abs(X2 - X1), Math.abs(Y2 - Y1), 1);
      const rad = Math.max((w * scale) / 2, 0.5);
      for (let s = 0; s <= steps; s++) {
        const cx = X1 + ((X2 - X1) * s) / steps, cy = Y1 + ((Y2 - Y1) * s) / steps;
        for (let j = cy - rad; j <= cy + rad; j++)
          for (let i = cx - rad; i <= cx + rad; i++)
            if ((i - cx) ** 2 + (j - cy) ** 2 <= rad * rad) set(i, j, ci);
      }
    } else if (kind === "p") {
      const [, ax, ay, bx, by, cx, cy, ci] = op;
      const A = [ax * scale, ay * scale], B = [bx * scale, by * scale], C = [cx * scale, cy * scale];
      const minX = Math.min(A[0], B[0], C[0]), maxX = Math.max(A[0], B[0], C[0]);
      const minY = Math.min(A[1], B[1], C[1]), maxY = Math.max(A[1], B[1], C[1]);
      const edge = (P, Q, R) => (R[0] - P[0]) * (Q[1] - P[1]) - (R[1] - P[1]) * (Q[0] - P[0]);
      const area = edge(A, B, C);
      if (area === 0) continue;
      for (let j = minY; j <= maxY; j++) for (let i = minX; i <= maxX; i++) {
        const P = [i, j];
        const w0 = edge(B, C, P) / area, w1 = edge(C, A, P) / area, w2 = edge(A, B, P) / area;
        if (w0 >= 0 && w1 >= 0 && w2 >= 0) set(i, j, ci);
      }
    } else if (kind === "t") {
      const [, x, y, size, ci, str] = op;
      const unit = Math.max(1, Math.round((size / 7) * scale));
      let cx = x * scale;
      for (const chRaw of String(str)) {
        const glyph = FONT[chRaw.toUpperCase()] ?? FONT["?"];
        // Font data is column-major with bit 0 = BOTTOM row; screen y
        // grows downward, so bit b lands at (6 - b).
        for (let col = 0; col < 5; col++)
          for (let row = 0; row < 7; row++)
            if ((glyph[col] >> row) & 1)
              for (let dj = 0; dj < unit; dj++)
                for (let di = 0; di < unit; di++)
                  set(cx + col * unit + di, y * scale + (6 - row) * unit + dj, ci);
        cx += 6 * unit;
      }
    }
  }
  return px;
}

const CRC_TABLE = (() => {
  const t = new Int32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c;
  }
  return t;
})();
function crc32(buf) {
  let c = -1;
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 255] ^ (c >>> 8);
  return (c ^ -1) >>> 0;
}
function chunk(type, data) {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type, "ascii"), data]);
  const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(body));
  return Buffer.concat([len, body, crc]);
}
export function writePNG(path, px, w, h) {
  const raw = Buffer.alloc(h * (1 + w * 3));
  for (let j = 0; j < h; j++) {
    raw[j * (1 + w * 3)] = 0;
    Buffer.from(px.buffer, j * w * 3, w * 3).copy(raw, j * (1 + w * 3) + 1);
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8; ihdr[9] = 2;
  const png = Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    chunk("IHDR", ihdr), chunk("IDAT", deflateSync(raw)), chunk("IEND", Buffer.alloc(0)),
  ]);
  writeFileSync(path, png);
}
