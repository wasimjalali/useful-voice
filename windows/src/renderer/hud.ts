import { api } from './api.js';
import { mountAnnouncer } from './components/announcer.js';
import { el, icon, ICONS } from './components/dom.js';
import { createLanguagePanel, LANGUAGE_PATHS } from './components/languagePicker.js';
import { createWaveform } from './components/waveform.js';
import {
  DEFAULT_HUD_ACCENT,
  errorTitle,
  fixLabel,
  formatClock,
  formatWords,
  hudLabel,
  type HudPlacement,
  type HudStyle,
  type HudWireFrame,
} from '../core/hudModel.js';
import type { HudAction } from '../preload/types.js';

// A frame from an older main process carries no placement or style.
const DEFAULT_PLACEMENT: HudPlacement = { kind: 'bottom' };
const DEFAULT_STYLE: HudStyle = { colorway: 'ink', accent: DEFAULT_HUD_ACCENT, systemDark: false };

// ---------------------------------------------------------------------------
// The two small windows that float over other apps share this entry: the HUD (a
// transparent capsule) and the language picker (`?panel=language`).
// ---------------------------------------------------------------------------

const ICON_PATHS = {
  check: LANGUAGE_PATHS.check,
  globe: LANGUAGE_PATHS.globe,
  close: ICONS.close,
  clipboard: 'M8 4h8v3H8zM8 5.5H6a1 1 0 0 0-1 1V20a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1V6.5a1 1 0 0 0-1-1h-2M9 14l2 2 4-4',
  alert: 'M12 9v4M12 17h.01M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z',
  micOff: 'M2 2l20 20M18.9 13.2A7.1 7.1 0 0 0 19 12v-2M5 10v2a7 7 0 0 0 12 5M15 9.3V5a3 3 0 0 0-5.7-1.3M9 9v3a3 3 0 0 0 5.1 2.1M12 19v3',
  wifiOff: 'M12 20h.01M8.5 16.4a5 5 0 0 1 7 0M2 8.8a15 15 0 0 1 4.2-2.6M10.7 5c4-.4 8.1.9 11.3 3.8M16.9 11.3a10 10 0 0 1 2.2 1.7M5 12.9a10 10 0 0 1 5.2-2.7M2 2l20 20',
};

export function mountHud(): void {
  if (new URLSearchParams(window.location.search).get('panel') === 'language') {
    mountLanguageWindow();
    return;
  }
  mountHudCapsule();
}

// ---------------------------------------------------------------------------
// HUD bubble
// ---------------------------------------------------------------------------

const SVG_NS = 'http://www.w3.org/2000/svg';

const clamp = (v: number, a = 0, b = 1): number => Math.min(b, Math.max(a, v));
const lerp = (a: number, b: number, p: number): number => a + (b - a) * p;
/** Progress of `t` between `a` and `b`, 0..1. */
const prog = (t: number, a: number, b: number): number => clamp((t - a) / (b - a));

/** A cubic-bezier easing, solved by bisection (the CSS curve, evaluated by the clock). */
function bez(x1: number, y1: number, x2: number, y2: number): (x: number) => number {
  return (x) => {
    if (x <= 0) return 0;
    if (x >= 1) return 1;
    let lo = 0;
    let hi = 1;
    let u = x;
    for (let i = 0; i < 18; i += 1) {
      u = (lo + hi) / 2;
      const cx = 3 * (1 - u) * (1 - u) * u * x1 + 3 * (1 - u) * u * u * x2 + u * u * u;
      if (cx < x) lo = u;
      else hi = u;
    }
    return 3 * (1 - u) * (1 - u) * u * y1 + 3 * (1 - u) * u * u * y2 + u * u * u;
  };
}
const EO = bez(0.22, 1, 0.36, 1);
const EI = bez(0.4, 0, 1, 1);

const ENTER_MS = 240;
const CHANGE_MS = 220;
/** The old row fades out over the first 90 ms of a state change; the new one follows. */
const OUT_MS = 90;
const FOLD_MS = 160;
const EXIT_MS = 180;
const CHIP_DELAY_MS = 80;
const CHIP_MS = 240;
const BLOOM_MS = 700;
const BLOOM_STAGGER_MS = 160;
const AURA_FADE_MS = 200;
/** Distance of the bubble's leading edge from the window edge, and of its bottom edge at the bottom. */
const EDGE = 28;
const BUBBLE_H = 30;
const CHIP_H = 22;
const SHIM_PERIOD_S = 1.5;

/** The check, drawn by trimming its stroke from 0 to 1. */
interface CheckMark {
  svg: SVGSVGElement;
  set(v: number): void;
}

function checkMark(size: number, strokeWidth: number): CheckMark {
  const svg = document.createElementNS(SVG_NS, 'svg');
  svg.setAttribute('width', String(size));
  svg.setAttribute('height', String(size));
  svg.setAttribute('viewBox', '0 0 16 16');
  svg.setAttribute('class', 'hud-check');
  svg.setAttribute('aria-hidden', 'true');
  const path = document.createElementNS(SVG_NS, 'path');
  path.setAttribute('d', 'M3.6 8.4 L6.7 11.4 L12.6 4.9');
  path.setAttribute('fill', 'none');
  path.setAttribute('stroke-width', String(strokeWidth));
  path.setAttribute('stroke-linecap', 'round');
  path.setAttribute('stroke-linejoin', 'round');
  path.setAttribute('pathLength', '1');
  path.setAttribute('stroke-dasharray', '1 1');
  svg.append(path);
  return {
    svg,
    set: (v) => {
      path.setAttribute('stroke-dashoffset', (1 - v).toFixed(3));
      path.style.opacity = v > 0.001 ? '1' : '0';
    },
  };
}

/** The working dots mark: three dots orbiting, fused by the goo filter. `null` = still, in a row. */
interface DotsMark {
  svg: SVGSVGElement;
  set(seconds: number | null): void;
}

function dotsMark(size: number): DotsMark {
  const svg = document.createElementNS(SVG_NS, 'svg');
  svg.setAttribute('width', String(size));
  svg.setAttribute('height', String(size));
  svg.setAttribute('viewBox', '-12 -12 24 24');
  svg.setAttribute('class', 'hud-dots-mark');
  svg.setAttribute('aria-hidden', 'true');
  const group = document.createElementNS(SVG_NS, 'g');
  group.setAttribute('filter', 'url(#uv-goo)');
  svg.append(group);
  const dots = [0, 1, 2].map(() => {
    const c = document.createElementNS(SVG_NS, 'circle');
    c.setAttribute('r', '3');
    group.append(c);
    return c;
  });
  return {
    svg,
    set: (t) => {
      const a = t === null ? 0 : (t * 2 * Math.PI) / 1.15;
      dots.forEach((c, k) => {
        if (t === null) {
          c.setAttribute('cx', ((k - 1) * 6.6).toFixed(2));
          c.setAttribute('cy', '0');
          c.setAttribute('r', '2.6');
          return;
        }
        const ph = a + k * 2.094;
        const r = 3.4 + 1.6 * Math.sin(t * 2.3 + k * 1.7);
        c.setAttribute('cx', (r * Math.cos(ph)).toFixed(2));
        c.setAttribute('cy', (r * Math.sin(ph)).toFixed(2));
        c.setAttribute('r', (2.3 + 0.9 * (0.5 + 0.5 * Math.sin(t * 4.7 + k * 2.2))).toFixed(2));
      });
    },
  };
}

/** The filter that makes overlapping dots fuse: blur 1, then an alpha threshold. */
function mountGooFilter(): void {
  const svg = document.createElementNS(SVG_NS, 'svg');
  svg.setAttribute('width', '0');
  svg.setAttribute('height', '0');
  svg.setAttribute('aria-hidden', 'true');
  svg.style.position = 'absolute';
  const filter = document.createElementNS(SVG_NS, 'filter');
  filter.setAttribute('id', 'uv-goo');
  filter.setAttribute('x', '-12');
  filter.setAttribute('y', '-12');
  filter.setAttribute('width', '24');
  filter.setAttribute('height', '24');
  filter.setAttribute('filterUnits', 'userSpaceOnUse');
  filter.setAttribute('color-interpolation-filters', 'sRGB');
  const blur = document.createElementNS(SVG_NS, 'feGaussianBlur');
  blur.setAttribute('stdDeviation', '1');
  const matrix = document.createElementNS(SVG_NS, 'feColorMatrix');
  matrix.setAttribute('values', '1 0 0 0 0  0 1 0 0 0  0 0 1 0 0  0 0 0 12 -4.4');
  filter.append(blur, matrix);
  const defs = document.createElementNS(SVG_NS, 'defs');
  defs.append(filter);
  svg.append(defs);
  document.body.append(svg);
}

/** One state's row. Its pieces that move are driven by the clock. */
interface Row {
  el: HTMLElement;
  /** Natural width, padding included: the width the bubble eases to. */
  width: number;
  /** When it was built, for the check's draw-in. */
  born: number;
  dot: HTMLElement | null;
  dots: DotsMark | null;
  shim: HTMLElement | null;
  check: CheckMark | null;
  checkDelay: number;
  checkMs: number;
}

const HEX_COLOR = /^#[0-9a-f]{6}$/i;

function mountHudCapsule(): void {
  document.body.classList.add('hud');
  const root = document.getElementById('root');
  if (!root) return;

  mountGooFilter();
  const capsule = el('div', { class: 'hud-capsule is-hidden', role: 'group' });
  const tail = el('div', { class: 'hud-tail' });
  const rings = [el('div', { class: 'hud-ring' }), el('div', { class: 'hud-ring' })];
  const aura = el('div', { class: 'hud-aura' });
  const body = el('div', { class: 'hud-body' }, tail, ...rings, aura, capsule);
  const anchor = el('div', { class: 'hud-anchor' }, body);
  const chip = el('div', { class: 'hud-chip', 'aria-hidden': 'true' });
  const stage = el(
    'div',
    { class: 'hud-stage', 'data-place': 'bottom', 'data-colorway': 'ink', 'data-dark': 'false' },
    anchor,
    chip,
  );
  root.append(stage);
  mountAnnouncer();

  const reduceQuery = window.matchMedia('(prefers-reduced-motion: reduce)');

  /** The frame the bubble currently draws: the only state, always replaced whole. */
  let frame: HudWireFrame | null = null;
  let place: HudPlacement = DEFAULT_PLACEMENT;
  let lastAppearance = 0;
  /** A frame stream is on screen (false once main says there is no view, while the exit plays). */
  let active = false;
  /** The bubble is folded away (or was never shown): only the done chip may be visible. */
  let folded = true;
  let enterAt: number | null = null;
  let foldAt: number | null = -1e9;
  let exitAt: number | null = null;
  let bloomAt: number | null = null;
  let chipAt: number | null = null;
  let chipCheck: CheckMark | null = null;
  let cur: Row | null = null;
  let prev: Row | null = null;
  let changeAt = 0;
  let wFrom = 0;
  let wTo = 0;
  let wAt = 0;
  let wDur = 0;
  let auraK = 0;
  let auraLevel = 0;
  let lastTick = 0;
  let raf = 0;
  let dragging = false;
  /** The timer of the recording view, patched in place while it lives. */
  let live: { time: HTMLElement; stops: HTMLElement | null } | null = null;
  /** The scrolling waveform of the recording view; it runs only while that view is on screen. */
  const wave = createWaveform({ bars: 16, width: 44, height: 14, minHeight: 2, opacity: 'level' });

  api.onHudView((next) => render(next as HudWireFrame | null));
  api.onLevel((level) => wave.push(level));

  // ---- the one render path -------------------------------------------------

  function render(next: HudWireFrame | null): void {
    if (next === null) {
      leave();
      return;
    }
    applyStyle(next.style ?? DEFAULT_STYLE);
    // Same seq is an update in place, unless the window moved (placement) or a new appearance began.
    const moved = JSON.stringify(next.placement ?? DEFAULT_PLACEMENT) !== JSON.stringify(place);
    const newAppearance = next.appearance !== undefined && next.appearance !== lastAppearance;
    if (frame && frame.seq === next.seq && !moved && !newAppearance) {
      patch(next);
      return;
    }
    build(next);
  }

  function applyStyle(style: HudStyle): void {
    stage.dataset.colorway = style.colorway;
    stage.dataset.dark = style.systemDark ? 'true' : 'false';
    stage.style.setProperty('--cw-accent', HEX_COLOR.test(style.accent) ? style.accent : DEFAULT_STYLE.accent);
  }

  /** Window geometry: the anchor point and the way the bubble grows from it. */
  function applyPlacement(): void {
    const w = stage.clientWidth;
    const h = stage.clientHeight;
    const key = place.kind === 'bottom' ? 'bottom' : place.flipped ? 'caret-flip' : 'caret';
    stage.dataset.place = key;
    tail.hidden = place.kind === 'bottom';
    if (place.kind === 'bottom') {
      anchor.style.left = `${w / 2}px`;
      anchor.style.top = `${h - EDGE - BUBBLE_H}px`;
      anchor.style.transformOrigin = '0 15px';
    } else {
      anchor.style.left = `${place.flipped ? w - EDGE : EDGE}px`;
      anchor.style.top = `${(h - BUBBLE_H) / 2}px`;
      anchor.style.transformOrigin = place.flipped ? '6px 15px' : '-6px 15px';
    }
    chip.style.top = `${(h - CHIP_H) / 2}px`;
    chip.style.transformOrigin = place.kind === 'caret' && place.flipped ? '100% 50%' : '0 50%';
  }

  function build(next: HudWireFrame): void {
    const t = performance.now();
    const wasActive = active;
    const nextPlace = next.placement ?? DEFAULT_PLACEMENT;
    // A frame with a new `appearance` is a new dictation on screen; a moved placement re-enters on its new side.
    // A frame from an older main process carries no appearance number.
    const appearance = next.appearance ?? lastAppearance;
    const reenter = appearance !== lastAppearance || JSON.stringify(nextPlace) !== JSON.stringify(place);
    lastAppearance = appearance;
    place = nextPlace;
    applyPlacement();

    frame = next;
    live = null;
    wave.stop();
    active = true;
    exitAt = null;
    if (!wasActive) {
      cur = null;
      prev = null;
      capsule.replaceChildren();
      capsule.classList.add('is-hidden');
      hideChip();
    }
    capsule.setAttribute('aria-label', hudLabel(next));
    capsule.dataset.kind = next.kind;
    if (next.kind === 'error') capsule.title = next.error.message;
    else capsule.removeAttribute('title');

    const caret = place.kind === 'caret';
    if (caret && (next.kind === 'inserting' || next.kind === 'saving' || next.kind === 'done')) {
      // The bubble folds into the cursor (its transcribing row stays while it folds).
      if (!folded) {
        foldAt = t;
        folded = true;
      }
      if (next.kind === 'done') showChip(next, t);
      else hideChip();
      ensureLoop();
      return;
    }

    hideChip();
    const row = buildRow(next, t);
    if (!wasActive || folded || reenter) {
      // A new appearance, or a bubble state after the fold: it enters.
      capsule.replaceChildren(row.el);
      capsule.classList.remove('is-hidden');
      row.el.style.opacity = '1';
      cur = row;
      prev = null;
      changeAt = t;
      wFrom = row.width;
      wTo = row.width;
      wDur = 0;
      folded = false;
      foldAt = null;
      enterAt = t;
      anchor.style.opacity = '0';
      bloomAt = next.kind === 'recording' ? t : null;
    } else {
      // A state change: the old row fades, the new follows, the width eases.
      prev?.el.remove();
      prev = cur;
      if (prev) {
        prev.el.classList.add('is-leaving');
        prev.el.setAttribute('aria-hidden', 'true');
      }
      cur = row;
      capsule.append(row.el);
      changeAt = t;
      retarget(row.width, t, CHANGE_MS);
    }
    ensureLoop();
  }

  /** The recording view updates in place: the ticking timer must not rebuild the bubble. */
  function patch(next: HudWireFrame): void {
    frame = next;
    capsule.setAttribute('aria-label', hudLabel(next));
    if (next.kind !== 'recording' || !live || !cur) return;
    live.time.textContent = formatClock(next.elapsedSeconds);
    if (next.stopsIn !== undefined) {
      const text = `Stops in ${next.stopsIn} s`;
      if (live.stops) {
        live.stops.textContent = text;
      } else {
        live.stops = el('span', { class: 'hud-stops' }, text);
        live.time.after(live.stops);
      }
    } else if (live.stops) {
      live.stops.remove();
      live.stops = null;
    }
    const width = cur.el.offsetWidth;
    if (Math.abs(width - cur.width) > 0.5) {
      cur.width = width;
      retarget(width, performance.now(), CHANGE_MS);
    }
  }

  function leave(): void {
    if (!active) return;
    active = false;
    frame = null;
    live = null;
    wave.stop();
    exitAt = performance.now();
    ensureLoop();
  }

  /** Everything is gone: nothing is left on screen and the clock stops. */
  function finishHide(): void {
    cur = null;
    prev = null;
    capsule.replaceChildren();
    capsule.classList.add('is-hidden');
    capsule.removeAttribute('title');
    anchor.style.opacity = '0';
    anchor.classList.remove('is-live');
    for (const node of [...rings, aura]) node.style.opacity = '0';
    hideChip();
    exitAt = null;
    enterAt = null;
    bloomAt = null;
    folded = true;
    foldAt = -1e9;
    auraK = 0;
  }

  // ---- rows ----------------------------------------------------------------

  /** A line icon for the bubble: a little heavier than the app's 1.6 stroke, which would thin out at 12 px. */
  function hudIcon(path: string, size: number): SVGSVGElement {
    const svg = icon(path, size);
    svg.setAttribute('stroke-width', '2.2');
    return svg;
  }

  function button(className: string, label: string, action: HudAction, ...children: Array<Node | string>): HTMLButtonElement {
    const node = el('button', { class: className, type: 'button', 'aria-label': label }, ...children);
    node.addEventListener('click', () => void api.hudAction(action));
    return node;
  }

  function closeButton(): HTMLButtonElement {
    const x = hudIcon(ICON_PATHS.close, 9);
    x.setAttribute('stroke-width', '3');
    return button('hud-x', 'Dismiss', 'dismiss', x);
  }

  function buildRow(view: HudWireFrame, t: number): Row {
    const row: Row = { el: el('div', { class: 'hud-inner' }), width: 0, born: t, dot: null, dots: null, shim: null, check: null, checkDelay: 0, checkMs: 0 };
    const bottom = place.kind === 'bottom';
    const add = (...children: Array<Node | string | null>): void => {
      for (const child of children) if (child !== null) row.el.append(child);
    };
    const working = (label: string, shimmer: boolean): void => {
      row.dots = dotsMark(16);
      row.dots.set(null);
      const text = el('span', shimmer ? { class: 'hud-shim' } : {}, label);
      if (shimmer) row.shim = text;
      add(row.dots.svg, text);
    };
    switch (view.kind) {
      case 'recording': {
        wave.start();
        row.dot = el('span', { class: 'hud-dot' });
        const time = el('span', { class: 'hud-time', 'aria-hidden': 'true' }, formatClock(view.elapsedSeconds));
        const stops = view.stopsIn !== undefined ? el('span', { class: 'hud-stops' }, `Stops in ${view.stopsIn} s`) : null;
        live = { time, stops };
        add(row.dot, wave.element, time, stops, bottom ? el('kbd', { class: 'hud-kbd' }, 'esc') : null);
        break;
      }
      case 'transcribing':
        working('Transcribing', true);
        break;
      case 'inserting':
        working('Inserting', false);
        break;
      case 'saving':
        working('Saving', false);
        break;
      case 'done':
        // Caret placement shows the chip instead; this row is the bottom bubble's.
        row.check = checkMark(14, 1.9);
        row.checkDelay = 110;
        row.checkMs = 300;
        add(row.check.svg, el('span', {}, view.saved ? 'Saved and copied' : 'Inserted', el('span', { class: 'hud-dim' }, ` · ${formatWords(view.words)}`)));
        break;
      case 'copied':
        row.el.classList.add('has-x');
        add(hudIcon(ICON_PATHS.clipboard, 12), 'Copied. Press Ctrl+V to paste', closeButton());
        break;
      case 'cancelled':
        add(hudIcon(ICON_PATHS.close, 12), 'Cancelled');
        break;
      case 'error': {
        const glyph =
          view.error.kind === 'micUnavailable' ? ICON_PATHS.micOff : view.error.kind === 'offline' ? ICON_PATHS.wifiOff : ICON_PATHS.alert;
        const label = fixLabel(view.error);
        const fix = view.error.fix;
        row.el.classList.add('has-x');
        add(
          hudIcon(glyph, 12),
          errorTitle(view.error),
          label && fix ? button('hud-btn', label, fix === 'retry' ? 'retry' : fix, label) : null,
          closeButton(),
        );
        break;
      }
      case 'language':
        add(hudIcon(ICON_PATHS.globe, 12), el('span', { dir: 'auto' }, view.name));
        break;
    }
    // Measured while it is in the bubble: an absolutely placed row is as wide as its content.
    capsule.append(row.el);
    row.width = row.el.offsetWidth;
    row.el.remove();
    return row;
  }

  // ---- the done chip (caret placement) --------------------------------------

  function showChip(view: Extract<HudWireFrame, { kind: 'done' }>, t: number): void {
    const mark = checkMark(14, 1.9);
    mark.set(0);
    const words = formatWords(view.words);
    chip.replaceChildren(mark.svg, el('span', {}, view.saved ? `Copied · ${words}` : words));
    const width = chip.offsetWidth;
    const flipped = place.kind === 'caret' && place.flipped;
    chip.style.left = `${flipped ? stage.clientWidth - EDGE - width : EDGE}px`;
    chip.style.opacity = '0';
    chipCheck = mark;
    chipAt = t;
  }

  function hideChip(): void {
    chipAt = null;
    chipCheck = null;
    chip.style.opacity = '0';
    chip.style.transform = '';
    chip.replaceChildren();
  }

  // ---- the clock -----------------------------------------------------------

  function currentWidth(t: number): number {
    return wDur > 0 ? lerp(wFrom, wTo, EO(prog(t, wAt, wAt + wDur))) : wTo;
  }

  function retarget(to: number, t: number, duration: number): void {
    wFrom = currentWidth(t);
    wTo = to;
    wAt = t;
    wDur = reduceQuery.matches ? 0 : duration;
  }

  function ensureLoop(): void {
    if (raf) return;
    lastTick = performance.now();
    raf = requestAnimationFrame(tick);
  }

  function animateRow(row: Row, t: number, reduce: boolean): void {
    const s = t / 1000;
    row.dots?.set(reduce ? null : s);
    if (row.shim) {
      row.shim.classList.toggle('is-still', reduce);
      row.shim.style.backgroundPosition = `${(100 - (((s % SHIM_PERIOD_S) / SHIM_PERIOD_S) * 100)).toFixed(1)}% 0`;
    }
    if (row.dot) row.dot.style.opacity = reduce ? '1' : (0.85 + 0.15 * Math.cos((s * 2 * Math.PI) / 1.1)).toFixed(3);
    row.check?.set(reduce ? 1 : EO(prog(t - row.born, row.checkDelay, row.checkDelay + row.checkMs)));
  }

  /** One frame of everything that moves, computed from the timestamp alone. */
  function tick(t: number): void {
    raf = 0;
    const reduce = reduceQuery.matches;
    const dt = clamp(t - lastTick, 0, 100);
    lastTick = t;

    // The anchor: enter, fold, exit.
    const a = enterAt === null ? 1 : EO(prog(t, enterAt, enterAt + ENTER_MS));
    const x = foldAt === null ? 0 : EI(prog(t, foldAt, foldAt + FOLD_MS));
    const y = exitAt === null ? 0 : EI(prog(t, exitAt, exitAt + EXIT_MS));
    const opacity = a * (1 - x) * (1 - y);
    anchor.style.opacity = opacity.toFixed(3);
    anchor.classList.toggle('is-live', active && !folded);
    if (reduce) {
      anchor.style.transform = '';
    } else if (place.kind === 'bottom') {
      anchor.style.transform = `translateY(${((1 - a) * 6 + y * 6).toFixed(2)}px) scale(${(lerp(0.6, 1, a) * lerp(1, 0.96, y)).toFixed(4)})`;
    } else {
      const dir = place.flipped ? -1 : 1;
      anchor.style.transform = `translateX(${((1 - a) * -4 * dir).toFixed(2)}px) scale(${(lerp(0.3, 1, a) * lerp(1, 0.2, x) * lerp(1, 0.9, y)).toFixed(4)})`;
    }

    // The bubble's width, grown away from the tail (from the centre at the bottom).
    const w = currentWidth(t);
    const factor = place.kind === 'bottom' ? 0.5 : place.flipped ? 1 : 0;
    body.style.width = `${w.toFixed(2)}px`;
    body.style.left = `${(-w * factor).toFixed(2)}px`;

    // Rows: the old one fades out first, then the new one in.
    const e = t - changeAt;
    if (prev) {
      if (reduce || e >= CHANGE_MS) {
        prev.el.remove();
        prev = null;
      } else {
        prev.el.style.opacity = (1 - EI(prog(e, 0, OUT_MS))).toFixed(3);
      }
    }
    if (cur) cur.el.style.opacity = prev ? EO(prog(e - OUT_MS, 0, CHANGE_MS - OUT_MS)).toFixed(3) : '1';
    if (cur) animateRow(cur, t, reduce);
    if (prev) animateRow(prev, t, reduce);

    // Halo: the bloom rings once on entry, the aura while recording.
    if (bloomAt !== null) {
      if (reduce || t > bloomAt + BLOOM_STAGGER_MS + BLOOM_MS) {
        bloomAt = null;
        for (const ring of rings) ring.style.opacity = '0';
      } else {
        rings.forEach((ring, k) => {
          const p = prog(t, bloomAt! + k * BLOOM_STAGGER_MS, bloomAt! + k * BLOOM_STAGGER_MS + BLOOM_MS);
          const eased = EO(p);
          const d = 12 * eased;
          ring.style.inset = `${-d}px`;
          ring.style.borderRadius = `${15 + d}px`;
          ring.style.opacity = p > 0 && p < 1 ? (0.55 * (1 - eased)).toFixed(3) : '0';
        });
      }
    }
    const recording = active && frame?.kind === 'recording';
    const auraTarget = recording && !reduce ? 1 : 0;
    auraK = auraTarget > auraK ? Math.min(1, auraK + dt / AURA_FADE_MS) : Math.max(0, auraK - dt / AURA_FADE_MS);
    if (recording) auraLevel = wave.level();
    const level = auraLevel;
    // A soft glow: the bubble's shape grown by 1 + 3 x level, blurred, behind the bubble.
    const spread = 1 + 3 * level;
    aura.style.inset = `${-spread}px`;
    aura.style.borderRadius = `${15 + spread}px`;
    aura.style.filter = `blur(${(5 + 5 * level).toFixed(1)}px)`;
    aura.style.opacity = ((0.18 + 0.37 * level) * auraK).toFixed(3);

    // The done chip beside the cursor.
    if (chipAt !== null) {
      const b = EO(prog(t, chipAt + CHIP_DELAY_MS, chipAt + CHIP_DELAY_MS + CHIP_MS));
      chip.style.opacity = (b * (1 - y)).toFixed(3);
      chip.style.transform = reduce ? '' : `scale(${lerp(0.7, 1, b).toFixed(3)})`;
      chipCheck?.set(reduce ? 1 : EO(prog(t - chipAt, 120, 400)));
    }

    if (exitAt !== null && t >= exitAt + EXIT_MS) {
      finishHide();
      return;
    }
    if (active || exitAt !== null) raf = requestAnimationFrame(tick);
  }

  // ---- pointer and drag ----------------------------------------------------

  // The window ignores the mouse except over the bubble; pressing on the bubble (not a
  // button) and moving drags the window, in bottom placement only. Main remembers where it
  // was left, per display.
  let pendingMove: { x: number; y: number } | null = null;
  capsule.addEventListener('pointerenter', () => api.hudPointer(true));
  capsule.addEventListener('pointerleave', () => {
    if (!dragging) api.hudPointer(false);
  });
  capsule.addEventListener('pointerdown', (event) => {
    if (place.kind !== 'bottom' || event.button !== 0 || (event.target as Element).closest('button')) return;
    dragging = true;
    capsule.setPointerCapture(event.pointerId);
    capsule.classList.add('is-dragging');
    api.hudDrag('start', event.screenX, event.screenY);
  });
  capsule.addEventListener('pointermove', (event) => {
    if (!dragging) return;
    const first = pendingMove === null;
    pendingMove = { x: event.screenX, y: event.screenY };
    if (first) {
      requestAnimationFrame(() => {
        if (pendingMove) api.hudDrag('move', pendingMove.x, pendingMove.y);
        pendingMove = null;
      });
    }
  });
  const endDrag = (event: PointerEvent): void => {
    if (!dragging) return;
    dragging = false;
    pendingMove = null;
    capsule.classList.remove('is-dragging');
    api.hudDrag('end', event.screenX, event.screenY);
    // Released away from the bubble (it follows the pointer, so rarely): click-through again.
    if (!capsule.matches(':hover')) api.hudPointer(false);
  };
  capsule.addEventListener('pointerup', endDrag);
  capsule.addEventListener('pointercancel', endDrag);
}


// ---------------------------------------------------------------------------
// Language picker window
// ---------------------------------------------------------------------------

/**
 * The floating picker. The main process shows this window focused (the search field has to
 * take keys), records the window that was in front and puts focus back on it when the picker
 * closes on a choice or Esc, and hides the window on a click elsewhere too. Each open resets the search and re-reads the pin.
 */
function mountLanguageWindow(): void {
  document.body.classList.add('lang-window');
  const root = document.getElementById('root');
  if (!root) return;

  const panel = createLanguagePanel({
    value: 'auto',
    onChoose: (value) => void api.pickerChoose(value),
    onClose: () => void api.pickerClose(),
  });
  root.append(panel.element);

  const open = async (): Promise<void> => {
    const settings = await api.getSettings();
    // Replay the enter animation on every open, not only the first.
    panel.element.style.animation = 'none';
    void panel.element.offsetWidth;
    panel.element.style.animation = '';
    panel.open(settings.languagePin);
  };
  api.onOpenLanguagePicker(() => void open());
  void open();
}
