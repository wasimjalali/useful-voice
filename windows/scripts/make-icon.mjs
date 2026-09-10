#!/usr/bin/env node
/**
 * Generate the Windows application icon.
 *
 * The icon is produced in code rather than committed as a binary so it stays in
 * step with the brand mark and can be regenerated on any machine. The mark is the
 * same one the macOS bundle and the renderer use: three waveform bars in the brand
 * ink on a white rounded square.
 *
 * Windows wants a multi-resolution .ico containing at least 16, 32, 48 and 256 px.
 * All sizes are rendered from the same vector description so small sizes stay
 * legible instead of being downscaled blurs.
 */

import { promises as fs } from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const outDir = path.join(root, 'build');

/** Brand ink (#171717) on white, matching the design system. */
const INK = [0x17, 0x17, 0x17];
const SURFACE = [0xff, 0xff, 0xff];

const SIZES = [16, 24, 32, 48, 64, 128, 256];

/**
 * Render one size as RGBA.
 *
 * Geometry is expressed as fractions of the canvas so every size is a true
 * re-render. Each bar is a vertical capsule at its own x position — an earlier
 * version centred every bar on the canvas, so only the middle one was ever drawn.
 */
function render(size) {
  const pixels = Buffer.alloc(size * size * 4);
  const radius = size * 0.22;
  // x is the bar's centre; half is its half-height. Both are canvas fractions.
  const bars = [
    { x: 0.30, half: 0.13 },
    { x: 0.50, half: 0.24 },
    { x: 0.70, half: 0.17 },
  ];
  const halfWidth = size * 0.105 / 2;

  for (let y = 0; y < size; y += 1) {
    for (let x = 0; x < size; x += 1) {
      const alphaBg = roundedRectCoverage(x, y, size, size, radius);
      if (alphaBg <= 0) continue;

      let colour = SURFACE;
      for (const bar of bars) {
        const barCentreX = size * bar.x;
        const halfHeight = size * bar.half;
        // Distance to a vertical capsule: horizontal offset from the bar's own
        // axis, plus the vertical overshoot past the capsule's straight section.
        const dx = Math.abs(x + 0.5 - barCentreX);
        const dy = Math.max(0, Math.abs(y + 0.5 - size / 2) - (halfHeight - halfWidth));
        if (Math.hypot(dx, dy) - halfWidth <= 0.5) {
          colour = INK;
          break;
        }
      }

      const offset = (y * size + x) * 4;
      pixels[offset] = colour[0];
      pixels[offset + 1] = colour[1];
      pixels[offset + 2] = colour[2];
      pixels[offset + 3] = Math.round(alphaBg * 255);
    }
  }
  return pixels;
}

/** Fractional coverage of a rounded rectangle at pixel (x, y). */
function roundedRectCoverage(x, y, width, height, radius) {
  const inset = Math.max(0.5, width * 0.045);
  const left = inset;
  const top = inset;
  const right = width - inset;
  const bottom = height - inset;
  const r = Math.min(radius, (right - left) / 2, (bottom - top) / 2);

  // Signed distance to the rounded rectangle.
  const cx = Math.min(Math.max(x + 0.5, left + r), right - r);
  const cy = Math.min(Math.max(y + 0.5, top + r), bottom - r);
  const dx = x + 0.5 - cx;
  const dy = y + 0.5 - cy;
  const distance = Math.hypot(dx, dy) - r;
  // One-pixel smooth edge.
  return Math.max(0, Math.min(1, 0.5 - distance));
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
 * Verify the rendered mark before writing it.
 *
 * A wrong icon is invisible in code review and only shows up as a blurry blob on a
 * user's taskbar, so the generator checks its own output: three bars, each present
 * at its own x position, on a transparent-cornered white square.
 */
function verify(size, rgba) {
  const at = (x, y) => {
    const offset = (y * size + x) * 4;
    return { r: rgba[offset], a: rgba[offset + 3] };
  };
  const problems = [];

  // Corners transparent, centre of the tile white or ink but opaque.
  for (const [x, y] of [[0, 0], [size - 1, 0], [0, size - 1], [size - 1, size - 1]]) {
    if (at(x, y).a > 8) problems.push(`corner (${x},${y}) is not transparent`);
  }
  const middle = at(Math.floor(size / 2), Math.floor(size / 2));
  if (middle.a < 250) problems.push('centre is not opaque');

  // Each bar must actually be drawn at its own position; a bar drawn with ink
  // pixels above and below the vertical centre is required for the i'th x.
  const bars = [
    { x: 0.30, half: 0.13 },
    { x: 0.50, half: 0.24 },
    { x: 0.70, half: 0.17 },
  ];
  bars.forEach((bar, index) => {
    const x = Math.round(bar.x * size);
    let ink = 0;
    for (let y = 0; y < size; y += 1) {
      if (at(Math.min(x, size - 1), y).r < 60) ink += 1;
    }
    const expected = Math.round(bar.half * 2 * size);
    if (ink < expected * 0.7) {
      problems.push(`bar ${index} at x=${x} has only ${ink} ink pixels (expected about ${expected})`);
    }
  });

  // The bars must be separated by surface, or the mark reads as a solid block.
  const gapX = Math.round(((bars[0].x + bars[1].x) / 2) * size);
  if (at(gapX, Math.floor(size / 2)).r < 200) {
    problems.push(`expected surface between bars at x=${gapX}`);
  }

  return problems;
}

async function main() {
  await fs.mkdir(outDir, { recursive: true });

  const entries = SIZES.map((size) => {
    const rgba = render(size);
    // The 16 px tile is too small for a meaningful pixel-count check.
    if (size >= 32) {
      const problems = verify(size, rgba);
      if (problems.length > 0) {
        throw new Error(`icon is wrong at ${size}px: ${problems.join('; ')}`);
      }
    }
    return { size, png: encodePng(size, rgba), dib: encodeDib(size, rgba) };
  });

  const ico = buildIco(entries);
  await fs.writeFile(path.join(outDir, 'icon.ico'), ico);
  // A 512 px PNG for the stores and for the app itself.
  await fs.writeFile(path.join(outDir, 'icon.png'), encodePng(512, render(512)));

  console.log(`icon.ico written (${SIZES.join(', ')} px; ${(ico.length / 1024).toFixed(1)} kB)`);
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : error);
  process.exit(1);
});
