import { el } from '../components/dom.js';
import { navigate, render, state } from '../shell.js';

// ---- Insights ---------------------------------------------------------
//
// Windows has no insights data yet (UV-028). This page draws the final layout with
// empty tracks so nothing moves when the data arrives, and says so in one line. It
// never shows a number it does not have: the only figure is the daily goal, which is
// a setting.

type Range = '7d' | '30d' | 'all';

const RANGES: Array<[Range, string]> = [
  ['7d', '7 days'],
  ['30d', '30 days'],
  ['all', 'All time'],
];

let range: Range = '30d';
let heroObserver: ResizeObserver | null = null;

const SVG_NS = 'http://www.w3.org/2000/svg';
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const NOT_YET = 'Not yet';

function svg(tag: string, attrs: Record<string, string | number>, text?: string): SVGElement {
  const node = document.createElementNS(SVG_NS, tag);
  for (const [key, value] of Object.entries(attrs)) node.setAttribute(key, String(value));
  if (text !== undefined) node.textContent = text;
  return node;
}

/** German grouping: 2500 -> 2.500. */
function grouped(value: number): string {
  return Math.round(value).toLocaleString('de-DE');
}

function dayLabel(daysAgo: number): string {
  const date = new Date();
  date.setDate(date.getDate() - daysAgo);
  return `${date.getDate()}. ${MONTHS[date.getMonth()]}`;
}

export function headerActionsForInsights(): HTMLElement[] {
  return [
    el(
      'div',
      { class: 'segmented', role: 'group', 'aria-label': 'Range' } as never,
      ...RANGES.map(([value, label]) =>
        el(
          'button',
          {
            type: 'button',
            'aria-pressed': range === value ? 'true' : 'false',
            onclick: () => {
              range = value;
              render();
            },
          } as never,
          label,
        ),
      ),
    ),
  ];
}

export function renderInsightsPage(): HTMLElement {
  const goal = state.settings?.dailyWordGoal ?? 0;
  return el(
    'div',
    { class: 'insights-page page-wide' },
    hero(goal),
    el('div', { class: 'ins-row ins-row-goal' }, goalCard(goal), timeOfDayCard(), speedCard()),
    el('div', { class: 'ins-row ins-row-saved' }, timeSavedCard(), languagesCard()),
    el('div', { class: 'ins-row ins-row-cost' }, costCard(), topWordsCard()),
    quietStrip(),
  );
}

function tile(title: string, meta: string | null, ...body: Array<Node | null>): HTMLElement {
  return el(
    'section',
    { class: 'ins-tile', 'aria-label': title },
    el('header', { class: 'ins-th' }, el('h3', {}, title), meta ? el('span', { class: 'ins-meta' }, meta) : null),
    ...body,
  );
}

function bigFigure(value: string, caption: string): HTMLElement {
  return el(
    'div',
    { class: 'ins-big' },
    el('span', { class: 'ins-fig ins-mute' }, value),
    el('span', { class: 'ins-note' }, caption),
  );
}

// ---- Hero ---------------------------------------------------------------

function hero(goal: number): HTMLElement {
  return el(
    'section',
    { class: 'ins-hero', 'aria-label': 'Summary' },
    el(
      'div',
      { class: 'ins-hero-text' },
      el('p', { class: 'ins-statement' }, 'Your words add up here.'),
      el('p', { class: 'ins-sub' }, 'Insights arrive on Windows in a later update.'),
    ),
    heroChart(goal),
  );
}

/**
 * The chart is drawn at the width it is shown at. Scaling a fixed viewBox would
 * shrink the axis labels below the 11 px floor on a narrow window.
 */
function heroChart(goal: number): HTMLElement {
  // A repaint builds a new chart: the old one's observer has nothing left to watch.
  heroObserver?.disconnect();
  const holder = el('div', { class: 'ins-hero-chart' });
  const draw = (): void => {
    holder.replaceChildren(emptyChart(goal, Math.max(320, Math.round(holder.clientWidth || 440))));
  };
  draw();
  const observer = new ResizeObserver(() => {
    // The page was left or repainted: stop observing instead of redrawing a detached node.
    if (!holder.isConnected) {
      observer.disconnect();
      return;
    }
    draw();
  });
  observer.observe(holder);
  heroObserver = observer;
  return holder;
}

/** Ghost axes: grid lines and the date axis, with no data line. */
function emptyChart(goal: number, w: number): SVGElement {
  const h = 254;
  const left = 44;
  const right = 14;
  const top = 30;
  const bottom = 26;
  const ph = h - top - bottom;
  const root = svg('svg', {
    class: 'ins-chart',
    viewBox: `0 0 ${w} ${h}`,
    width: w,
    height: h,
    role: 'img',
    'aria-label': 'Words per day, not available yet',
  });
  // The scale comes from the goal setting, so the axis is real even with no data.
  const ticks: Array<[number, number]> = [[0, 0], [goal, 0.5], [goal * 2, 1]];
  for (const [value, frac] of ticks) {
    const y = top + ph * (1 - frac);
    root.append(svg('line', { class: 'ins-gl', x1: left, x2: w - right, y1: y, y2: y }));
    root.append(svg('text', { class: 'ins-ax', x: left - 10, y: y + 4, 'text-anchor': 'end' }, grouped(value)));
  }
  const baseline = top + ph;
  root.append(svg('line', { class: 'ins-fut', x1: left, x2: w - right, y1: baseline, y2: baseline }));
  const labels: Array<[number, string, string]> =
    range === 'all'
      ? [[left, 'First dictation', 'start'], [w - right, 'Today', 'end']]
      : range === '7d'
        ? [[left, dayLabel(6), 'start'], [left + (w - left - right) / 2, dayLabel(3), 'middle'], [w - right, 'Today', 'end']]
        : [[left, dayLabel(29), 'start'], [left + (w - left - right) / 2, dayLabel(14), 'middle'], [w - right, 'Today', 'end']];
  for (const [x, label, anchor] of labels) {
    root.append(svg('text', { class: 'ins-ax', x, y: h - 6, 'text-anchor': anchor }, label));
  }
  root.append(svg('text', { class: 'ins-as', x: w - right, y: 12, 'text-anchor': 'end' }, range === 'all' ? 'Words per week' : 'Words per day'));
  return root;
}

// ---- Row 2: goal and streak, time of day, speaking speed -----------------

function goalCard(goal: number): HTMLElement {
  const size = 176;
  const c = size / 2;
  const rings = svg('svg', {
    class: 'ins-rings',
    viewBox: `0 0 ${size} ${size}`,
    role: 'img',
    'aria-label': 'Daily goal and streak, not available yet',
  });
  for (const r of [76, 52]) rings.append(svg('circle', { class: 'ins-ring-track', cx: c, cy: c, r }));

  const goalLabel = goal > 0 ? 'Change goal' : 'Set a daily goal';
  const legend = el(
    'div',
    { class: 'ins-legend' },
    el(
      'div',
      { class: 'ins-li' },
      el('span', { class: 'ins-sw ins-k1' }),
      el('span', { class: 'ins-l' }, 'Daily goal'),
      el('span', { class: 'ins-v' }, goal > 0 ? grouped(goal) : 'Not set', goal > 0 ? el('small', {}, ' words') : null),
      el(
        'button',
        { class: 'ins-link', type: 'button', onclick: () => navigate('settings', 'general') } as never,
        goalLabel,
      ),
    ),
    el(
      'div',
      { class: 'ins-li' },
      el('span', { class: 'ins-sw ins-k2' }),
      el('span', { class: 'ins-l' }, 'Streak'),
      el('span', { class: 'ins-v ins-mute ins-v-quiet' }, NOT_YET),
    ),
  );
  const card = tile('Goal and streak', null, el('div', { class: 'ins-goal-body' }, rings, legend));
  card.classList.add('ins-s5');
  return card;
}

function timeOfDayCard(): HTMLElement {
  // Drawn at its shown size (not scaled) so the hour labels stay at 11 px.
  const size = 160;
  const c = size / 2;
  const r0 = 18;
  const rmax = 64;
  const radial = svg('svg', {
    class: 'ins-radial',
    viewBox: `0 0 ${size} ${size}`,
    role: 'img',
    'aria-label': 'Words by hour of day, not available yet',
  });
  for (let hour = 0; hour < 24; hour += 1) {
    radial.append(svg('path', { class: 'ins-track-fill', d: sector(c, c, r0, rmax, hour * 15 + 1.8, hour * 15 + 13.2) }));
  }
  for (const [hour, label] of [[0, '00'], [6, '06'], [12, '12'], [18, '18']] as const) {
    const [x, y] = polar(c, c, rmax + 10, hour * 15);
    radial.append(svg('text', { class: 'ins-ax ins-halo', x, y: y + 4, 'text-anchor': 'middle' }, label));
  }
  const card = tile(
    'Time of day',
    null,
    el('div', { class: 'ins-radial-body' }, bigFigure(NOT_YET, 'Busiest hour'), radial),
  );
  card.classList.add('ins-s4');
  return card;
}

function speedCard(): HTMLElement {
  const card = tile(
    'Speaking speed',
    null,
    bigFigure(NOT_YET, 'Words per minute'),
    el('p', { class: 'ins-note2 ins-push' }, 'Typing runs at about 40. Most people speak three times faster.'),
  );
  card.classList.add('ins-s3');
  return card;
}

// ---- Row 3 and 4 -----------------------------------------------------------

function emptyBar(label: string): HTMLElement {
  return el(
    'div',
    { class: 'ins-bar' },
    el('div', { class: 'ins-bar-label' }, el('span', {}, label)),
    el('div', { class: 'ins-bar-track' }),
  );
}

function timeSavedCard(): HTMLElement {
  const card = tile(
    'Time saved',
    'Same words, two ways',
    bigFigure(NOT_YET, "Time you didn't spend typing"),
    el('div', { class: 'ins-bars' }, emptyBar('Typing at 40 wpm'), emptyBar('Dictating')),
  );
  card.classList.add('ins-s7');
  return card;
}

function languagesCard(): HTMLElement {
  const card = tile(
    'Languages',
    null,
    bigFigure(NOT_YET, 'Dictations by language'),
    el('div', { class: 'ins-seg-track' }),
  );
  card.classList.add('ins-s5');
  return card;
}

function costCard(): HTMLElement {
  const card = tile(
    'Engine cost',
    'Estimate',
    bigFigure(NOT_YET, 'Deepgram Nova-3'),
    el('div', { class: 'ins-meter-track' }),
    el('p', { class: 'ins-foot' }, 'List prices. Your Deepgram invoice is the source of truth.'),
  );
  card.classList.add('ins-s5');
  return card;
}

function topWordsCard(): HTMLElement {
  const rows = [0, 1, 2, 3, 4].map(() => el('div', { class: 'ins-word-track' }));
  const card = tile(
    'Top words',
    'From your vocabulary',
    el('div', { class: 'ins-words' }, bigFigure(NOT_YET, 'Most said word'), el('div', { class: 'ins-word-list' }, ...rows)),
  );
  card.classList.add('ins-s7');
  return card;
}

function quietStrip(): HTMLElement {
  const items = ['Fixes applied', 'Longest dictation', 'Average dictation', 'Words in total'];
  return el(
    'div',
    { class: 'ins-quiet' },
    ...items.map((label) =>
      el('div', {}, el('span', { class: 'ins-qv' }, 'Not yet'), el('span', { class: 'ins-ql' }, label)),
    ),
  );
}

// ---- Geometry (the same maths as the board's generator) -----------------------

function polar(cx: number, cy: number, r: number, deg: number): [number, number] {
  const angle = ((deg - 90) * Math.PI) / 180;
  return [cx + r * Math.cos(angle), cy + r * Math.sin(angle)];
}

function sector(cx: number, cy: number, r0: number, r1: number, a0: number, a1: number): string {
  const [x0, y0] = polar(cx, cy, r1, a0);
  const [x1, y1] = polar(cx, cy, r1, a1);
  const [x2, y2] = polar(cx, cy, r0, a1);
  const [x3, y3] = polar(cx, cy, r0, a0);
  const f = (n: number): string => n.toFixed(2);
  return (
    `M${f(x0)},${f(y0)} A${r1},${r1} 0 0 1 ${f(x1)},${f(y1)} ` +
    `L${f(x2)},${f(y2)} A${r0},${r0} 0 0 0 ${f(x3)},${f(y3)} Z`
  );
}
