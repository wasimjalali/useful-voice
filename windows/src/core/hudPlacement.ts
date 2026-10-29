/**
 * Where the HUD window goes: at the bottom of the work area, or beside the text cursor.
 *
 * Pure (no Electron), all in DIP. The window is a fixed 520 x 96 area and the bubble is drawn
 * inside it, so these functions say where the window sits for the bubble to land on the right
 * spot. The renderer assumes this geometry:
 *  - bottom: the bubble is centred in the window, its bottom edge 28 above the window's bottom;
 *  - caret: the bubble is vertically centred in the window, its leading edge 28 from the window's
 *    left edge (flipped: its trailing edge 28 from the right edge).
 */

import type { HudPlacement } from './hudModel.js';

export interface Rect {
  x: number;
  y: number;
  width: number;
  height: number;
}

export const HUD_WIDTH = 520;
export const HUD_HEIGHT = 96;
/** How far the bubble sits inside the window's edge (room for its shadow and halo). */
const INSET = 28;
const BUBBLE_HEIGHT = 30;
/** The widest bubble, for the rectangle `bubbleRect` reports when the real width is not known. */
const BUBBLE_MAX_WIDTH = 340;
/**
 * Room the bubble needs beyond the caret before it flips to the caret's left (flipping covers the
 * words just before the cursor, so only when there is truly no room), and how much of it must
 * stay on screen when the window is clamped.
 */
const BUBBLE_MIN_ROOM = 170;
const CHIP_HEIGHT = 22;
const CHIP_MAX_WIDTH = 160;
/** Gap between the caret and the bubble / the done chip. */
const CARET_GAP = 14;
const CHIP_GAP = 8;
/** The bottom bubble's distance from the work area edge. */
const BOTTOM_GAP = 32;

type Point = { x: number; y: number };

const clamp = (value: number, min: number, max: number): number => Math.min(Math.max(min, value), Math.max(min, max));
const right = (area: Rect): number => area.x + area.width;
const bottom = (area: Rect): number => area.y + area.height;

/** Caret placement when there is a caret, flipped to its left when the bubble would not fit on the right. */
export function decidePlacement(caret: Rect | null, workArea: Rect): HudPlacement {
  if (!caret) return { kind: 'bottom' };
  return { kind: 'caret', flipped: caret.x + caret.width + CARET_GAP + BUBBLE_MIN_ROOM > right(workArea) };
}

/** The window's top-left for the bottom spot, plus the user's remembered drag (bottom only). */
function bottomOrigin(workArea: Rect, offset: { dx: number; dy: number }): Point {
  const x = Math.round(workArea.x + (workArea.width - HUD_WIDTH) / 2) + offset.dx;
  const y = bottom(workArea) - BOTTOM_GAP - (HUD_HEIGHT - INSET) + offset.dy;
  return {
    x: clamp(x, workArea.x, right(workArea) - HUD_WIDTH),
    // The bubble's bottom edge stays inside the work area.
    y: clamp(y, workArea.y, bottom(workArea) - (HUD_HEIGHT - INSET)),
  };
}

/** The default bottom spot for a display, before any drag. The drag offset is stored relative to it. */
export function bottomDefaultOrigin(workArea: Rect): Point {
  return bottomOrigin(workArea, { dx: 0, dy: 0 });
}

/**
 * Where the window goes for a placement. `anchor` is the caret in DIP; `offset` is the remembered
 * drag and applies to the bottom spot only. A caret placement without a caret is the bottom spot.
 */
export function hudWindowOrigin(
  placement: HudPlacement,
  anchor: Rect | null,
  workArea: Rect,
  offset: { dx: number; dy: number } = { dx: 0, dy: 0 },
): Point {
  if (placement.kind === 'bottom' || !anchor) return bottomOrigin(workArea, offset);
  const centreY = anchor.y + anchor.height / 2;
  const x = placement.flipped
    ? anchor.x - CARET_GAP - (HUD_WIDTH - INSET)
    : anchor.x + anchor.width + CARET_GAP - INSET;
  return clampCaretWindow(x, Math.round(centreY - HUD_HEIGHT / 2), placement.flipped, BUBBLE_HEIGHT, BUBBLE_MIN_ROOM, workArea);
}

/** Keep at least `maxWidth` (the room the bubble or chip needs) of a caret window's bubble inside the work area. */
function clampCaretWindow(
  x: number,
  y: number,
  flipped: boolean,
  height: number,
  maxWidth: number,
  workArea: Rect,
): Point {
  // The bubble's extent inside the window, from its leading edge (the inset) to its widest.
  const minX = flipped ? workArea.x - (HUD_WIDTH - INSET - maxWidth) : workArea.x - INSET;
  const maxX = flipped ? right(workArea) - (HUD_WIDTH - INSET) : right(workArea) - INSET - maxWidth;
  const top = (HUD_HEIGHT - height) / 2;
  return {
    x: clamp(x, minX, maxX),
    y: clamp(y, workArea.y - top, bottom(workArea) - top - height),
  };
}

/** Where the bubble is on screen for a window origin. `width` is the bubble's actual or widest width. */
export function bubbleRect(placement: HudPlacement, origin: Point, width = BUBBLE_MAX_WIDTH): Rect {
  if (placement.kind === 'bottom') {
    return {
      x: origin.x + Math.round((HUD_WIDTH - width) / 2),
      y: origin.y + HUD_HEIGHT - INSET - BUBBLE_HEIGHT,
      width,
      height: BUBBLE_HEIGHT,
    };
  }
  return {
    x: placement.flipped ? origin.x + HUD_WIDTH - INSET - width : origin.x + INSET,
    y: origin.y + (HUD_HEIGHT - BUBBLE_HEIGHT) / 2,
    width,
    height: BUBBLE_HEIGHT,
  };
}

/**
 * The window origin for the done chip beside the new caret. The chip is small, so the side is
 * decided again: it stays on the bubble's side unless the caret has moved to where it would not fit.
 */
export function chipWindowOrigin(
  placement: Extract<HudPlacement, { kind: 'caret' }>,
  caret: Rect,
  workArea: Rect,
): { origin: Point; placement: Extract<HudPlacement, { kind: 'caret' }> } {
  const fitsRight = caret.x + caret.width + CHIP_GAP + CHIP_MAX_WIDTH <= right(workArea);
  const fitsLeft = caret.x - CHIP_GAP - CHIP_MAX_WIDTH >= workArea.x;
  const flipped = placement.flipped ? !(fitsRight && !fitsLeft) : !fitsRight && fitsLeft;
  const x = flipped ? caret.x - CHIP_GAP - (HUD_WIDTH - INSET) : caret.x + caret.width + CHIP_GAP - INSET;
  const centreY = caret.y + caret.height / 2;
  return {
    origin: clampCaretWindow(x, Math.round(centreY - HUD_HEIGHT / 2), flipped, CHIP_HEIGHT, CHIP_MAX_WIDTH, workArea),
    placement: { kind: 'caret', flipped },
  };
}

/**
 * The language picker's window origin: centred on the bubble and opening above it, or below it when
 * there is no room above. `window` is the picker window's size, with `margin` of shadow room all round.
 */
export function pickerOrigin(
  bubble: Rect,
  workArea: Rect,
  picker: { width: number; height: number; margin: number; gap: number },
): Point {
  const x = clamp(Math.round(bubble.x + bubble.width / 2 - picker.width / 2), workArea.x, right(workArea) - picker.width);
  const above = bubble.y - picker.gap + picker.margin - picker.height;
  const y = above + picker.margin >= workArea.y ? above : bubble.y + bubble.height + picker.gap - picker.margin;
  return { x, y: clamp(y, workArea.y, bottom(workArea) - picker.height) };
}

/**
 * Read the caret script's answer, `left,top,right,bottom` in physical pixels, into a rectangle.
 * Anything else (`own`, empty, garbage), a negative size, or a height outside [minHeight, maxHeight]
 * is not a text caret.
 */
export function parseCaretLine(line: string, minHeight: number, maxHeight: number): Rect | null {
  const match = /^(-?\d+),(-?\d+),(-?\d+),(-?\d+)$/.exec(line.trim());
  if (!match) return null;
  const [left, top, rightEdge, bottomEdge] = match.slice(1).map(Number) as [number, number, number, number];
  const width = rightEdge - left;
  const height = bottomEdge - top;
  if (width < 0 || height < minHeight || height > maxHeight) return null;
  return { x: left, y: top, width, height };
}
