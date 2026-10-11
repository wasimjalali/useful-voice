/**
 * The Useful Voice mark, Swell: five round bars, tall in the middle, on the 24u grid from
 * the logo board. Sizes under 20px use the hand-hinted 16u cut.
 * Styling and motion live in styles/components/landing-mark.css.
 */

/** `still` and `idle` both draw the static mark; `live` lets the bars follow the levels. */
export type LandingMarkState = 'still' | 'idle' | 'live';

export interface LandingMarkOptions {
  /** Side length in CSS pixels. */
  size: number;
  state?: LandingMarkState;
}

const SVG_NS = 'http://www.w3.org/2000/svg';

/** Below this size the hinted 16u cut is used so edges stay on whole pixels. */
const HINTED_BELOW = 20;

interface Cut {
  grid: number;
  bars: ReadonlyArray<readonly [x: number, y: number, w: number, h: number]>;
}

/** Centres at x = 3, 7.5, 12, 16.5, 21; heights 7, 13, 19, 13, 7; width 2.8; centred at y = 12. */
const CUT_24: Cut = {
  grid: 24,
  bars: [
    [1.6, 8.5, 2.8, 7],
    [6.1, 5.5, 2.8, 13],
    [10.6, 2.5, 2.8, 19],
    [15.1, 5.5, 2.8, 13],
    [19.6, 8.5, 2.8, 7],
  ],
};

/** Width 2 at x = 1, 4, 7, 10, 13; heights 4, 8, 12, 8, 4; centred at y = 8. */
const CUT_16: Cut = {
  grid: 16,
  bars: [
    [1, 6, 2, 4],
    [4, 4, 2, 8],
    [7, 2, 2, 12],
    [10, 4, 2, 8],
    [13, 6, 2, 4],
  ],
};

/** Returns the mark as an SVG element filled with `currentColor`. */
export function createLandingMark(options: LandingMarkOptions): SVGSVGElement {
  const { size, state = 'still' } = options;
  const cut = size < HINTED_BELOW ? CUT_16 : CUT_24;
  const svg = document.createElementNS(SVG_NS, 'svg');
  svg.setAttribute('viewBox', `0 0 ${cut.grid} ${cut.grid}`);
  svg.setAttribute('width', String(size));
  svg.setAttribute('height', String(size));
  svg.setAttribute('fill', 'currentColor');
  svg.setAttribute('aria-hidden', 'true');
  svg.classList.add('landing-mark');
  svg.dataset.state = state;

  cut.bars.forEach(([x, y, w, h], index) => {
    const rect = document.createElementNS(SVG_NS, 'rect');
    rect.classList.add('landing-mark-bar');
    rect.dataset.k = String(index);
    rect.setAttribute('x', String(x));
    rect.setAttribute('y', String(y));
    rect.setAttribute('width', String(w));
    rect.setAttribute('height', String(h));
    rect.setAttribute('rx', String(w / 2));
    svg.append(rect);
  });
  return svg;
}

export type LandingMarkLevels = readonly [number, number, number, number, number];

const MIN_SCALE = 0.28;
const MAX_SCALE = 1.2;

/**
 * Per-bar scale for mapped level `a` (0..1) at time `t` seconds: a base that follows the
 * level plus a travelling sine that is bigger when louder. `calm` drops the sine
 * (prefers-reduced-motion).
 */
export function swellScales(a: number, t: number, calm = false): LandingMarkLevels {
  const scale = (i: number): number => {
    const wobble = calm ? 0 : Math.sin(t * (5 + 4 * a) * (1 + 0.13 * i) + 1.3 * i) * (0.05 + 0.2 * a);
    return Math.max(MIN_SCALE, Math.min(MAX_SCALE, 0.32 + 0.95 * a + wobble));
  };
  return [scale(0), scale(1), scale(2), scale(3), scale(4)];
}

/** Sets the five bar channels (scale around each bar's centre, 0.28 to 1.2). */
export function setLandingMarkLevels(el: SVGSVGElement, levels: LandingMarkLevels): void {
  levels.forEach((level, index) => el.style.setProperty(`--lm-${index}`, level.toFixed(3)));
}

/** Switches between the static mark (still, idle) and live (bars follow the levels). */
export function setLandingMarkState(el: SVGSVGElement, state: LandingMarkState): void {
  el.dataset.state = state;
}
