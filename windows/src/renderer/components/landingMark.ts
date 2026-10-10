/**
 * The Useful Voice mark: three round sound bars landing on a square-cut I-beam caret,
 * on the 24u grid from the logo board. Sizes under 20px use the hand-hinted 16u cut.
 * Styling and motion live in styles/components/landing-mark.css.
 */

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
  caret: string;
}

const CUT_24: Cut = {
  grid: 24,
  bars: [
    [1, 9, 3, 6],
    [6, 7, 3, 10],
    [11, 5, 3, 14],
  ],
  caret: 'M16 2h7v3h-2v14h2v3h-7v-3h2V5h-2z',
};

const CUT_16: Cut = {
  grid: 16,
  bars: [
    [1, 6, 2, 4],
    [4, 5, 2, 6],
    [7, 3, 2, 10],
  ],
  caret: 'M11 1h4v2h-1v10h1v2h-4v-2h1V3h-1z',
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

  const caret = document.createElementNS(SVG_NS, 'path');
  caret.classList.add('landing-mark-caret');
  caret.setAttribute('d', cut.caret);
  svg.append(caret);
  return svg;
}

/** Sets the three bar channels (scale around each bar's centre, about 0.3 to 1.35). */
export function setLandingMarkLevels(
  el: SVGSVGElement,
  levels: readonly [number, number, number],
): void {
  el.style.setProperty('--lm-a', levels[0].toFixed(3));
  el.style.setProperty('--lm-b', levels[1].toFixed(3));
  el.style.setProperty('--lm-c', levels[2].toFixed(3));
}

/** Switches between still, idle (caret blinks) and live (bars follow the levels). */
export function setLandingMarkState(el: SVGSVGElement, state: LandingMarkState): void {
  el.dataset.state = state;
}
