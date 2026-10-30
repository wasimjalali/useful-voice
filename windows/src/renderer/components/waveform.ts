import { LEVEL_METER_GAIN } from '../../core/audio/wav.js';

/**
 * Mic level to picture. The meter level the main process sends is `min(1, rms * LEVEL_METER_GAIN)`,
 * so the raw RMS is recovered here and mapped on a dB scale: -52 dB is empty, -16 dB is full.
 */
const FLOOR_DB = -52;
const RANGE_DB = 36;
const ATTACK_MS = 35;
const RELEASE_MS = 160;

/** Maps a meter level (0 to 1, see LEVEL_METER_GAIN) to 0..1 on the dB scale. */
export function mapLevel(meterLevel: number): number {
  const rms = Math.max(0, meterLevel) / LEVEL_METER_GAIN;
  const db = 20 * Math.log10(Math.max(rms, 1e-6));
  return Math.max(0, Math.min(1, (db - FLOOR_DB) / RANGE_DB));
}

/** A smoothed level: fast to rise, slow to fall. Feed it levels, step it once per frame. */
export interface LevelSmoother {
  /** Sets the latest meter level (0 to 1). */
  push(meterLevel: number): void;
  /** Advances by `dtMs` and returns the smoothed 0..1 value. */
  step(dtMs: number): number;
  reset(): void;
}

export function createLevelSmoother(): LevelSmoother {
  let target = 0;
  let v = 0;
  return {
    push: (meterLevel) => {
      target = Number.isFinite(meterLevel) ? mapLevel(meterLevel) : 0;
    },
    step: (dtMs) => {
      const tau = target > v ? ATTACK_MS : RELEASE_MS;
      v += (target - v) * (1 - Math.exp(-dtMs / tau));
      return v;
    },
    reset: () => {
      target = 0;
      v = 0;
    },
  };
}

// ---------------------------------------------------------------------------
// The scrolling waveform of the HUD pill
// ---------------------------------------------------------------------------

const SVG_NS = 'http://www.w3.org/2000/svg';
const BAR_W = 2;
const PUSH_MS = 50;

export interface WaveformOptions {
  /** Number of bars; default 30. */
  bars?: number;
  /** Box size in px; default 104 x 28. */
  width?: number;
  height?: number;
  /** Height of a silent bar; default 3. */
  minHeight?: number;
  /** `position`: older bars are dimmer (default). `level`: a bar's opacity follows its own level, 0.45 to 1. */
  opacity?: 'position' | 'level';
}

export interface Waveform {
  element: SVGSVGElement;
  /** Feeds the latest meter level (0 to 1). */
  push(meterLevel: number): void;
  /** The smoothed level (0..1) of the latest frame, for effects that follow the voice. */
  level(): number;
  /** Starts the animation loop with an empty history; `stop` ends it. */
  start(): void;
  stop(): void;
}

/** Scrolling bars of 2 px: every 50 ms the smoothed level enters on the right. Defaults: 30 bars in 104 x 28 px. */
export function createWaveform(options: WaveformOptions = {}): Waveform {
  const BARS = options.bars ?? 30;
  const WIDTH = options.width ?? 104;
  const HEIGHT = options.height ?? 28;
  const MIN_H = options.minHeight ?? 3;
  const byLevel = options.opacity === 'level';
  const OLDEST_OPACITY = byLevel ? 0.45 : 0.35;

  const svg = document.createElementNS(SVG_NS, 'svg');
  svg.setAttribute('viewBox', `0 0 ${WIDTH} ${HEIGHT}`);
  svg.setAttribute('width', String(WIDTH));
  svg.setAttribute('height', String(HEIGHT));
  svg.setAttribute('fill', 'currentColor');
  svg.setAttribute('aria-hidden', 'true');
  svg.classList.add('waveform');

  const gap = (WIDTH - BARS * BAR_W) / (BARS - 1);
  const rects: SVGRectElement[] = [];
  for (let i = 0; i < BARS; i += 1) {
    const rect = document.createElementNS(SVG_NS, 'rect');
    rect.setAttribute('x', (i * (BAR_W + gap)).toFixed(3));
    rect.setAttribute('width', String(BAR_W));
    rect.setAttribute('rx', '1');
    svg.append(rect);
    rects.push(rect);
  }

  const smoother = createLevelSmoother();
  let history: number[] = new Array<number>(BARS).fill(0);
  let frame = 0;
  let last = 0;
  let sincePush = 0;
  let current = 0;

  const paint = (): void => {
    rects.forEach((rect, i) => {
      const v = history[i] ?? 0;
      const h = MIN_H + (HEIGHT - MIN_H) * v;
      rect.setAttribute('y', ((HEIGHT - h) / 2).toFixed(2));
      rect.setAttribute('height', h.toFixed(2));
      const opacity = byLevel
        ? OLDEST_OPACITY + (1 - OLDEST_OPACITY) * v
        : OLDEST_OPACITY + ((1 - OLDEST_OPACITY) * i) / (BARS - 1);
      rect.setAttribute('opacity', opacity.toFixed(3));
    });
  };

  const tick = (now: number): void => {
    const dt = Math.min(100, now - last);
    last = now;
    current = smoother.step(dt);
    sincePush += dt;
    if (sincePush >= PUSH_MS) {
      sincePush -= PUSH_MS;
      history = [...history.slice(1), current];
      paint();
    }
    frame = requestAnimationFrame(tick);
  };

  paint();
  return {
    element: svg,
    push: (meterLevel) => smoother.push(meterLevel),
    level: () => current,
    start: () => {
      cancelAnimationFrame(frame);
      smoother.reset();
      history = new Array<number>(BARS).fill(0);
      sincePush = 0;
      current = 0;
      last = performance.now();
      paint();
      frame = requestAnimationFrame(tick);
    },
    stop: () => cancelAnimationFrame(frame),
  };
}
