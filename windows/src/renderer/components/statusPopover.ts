import { api } from '../api.js';
import { el, icon } from './dom.js';
import type { DictationError } from '../../preload/types.js';

/**
 * The rail's status button and its health popover.
 *
 * Everything the app can say about its own health comes from one `HealthInput`, so the
 * button, the popover and the window banners (components/banners.ts) never disagree.
 * Every state carries a glyph and a word, so it never relies on hue alone.
 */

export interface HealthInput {
  hasApiKey: boolean;
  /** The last dictation error, until the next dictation starts or succeeds. */
  lastError: DictationError | null;
  /** The OS microphone permission, when the renderer can read it. */
  micDenied: boolean;
  /** The last hotkey dictation was copied because Windows blocked the paste. */
  pasteBlocked: boolean;
  saveStatus: { ok: boolean; message?: string };
}

export type Tone = 'ok' | 'warn' | 'bad';
export type Overall = 'ready' | 'needs' | 'problem';

export interface HealthRow {
  label: string;
  tone: Tone;
  text: string;
  fix?: { label: string; run: () => void };
}

export interface Health {
  overall: Overall;
  engine: HealthRow;
  microphone: HealthRow;
}

const GLYPH = {
  ready: 'M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18zM8 12.5l3 3 5-6',
  needs: 'M12 9v4M12 17h.01M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z',
  problem: 'M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18zM9 9l6 6M15 9l-6 6',
} as const;

const WORD: Record<Overall, string> = { ready: 'Ready', needs: 'Needs access', problem: 'Problem' };
const TONE: Record<Overall, Tone> = { ready: 'ok', needs: 'warn', problem: 'bad' };

export const MIC_SETTINGS_URL = 'ms-settings:privacy-microphone';

export function micOff(input: HealthInput): boolean {
  return input.micDenied || input.lastError?.kind === 'micUnavailable';
}

export function computeHealth(input: HealthInput, goToEngine: () => void): Health {
  const kind = input.lastError?.kind;
  let engine: HealthRow;
  if (!input.hasApiKey) {
    engine = { label: 'Engine', tone: 'warn', text: 'No key', fix: { label: 'Add key', run: goToEngine } };
  } else if (kind === 'keyRejected') {
    engine = { label: 'Engine', tone: 'bad', text: 'Key rejected', fix: { label: 'Open Engine settings', run: goToEngine } };
  } else if (kind === 'outOfCredits') {
    engine = { label: 'Engine', tone: 'bad', text: 'Out of credits', fix: { label: 'Open Engine settings', run: goToEngine } };
  } else if (kind === 'timedOut' || kind === 'providerFailed') {
    engine = {
      label: 'Engine',
      tone: 'bad',
      text: kind === 'timedOut' ? 'Timed out' : 'Not responding',
      // Retry only when the error carries a retry fix: a failure without retained audio has none.
      fix: input.lastError?.fix === 'retry' ? { label: 'Retry last recording', run: () => void api.retryLast() } : undefined,
    };
  } else if (kind === 'deliveryFailed') {
    engine = { label: 'Engine', tone: 'bad', text: "Couldn't deliver" };
  } else if (kind === 'offline') {
    engine = { label: 'Engine', tone: 'warn', text: 'Offline', fix: { label: 'Retry last recording', run: () => void api.retryLast() } };
  } else {
    engine = { label: 'Engine', tone: 'ok', text: 'Deepgram Nova-3' };
  }
  const microphone: HealthRow = micOff(input)
    ? { label: 'Microphone', tone: 'warn', text: 'Off', fix: { label: 'Open settings', run: () => void api.openExternal(MIC_SETTINGS_URL) } }
    : { label: 'Microphone', tone: 'ok', text: 'Allowed' };

  const tones = [engine.tone, microphone.tone];
  if (!input.saveStatus.ok) tones.push('warn');
  if (input.pasteBlocked) tones.push('warn');
  const overall: Overall = tones.includes('bad') ? 'problem' : tones.includes('warn') ? 'needs' : 'ready';
  return { overall, engine, microphone };
}

export interface StatusButton {
  /** The rail button, with its popover as a sibling inside `element`. */
  element: HTMLElement;
  update: (health: Health) => void;
}

export function createStatusButton(): StatusButton {
  let health: Health | null = null;
  let open = false;

  const button = el('button', {
    class: 'rail-item rail-status',
    type: 'button',
    'aria-haspopup': 'dialog',
    'aria-expanded': 'false',
    'aria-controls': 'status-popover',
  } as never);
  const popover = el('div', {
    class: 'status-popover',
    id: 'status-popover',
    role: 'dialog',
    'aria-label': 'Status',
    hidden: true,
  } as never);
  const element = el('div', { class: 'rail-status-wrap' }, button, popover);

  function paint(): void {
    if (!health) return;
    const tone = TONE[health.overall];
    button.replaceChildren(
      el('span', { class: `rail-glyph ${tone}` }, icon(GLYPH[health.overall], 22)),
      el('span', { class: 'rail-label' }, WORD[health.overall]),
    );
    button.dataset.tone = tone;
    popover.replaceChildren(
      el('h2', { class: 'status-popover-title' }, 'Status'),
      row(health.engine),
      row(health.microphone),
    );
  }

  function row(entry: HealthRow): HTMLElement {
    const glyph = entry.tone === 'ok' ? GLYPH.ready : entry.tone === 'warn' ? GLYPH.needs : GLYPH.problem;
    return el(
      'div',
      { class: 'status-row' },
      el('span', { class: 'status-row-label' }, entry.label),
      el('span', { class: `status-pill ${entry.tone}` }, icon(glyph, 14), entry.text),
      entry.fix
        ? el(
            'button',
            {
              class: 'btn btn-sm',
              type: 'button',
              onclick: () => {
                setOpen(false);
                entry.fix?.run();
              },
            } as never,
            entry.fix.label,
          )
        : null,
    );
  }

  function setOpen(next: boolean, restoreFocus = false): void {
    if (next === open) return;
    open = next;
    button.setAttribute('aria-expanded', String(open));
    if (open) {
      popover.hidden = false;
      popover.classList.remove('leaving');
      document.addEventListener('pointerdown', onOutside, true);
      document.addEventListener('keydown', onKey, true);
    } else {
      document.removeEventListener('pointerdown', onOutside, true);
      document.removeEventListener('keydown', onKey, true);
      // Exit beat (120 ms), then hide. A new open cancels it by clearing `leaving`.
      popover.classList.add('leaving');
      window.setTimeout(() => {
        if (!open) popover.hidden = true;
      }, 120);
      if (restoreFocus) button.focus();
    }
  }

  function onOutside(event: Event): void {
    if (!element.contains(event.target as Node)) setOpen(false);
  }

  function onKey(event: KeyboardEvent): void {
    if (event.key === 'Escape') {
      event.stopPropagation();
      setOpen(false, true);
    }
  }

  button.addEventListener('click', () => setOpen(!open));

  return {
    element,
    update(next) {
      health = next;
      paint();
    },
  };
}
