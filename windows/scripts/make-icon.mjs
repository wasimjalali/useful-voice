#!/usr/bin/env node
/**
 * Generate the Windows application icon and the tray icons.
 *
 * Everything is drawn in code from the Landing mark (three round sound bars landing
 * on a square-cut I-beam caret), so the output stays in step with the SVG masters in
 * assets/branding/ and can be regenerated on any machine. Two cuts exist: the 24 unit
 * master and a 16 unit cut hand-hinted to whole pixels. Sizes where one unit lands on
 * a whole number of pixels use those cuts 1:1 (or doubled), so every edge is crisp.
 *
 * Writes build/icon.ico (16, 20, 24, 32, 40, 48, 64, 128, 256), build/icon.png (512)
 * and build/tray/tray-<taskbar>-<state>-<px>.png for light and dark taskbars.
 */

import { promises as fs } from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const outDir = path.join(root, 'build');
const trayDir = path.join(outDir, 'tray');

const hex = (value) => [(value >> 16) & 255, (value >> 8) & 255, value & 255];
const INK = hex(0x171717);
const LIGHT = hex(0xfafafa);
/** Recording colour per taskbar: the danger tokens of the light and dark palettes. */
const DANGER_ON_LIGHT = hex(0xb23c22);
const DANGER_ON_DARK = hex(0xf0795c);

const ICON_SIZES = [16, 20, 24, 32, 40, 48, 64, 128, 256];
const TRAY_SIZES = [16, 20, 24, 32];
const SAMPLES = 8; // sub-samples per axis for anti-aliasing

/** Round bar: [x, y, width, height], fully round ends (radius = width / 2). */
const MARK_24 = {
  bars: [[1, 9, 3, 6], [6, 7, 3, 10], [11, 5, 3, 14]],
  caret: [[16, 2], [23, 2], [23, 5], [21, 5], [21, 19], [23, 19], [23, 22], [16, 22], [16, 19], [18, 19], [18, 5], [16, 5]],
  size: 24,
  stem: [19.5, 12],
  gap: [4.5, 12],
};
const MARK_16 = {
  bars: [[1, 6, 2, 4], [4, 5, 2, 6], [7, 3, 2, 10]],
  caret: [[11, 1], [15, 1], [15, 3], [14, 3], [14, 13], [15, 13], [15, 15], [11, 15], [11, 13], [12, 13], [12, 3], [11, 3]],
  size: 16,
  stem: [12.5, 8],
  gap: [3.5, 8],
};

/** Inside test for a mark point given in mark units. */
function inMark(mark, x, y) {
  for (const [bx, by, bw, bh] of mark.bars) {
    const r = bw / 2;
    const cx = Math.min(Math.max(x, bx + r), bx + bw - r);
    const cy = Math.min(Math.max(y, by + r), by + bh - r);
    if (Math.hypot(x - cx, y - cy) <= r) return true;
  }
  return pointInPolygon(mark.caret, x, y);
}

function pointInPolygon(points, x, y) {
  let inside = false;
  for (let i = 0, j = points.length - 1; i < points.length; j = i, i += 1) {
    const [xi, yi] = points[i];
    const [xj, yj] = points[j];
    if (yi > y !== yj > y && x < ((xj - xi) * (y - yi)) / (yj - yi) + xi) inside = !inside;
  }
  return inside;
}

/** Signed inside test for a rounded rectangle in pixel space. */
function inRoundedRect(x, y, left, top, right, bottom, r) {
  const cx = Math.min(Math.max(x, left + r), right - r);
  const cy = Math.min(Math.max(y, top + r), bottom - r);
  return x >= left && x <= right && y >= top && y <= bottom && Math.hypot(x - cx, y - cy) <= r;
}

/**
 * Render a canvas of `size` px.
 *   tile:  null for the bare mark, or { body, edge } colours for a rounded tile.
 *   place: { mark, scale, offset } puts the mark at `offset` px with `scale` px per unit.
 */
function render(size, { tile, place, ink }) {
  const pixels = Buffer.alloc(size * size * 4);
  const radius = Math.round(size * 0.18);
  const edge = size >= 32 && tile ? 1 : 0;
  const total = SAMPLES * SAMPLES;
  for (let py = 0; py < size; py += 1) {
    for (let px = 0; px < size; px += 1) {
      let r = 0, g = 0, b = 0, a = 0;
      for (let sy = 0; sy < SAMPLES; sy += 1) {
        for (let sx = 0; sx < SAMPLES; sx += 1) {
          const x = px + (sx + 0.5) / SAMPLES;
          const y = py + (sy + 0.5) / SAMPLES;
          let colour = null;
          if (tile && inRoundedRect(x, y, 0, 0, size, size, radius)) {
            const inner = edge === 0 || inRoundedRect(x, y, edge, edge, size - edge, size - edge, Math.max(0, radius - edge));
            colour = inner ? tile.body : tile.edge;
          }
          const mx = (x - place.offset) / place.scale;
          const my = (y - place.offset) / place.scale;
          if (inMark(place.mark, mx, my)) colour = ink;
          if (colour) {
            r += colour[0]; g += colour[1]; b += colour[2]; a += 1;
          }
        }
      }
      const at = (py * size + px) * 4;
      if (a > 0) {
        pixels[at] = Math.round(r / a);
        pixels[at + 1] = Math.round(g / a);
        pixels[at + 2] = Math.round(b / a);
        pixels[at + 3] = Math.round((a / total) * 255);
      }
    }
  }
  return pixels;
}

const LIGHT_TILE = { body: LIGHT, edge: [0xc9, 0xc9, 0xc9] };

/** How the mark sits on the app icon tile at each size. */
function iconPlacement(size) {
  if (size <= 32) return { mark: MARK_16, scale: 1, offset: (size - 16) / 2 };
  if (size <= 48) return { mark: MARK_24, scale: 1, offset: (size - 24) / 2 };
  if (size === 64) return { mark: MARK_16, scale: 2, offset: 16 };
  const scale = (size * 440) / 1024 / 24;
  return { mark: MARK_24, scale, offset: size / 2 - 12 * scale };
}

/** How the bare mark sits in a tray icon: whole pixels at 16, 24 (24 unit cut) and 32. */
function trayPlacement(size) {
  if (size === 24) return { mark: MARK_24, scale: 1, offset: 0 };
  return { mark: MARK_16, scale: size / 16, offset: 0 };
}

/** Encode RGBA pixels as a PNG. */
function encodePng(size, rgba) {
  const raw = Buffer.alloc((size * 4 + 1) * size);
  for (let y = 0; y < size; y += 1) {
    raw[y * (size * 4 + 1)] = 0; // filter: none
    rgba.copy(raw, y * (size * 4 + 1) + 1, y * size * 4, (y + 1) * size * 4);
  }

  const chunk = (type, data) => {
    const length = Buffer.alloc(4);
    length.writeUInt32BE(data.length);
    const typeAndData = Buffer.concat([Buffer.from(type, 'ascii'), data]);
    const crc = Buffer.alloc(4);
    crc.writeUInt32BE(crc32(typeAndData) >>> 0);
    return Buffer.concat([length, typeAndData, crc]);
  };

  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(size, 0);
  ihdr.writeUInt32BE(size, 4);
  ihdr[8] = 8;  // bit depth
  ihdr[9] = 6;  // colour type RGBA
  ihdr[10] = 0;
  ihdr[11] = 0;
  ihdr[12] = 0;

  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr),
    chunk('IDAT', zlib.deflateSync(raw, { level: 9 })),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

let crcTable = null;
function crc32(buffer) {
  if (!crcTable) {
    crcTable = new Int32Array(256);
    for (let n = 0; n < 256; n += 1) {
      let c = n;
      for (let k = 0; k < 8; k += 1) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
      crcTable[n] = c;
    }
  }
  let crc = -1;
  for (const byte of buffer) crc = crcTable[(crc ^ byte) & 0xff] ^ (crc >>> 8);
  return crc ^ -1;
}

/**
 * Build a multi-resolution .ico.
 *
 * The 256 px entry is stored as PNG (which Windows Vista and later expect at that
 * size); smaller entries use the classic BMP/DIB form for maximum compatibility.
 */
function buildIco(entries) {
  const header = Buffer.alloc(6);
  header.writeUInt16LE(0, 0);          // reserved
  header.writeUInt16LE(1, 2);          // type: icon
  header.writeUInt16LE(entries.length, 4);

  const directory = Buffer.alloc(16 * entries.length);
  const images = [];
  let offset = 6 + directory.length;

  entries.forEach((entry, index) => {
    const isPng = entry.size >= 256;
    const data = isPng ? entry.png : entry.dib;
    const at = index * 16;
    directory[at] = entry.size >= 256 ? 0 : entry.size;   // 0 means 256
    directory[at + 1] = entry.size >= 256 ? 0 : entry.size;
    directory[at + 2] = 0;                                 // palette
    directory[at + 3] = 0;                                 // reserved
    directory.writeUInt16LE(1, at + 4);                    // colour planes
    directory.writeUInt16LE(32, at + 6);                   // bits per pixel
    directory.writeUInt32LE(data.length, at + 8);
    directory.writeUInt32LE(offset, at + 12);
    offset += data.length;
    images.push(data);
  });

  return Buffer.concat([header, directory, ...images]);
}

/** Encode RGBA as a BMP/DIB suitable for an .ico entry (bottom-up, BGRA). */
function encodeDib(size, rgba) {
  const header = Buffer.alloc(40);
  header.writeUInt32LE(40, 0);                  // header size
  header.writeInt32LE(size, 4);                 // width
  header.writeInt32LE(size * 2, 8);             // height (colour + mask)
  header.writeUInt16LE(1, 12);                  // planes
  header.writeUInt16LE(32, 14);                 // bits per pixel
  header.writeUInt32LE(0, 16);                  // no compression
  header.writeUInt32LE(size * size * 4, 20);    // image size
  header.writeInt32LE(0, 24);
  header.writeInt32LE(0, 28);
  header.writeUInt32LE(0, 32);
  header.writeUInt32LE(0, 36);

  const pixels = Buffer.alloc(size * size * 4);
  for (let y = 0; y < size; y += 1) {
    const source = (size - 1 - y) * size * 4;   // bottom-up
    for (let x = 0; x < size; x += 1) {
      const from = source + x * 4;
      const to = (y * size + x) * 4;
      pixels[to] = rgba[from + 2];      // B
      pixels[to + 1] = rgba[from + 1];  // G
      pixels[to + 2] = rgba[from];      // R
      pixels[to + 3] = rgba[from + 3];  // A
    }
  }

  // The AND mask is required even with an alpha channel; all-zero means "use alpha".
  const maskStride = Math.ceil(size / 32) * 4;
  const mask = Buffer.alloc(maskStride * size, 0);

  return Buffer.concat([header, pixels, mask]);
}

/**
 * Check the rendered tile before writing it.
 *
 * A wrong icon is invisible in code review and only shows up as a blurry blob on a
 * user's taskbar, so the generator checks its own output: transparent corners, ink
 * in the caret stem, and surface in the gap between the first two bars.
 */
function verify(size, rgba, place) {
  const at = (x, y) => {
    const offset = (Math.floor(y) * size + Math.floor(x)) * 4;
    return { r: rgba[offset], a: rgba[offset + 3] };
  };
  const problems = [];
  for (const [x, y] of [[0, 0], [size - 1, 0], [0, size - 1], [size - 1, size - 1]]) {
    if (at(x, y).a > 8) problems.push(`corner (${x},${y}) is not transparent`);
  }
  const toPx = ([ux, uy]) => [place.offset + ux * place.scale, place.offset + uy * place.scale];
  const stem = at(...toPx(place.mark.stem));
  if (stem.r > 60) problems.push('caret stem is not ink');
  const gap = at(...toPx(place.mark.gap));
  if (gap.r < 200) problems.push('no surface between the first two bars');
  return problems;
}

async function main() {
  await fs.mkdir(trayDir, { recursive: true });

  const entries = ICON_SIZES.map((size) => {
    const place = iconPlacement(size);
    const rgba = render(size, { tile: LIGHT_TILE, place, ink: INK });
    const problems = verify(size, rgba, place);
    if (problems.length > 0) {
      throw new Error(`icon is wrong at ${size}px: ${problems.join('; ')}`);
    }
    return { size, png: encodePng(size, rgba), dib: encodeDib(size, rgba) };
  });

  const ico = buildIco(entries);
  await fs.writeFile(path.join(outDir, 'icon.ico'), ico);
  // A 512 px PNG for the stores and for the app itself.
  await fs.writeFile(
    path.join(outDir, 'icon.png'),
    encodePng(512, render(512, { tile: LIGHT_TILE, place: iconPlacement(512), ink: INK })),
  );

  // Tray icons: the bare mark, ink on a light taskbar and light on a dark one. While
  // recording the mark takes the danger colour of that palette.
  const tray = [
    ['light', 'idle', INK],
    ['light', 'recording', DANGER_ON_LIGHT],
    ['dark', 'idle', LIGHT],
    ['dark', 'recording', DANGER_ON_DARK],
  ];
  for (const [taskbar, state, ink] of tray) {
    for (const size of TRAY_SIZES) {
      const rgba = render(size, { tile: null, place: trayPlacement(size), ink });
      await fs.writeFile(path.join(trayDir, `tray-${taskbar}-${state}-${size}.png`), encodePng(size, rgba));
    }
  }

  console.log(
    `icon.ico written (${ICON_SIZES.join(', ')} px; ${(ico.length / 1024).toFixed(1)} kB), icon.png, ${tray.length * TRAY_SIZES.length} tray PNGs`,
  );
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : error);
  process.exit(1);
});
