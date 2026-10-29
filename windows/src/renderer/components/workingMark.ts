/**
 * The in-progress marks: three fusing dots, the shimmer label and the self-drawing
 * check. Same recipes as the macOS HUD parts (HUDParts.swift). Calm under reduced
 * motion: still dots, plain label, a check that is already drawn.
 */

const SVG_NS = 'http://www.w3.org/2000/svg';
const DOTS_PERIOD = 1.15;
const FILTER_ID = 'uv-working-goo';

function calm(): boolean {
  return window.matchMedia('(prefers-reduced-motion: reduce)').matches;
}

function svg(tag: string, attrs: Record<string, string>): SVGElement {
  const node = document.createElementNS(SVG_NS, tag);
  for (const [key, value] of Object.entries(attrs)) node.setAttribute(key, value);
  return node;
}

/** One shared goo filter: blur, then threshold the alpha so overlapping dots fuse. */
function gooFilter(): SVGSVGElement {
  const defs = svg('svg', { width: '0', height: '0', 'aria-hidden': 'true', focusable: 'false' }) as SVGSVGElement;
  defs.style.position = 'absolute';
  const filter = svg('filter', { id: FILTER_ID, x: '-50%', y: '-50%', width: '200%', height: '200%' });
  filter.append(
    svg('feGaussianBlur', { in: 'SourceGraphic', stdDeviation: '1', result: 'b' }),
    svg('feColorMatrix', { in: 'b', type: 'matrix', values: '1 0 0 0 0  0 1 0 0 0  0 0 1 0 0  0 0 0 12 -4.4' }),
  );
  defs.append(svg('defs', {}));
  defs.firstChild?.appendChild(filter);
  return defs;
}

/** The working dots: a 24 box drawn at 16 px, in the current text colour. */
export function createWorkingDots(size = 16): HTMLElement {
  const wrap = document.createElement('span');
  wrap.className = 'working-dots';
  wrap.setAttribute('aria-hidden', 'true');
  wrap.style.width = `${size}px`;
  wrap.style.height = `${size}px`;
  wrap.append(gooFilter());

  const mark = svg('svg', { viewBox: '-12 -12 24 24', width: String(size), height: String(size) }) as SVGSVGElement;
  const group = svg('g', { filter: `url(#${FILTER_ID})`, fill: 'currentColor' });
  const circles = [0, 1, 2].map(() => svg('circle', { cx: '0', cy: '0', r: '2.4' }));
  group.append(...circles);
  mark.append(group);
  wrap.append(mark);

  const place = (t: number, still: boolean): void => {
    circles.forEach((circle, k) => {
      if (still) {
        circle.setAttribute('cx', String((k - 1) * 6));
        circle.setAttribute('cy', '0');
        circle.setAttribute('r', '2.4');
        return;
      }
      const ph = (t * 2 * Math.PI) / DOTS_PERIOD + k * 2.094;
      const orbit = 3.4 + 1.6 * Math.sin(2.3 * t + 1.7 * k);
      circle.setAttribute('cx', (orbit * Math.cos(ph)).toFixed(3));
      circle.setAttribute('cy', (orbit * Math.sin(ph)).toFixed(3));
      circle.setAttribute('r', (2.3 + 0.9 * (0.5 + 0.5 * Math.sin(4.7 * t + 2.2 * k))).toFixed(3));
    });
  };

  if (calm()) {
    place(0, true);
    return wrap;
  }
  place(0, false);
  // Runs only while the mark is on screen; a rebuilt dock disconnects it and the loop ends.
  const tick = (now: number): void => {
    if (!wrap.isConnected) return;
    place(now / 1000, false);
    requestAnimationFrame(tick);
  };
  // The wrap is attached after this returns, so the first frame waits for it.
  requestAnimationFrame(tick);
  return wrap;
}

/** A label at half ink with a full-ink band sweeping left to right (see workingMark.css). */
export function createShimmerLabel(text: string): HTMLElement {
  const label = document.createElement('b');
  label.className = 'working-shimmer';
  label.textContent = text;
  return label;
}

/** A check that draws itself once when it appears. */
export function createDrawnCheck(size = 14): SVGSVGElement {
  const mark = svg('svg', { viewBox: '0 0 16 16', width: String(size), height: String(size), fill: 'none', stroke: 'currentColor', 'stroke-width': '1.9', 'stroke-linecap': 'round', 'stroke-linejoin': 'round', 'aria-hidden': 'true' }) as SVGSVGElement;
  mark.classList.add('working-check');
  mark.append(svg('path', { d: 'M3.6 8.4 L6.7 11.4 L12.6 4.9', pathLength: '1' }));
  return mark;
}
