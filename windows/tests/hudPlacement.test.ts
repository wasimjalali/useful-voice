import { describe, expect, it } from 'vitest';
import {
  HUD_HEIGHT,
  HUD_WIDTH,
  bubbleRect,
  chipWindowOrigin,
  decidePlacement,
  hudWindowOrigin,
  parseCaretLine,
  pickerOrigin,
  type Rect,
} from '../src/core/hudPlacement.js';

const SCREEN: Rect = { x: 0, y: 0, width: 1920, height: 1040 };
/** A second monitor to the left of the main one: negative coordinates. */
const LEFT: Rect = { x: -1920, y: -100, width: 1920, height: 1040 };
const caretAt = (x: number, y: number, height = 20): Rect => ({ x, y, width: 0, height });

describe('decidePlacement', () => {
  it('uses the bottom when there is no caret', () => {
    expect(decidePlacement(null, SCREEN)).toEqual({ kind: 'bottom' });
  });

  it('puts the bubble on the right of a caret in the middle of the screen', () => {
    expect(decidePlacement(caretAt(800, 400), SCREEN)).toEqual({ kind: 'caret', flipped: false });
  });

  it('flips only when there is truly no room: less than 170 beyond the caret', () => {
    // right + 14 + 170 = 1920 exactly: still fits.
    expect(decidePlacement(caretAt(1920 - 184, 400), SCREEN)).toEqual({ kind: 'caret', flipped: false });
    // One pixel more: flips.
    expect(decidePlacement(caretAt(1920 - 183, 400), SCREEN)).toEqual({ kind: 'caret', flipped: true });
    // Room for a short bubble but not the widest one: stays on the right of the cursor.
    expect(decidePlacement(caretAt(1920 - 300, 400), SCREEN)).toEqual({ kind: 'caret', flipped: false });
  });

  it('measures the flip against the right edge of a monitor with negative coordinates', () => {
    // LEFT's right edge is x = 0.
    expect(decidePlacement(caretAt(-100, 200), LEFT)).toEqual({ kind: 'caret', flipped: true });
    expect(decidePlacement(caretAt(-700, 200), LEFT)).toEqual({ kind: 'caret', flipped: false });
  });

  it('uses the caret right edge, not its left, for a caret with width', () => {
    const wide: Rect = { x: 1920 - 220, y: 300, width: 60, height: 20 };
    expect(decidePlacement(wide, SCREEN)).toEqual({ kind: 'caret', flipped: true });
  });
});

describe('hudWindowOrigin', () => {
  it('centres the bottom bubble, 32 above the work area edge', () => {
    const origin = hudWindowOrigin({ kind: 'bottom' }, null, SCREEN);
    expect(origin.x).toBe((1920 - HUD_WIDTH) / 2);
    // The bubble's bottom is 28 above the window's bottom edge.
    expect(origin.y + HUD_HEIGHT - 28).toBe(1040 - 32);
  });

  it('applies the drag offset to a bottom bubble only', () => {
    const base = hudWindowOrigin({ kind: 'bottom' }, null, SCREEN);
    const moved = hudWindowOrigin({ kind: 'bottom' }, null, SCREEN, { dx: -200, dy: -150 });
    expect(moved).toEqual({ x: base.x - 200, y: base.y - 150 });
    const caret = caretAt(800, 400);
    expect(hudWindowOrigin({ kind: 'caret', flipped: false }, caret, SCREEN, { dx: 500, dy: 500 })).toEqual(
      hudWindowOrigin({ kind: 'caret', flipped: false }, caret, SCREEN),
    );
  });

  it('keeps a dragged bottom bubble inside the work area', () => {
    const far = hudWindowOrigin({ kind: 'bottom' }, null, SCREEN, { dx: 99999, dy: 99999 });
    expect(far.x).toBe(1920 - HUD_WIDTH);
    expect(far.y + HUD_HEIGHT - 28).toBe(1040);
    const near = hudWindowOrigin({ kind: 'bottom' }, null, SCREEN, { dx: -99999, dy: -99999 });
    expect(near).toEqual({ x: 0, y: 0 });
  });

  it('places a caret bubble 14 to the right, centred on the caret line', () => {
    const caret = caretAt(800, 400, 20); // right 800, centre y 410
    const origin = hudWindowOrigin({ kind: 'caret', flipped: false }, caret, SCREEN);
    const bubble = bubbleRect({ kind: 'caret', flipped: false }, origin);
    expect(bubble.x).toBe(800 + 14);
    expect(bubble.y + bubble.height / 2).toBe(410);
  });

  it('places a flipped bubble with its trailing edge 14 left of the caret', () => {
    const caret = caretAt(1700, 400);
    const origin = hudWindowOrigin({ kind: 'caret', flipped: true }, caret, SCREEN);
    const bubble = bubbleRect({ kind: 'caret', flipped: true }, origin);
    expect(bubble.x + bubble.width).toBe(1700 - 14);
  });

  it('never pushes the leading edge past 170 from the right edge, nor over the caret further left', () => {
    const placement = { kind: 'caret', flipped: false } as const;
    const origin = hudWindowOrigin(placement, caretAt(1745, 400), SCREEN);
    expect(bubbleRect(placement, origin).x).toBe(1920 - 170);
    // With room, the bubble is not moved at all.
    expect(bubbleRect(placement, hudWindowOrigin(placement, caretAt(1700, 400), SCREEN)).x).toBe(1714);
    const flipped = { kind: 'caret', flipped: true } as const;
    const left = hudWindowOrigin(flipped, caretAt(100, 400), SCREEN);
    const rect = bubbleRect(flipped, left);
    expect(rect.x + rect.width).toBe(170);
  });

  it('clamps a caret near the bottom so the bubble stays on screen', () => {
    const origin = hudWindowOrigin({ kind: 'caret', flipped: false }, caretAt(800, 1035), SCREEN);
    const bubble = bubbleRect({ kind: 'caret', flipped: false }, origin);
    expect(bubble.y + bubble.height).toBeLessThanOrEqual(1040);
  });

  it('clamps a caret near the top so the bubble stays on screen', () => {
    const origin = hudWindowOrigin({ kind: 'caret', flipped: false }, caretAt(800, 0), SCREEN);
    expect(bubbleRect({ kind: 'caret', flipped: false }, origin).y).toBeGreaterThanOrEqual(0);
  });

  it('clamps a caret at the far left of a flipped bubble', () => {
    const origin = hudWindowOrigin({ kind: 'caret', flipped: true }, caretAt(100, 400), SCREEN);
    expect(bubbleRect({ kind: 'caret', flipped: true }, origin).x + 340).toBeGreaterThanOrEqual(170);
  });

  it('works on a monitor with negative coordinates', () => {
    const caret = caretAt(-1500, -50);
    const origin = hudWindowOrigin({ kind: 'caret', flipped: false }, caret, LEFT);
    const bubble = bubbleRect({ kind: 'caret', flipped: false }, origin);
    expect(bubble.x).toBe(-1500 + 14);
    expect(bubble.y).toBeGreaterThanOrEqual(-100);
    const bottom = hudWindowOrigin({ kind: 'bottom' }, null, LEFT);
    expect(bottom.x).toBe(-1920 + (1920 - HUD_WIDTH) / 2);
    expect(bottom.y + HUD_HEIGHT - 28).toBe(-100 + 1040 - 32);
  });

  it('falls back to the bottom spot when a caret placement has no caret', () => {
    expect(hudWindowOrigin({ kind: 'caret', flipped: false }, null, SCREEN)).toEqual(
      hudWindowOrigin({ kind: 'bottom' }, null, SCREEN),
    );
  });
});

describe('chipWindowOrigin', () => {
  it('puts the chip 8 to the right of the new caret', () => {
    const result = chipWindowOrigin({ kind: 'caret', flipped: false }, caretAt(900, 500), SCREEN);
    // Chip leading edge is 28 inside the window.
    expect(result.origin.x + 28).toBe(900 + 8);
    expect(result.origin.y).toBe(510 - HUD_HEIGHT / 2);
    expect(result.placement).toEqual({ kind: 'caret', flipped: false });
  });

  it('puts a flipped chip 8 to the left of the new caret', () => {
    const result = chipWindowOrigin({ kind: 'caret', flipped: true }, caretAt(1000, 500), SCREEN);
    expect(result.origin.x + 492).toBe(1000 - 8);
    expect(result.placement).toEqual({ kind: 'caret', flipped: true });
  });

  it('flips a chip that would pass the right edge, because the caret moved there', () => {
    const result = chipWindowOrigin({ kind: 'caret', flipped: false }, caretAt(1900, 500), SCREEN);
    expect(result.placement).toEqual({ kind: 'caret', flipped: true });
    expect(result.origin.x + 492).toBeLessThanOrEqual(1900 - 8);
  });

  it('keeps the chip on screen near the bottom and the left edge', () => {
    const result = chipWindowOrigin({ kind: 'caret', flipped: true }, caretAt(20, 1038), SCREEN);
    expect(result.origin.x + 492 - 160).toBeGreaterThanOrEqual(0);
    expect(result.origin.y + HUD_HEIGHT / 2 + 11).toBeLessThanOrEqual(1040);
  });
});

describe('pickerOrigin', () => {
  const PICKER = { width: 348, height: 448, margin: 24, gap: 10 };
  it('opens above a bubble with room', () => {
    const bubble: Rect = { x: 700, y: 600, width: 220, height: 30 };
    const origin = pickerOrigin(bubble, SCREEN, PICKER);
    // The panel's bottom (window bottom minus margin) sits 10 above the bubble.
    expect(origin.y + PICKER.height - PICKER.margin).toBe(600 - 10);
  });

  it('opens below a bubble that has no room above', () => {
    const bubble: Rect = { x: 700, y: 100, width: 220, height: 30 };
    const origin = pickerOrigin(bubble, SCREEN, PICKER);
    expect(origin.y + PICKER.margin).toBe(130 + 10);
  });

  it('stays inside the work area horizontally', () => {
    const bubble: Rect = { x: 1800, y: 600, width: 220, height: 30 };
    expect(pickerOrigin(bubble, SCREEN, PICKER).x + PICKER.width).toBeLessThanOrEqual(1920);
    const left: Rect = { x: -1900, y: 600, width: 220, height: 30 };
    expect(pickerOrigin(left, LEFT, PICKER).x).toBeGreaterThanOrEqual(-1920);
  });
});

describe('parseCaretLine', () => {
  it('reads left,top,right,bottom into a rectangle', () => {
    expect(parseCaretLine('100,200,102,220', 6, 120)).toEqual({ x: 100, y: 200, width: 2, height: 20 });
  });

  it('keeps negative coordinates from a monitor on the left', () => {
    expect(parseCaretLine('-1500,-40,-1500,-20', 6, 120)).toEqual({ x: -1500, y: -40, width: 0, height: 20 });
  });

  it('refuses our own window, an empty answer and garbage', () => {
    for (const bad of ['own', '', 'UVERR:x', '1,2,3', '1,2,3,4,5', 'a,b,c,d']) {
      expect(parseCaretLine(bad, 6, 120)).toBeNull();
    }
  });

  it('refuses a rectangle too short or too tall to be a text caret, and an inverted one', () => {
    expect(parseCaretLine('10,10,11,15', 6, 120)).toBeNull();
    expect(parseCaretLine('10,10,11,16', 6, 120)).not.toBeNull();
    expect(parseCaretLine('10,10,11,130', 6, 120)).not.toBeNull();
    expect(parseCaretLine('10,10,11,131', 6, 120)).toBeNull();
    expect(parseCaretLine('20,10,10,30', 6, 120)).toBeNull();
  });
});
