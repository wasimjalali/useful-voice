import { api } from './api.js';
import { mountAnnouncer } from './components/announcer.js';
import { el, icon, ICONS } from './components/dom.js';
import { createLandingMark, setLandingMarkLevels } from './components/landingMark.js';
import { createLanguagePanel, LANGUAGE_PATHS } from './components/languagePicker.js';
import {
  errorTitle,
  fixLabel,
  formatClock,
  formatWords,
  hudLabel,
  type HudFrame,
} from '../core/hudModel.js';
import type { HudAction } from '../preload/types.js';

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

/** How long the outgoing content takes to fade, and the width to ease (the board's 200 ms morph). */
const MORPH_MS = 200;
/** The exit sink, 160 ms, plus a frame. */
const EXIT_MS = 170;

export function mountHud(): void {
  if (new URLSearchParams(window.location.search).get('panel') === 'language') {
    mountLanguageWindow();
    return;
  }
  mountHudCapsule();
}

// ---------------------------------------------------------------------------
// HUD capsule
// ---------------------------------------------------------------------------

function mountHudCapsule(): void {
  document.body.classList.add('hud');
  const root = document.getElementById('root');
  if (!root) return;

  const capsule = el('div', { class: 'hud-capsule is-hidden', role: 'group' });
  root.append(el('div', { class: 'hud-stage' }, capsule));
  mountAnnouncer();

  /** The frame the capsule currently draws: the only state, always replaced whole. */
  let frame: HudFrame | null = null;
  let leaveTimer = 0;
  let dragging = false;
  /** The mark and the timer of the recording view, patched in place while it lives. */
  let live: { mark: SVGSVGElement; time: HTMLElement; stops: HTMLElement | null } | null = null;
  /** The last three input levels: the three bars show a short trail, so a loud word travels. */
  const trail: [number, number, number] = [0, 0, 0];

  api.onHudView((next) => render(next));
  api.onLevel((level) => {
    trail[0] = trail[1];
    trail[1] = trail[2];
    trail[2] = Math.max(0, Math.min(1, level));
    if (live) paintLevels(live.mark);
  });

  function paintLevels(mark: SVGSVGElement): void {
    // 0.3 is a bar held low in a quiet room, 1.35 the loudest it goes.
    const scale = (level: number): number => 0.3 + 1.05 * level;
    setLandingMarkLevels(mark, [scale(trail[0]), scale(trail[1]), scale(trail[2])]);
  }

  /** The one render path: whatever the main process sent last is what is drawn. */
  function render(next: HudFrame | null): void {
    window.clearTimeout(leaveTimer);
    if (next === null) {
      leave();
      return;
    }
    if (frame && frame.seq === next.seq) {
      patch(next);
      return;
    }
    build(next);
  }

  function build(next: HudFrame): void {
    const entering = frame === null || capsule.classList.contains('is-leaving') || capsule.classList.contains('is-hidden');
    const previous = capsule.querySelector<HTMLElement>('.hud-inner:not(.is-leaving)');
    const from = capsule.offsetWidth;

    frame = next;
    live = null;
    const content = buildContent(next);
    content.classList.add('hud-inner');
    capsule.setAttribute('aria-label', hudLabel(next));
    capsule.dataset.kind = next.kind;
    if (next.kind === 'error') capsule.title = next.error.message;
    else capsule.removeAttribute('title');

    if (entering) {
      capsule.replaceChildren(content);
      capsule.style.width = '';
      capsule.classList.remove('is-hidden', 'is-leaving', 'is-entering');
      // Restart the enter animation even when the last exit was cut short.
      void capsule.offsetWidth;
      capsule.classList.add('is-entering');
      return;
    }

    capsule.classList.remove('is-entering');
    // Cross-fade: the old content fades out where it was while the new fades in, and the
    // capsule's width eases between the two natural widths.
    if (previous) {
      previous.classList.add('is-leaving');
      previous.setAttribute('aria-hidden', 'true');
      window.setTimeout(() => previous.remove(), MORPH_MS);
    }
    content.classList.add('is-fading-in');
    capsule.append(content);
    easeWidth(from);
  }

  /** Ease the capsule from `from` to the natural width of what is in it now. */
  function easeWidth(from: number): void {
    capsule.style.width = '';
    // Measured with only the incoming content counted: the outgoing one is out of flow.
    const to = capsule.offsetWidth;
    if (from === to) return;
    capsule.style.width = `${from}px`;
    void capsule.offsetWidth;
    capsule.style.width = `${to}px`;
  }

  /** The recording view updates in place: the ticking timer must not rebuild the capsule. */
  function patch(next: HudFrame): void {
    frame = next;
    capsule.setAttribute('aria-label', hudLabel(next));
    if (next.kind !== 'recording' || !live) return;
    live.time.textContent = formatClock(next.elapsedSeconds);
    const from = capsule.offsetWidth;
    const content = capsule.querySelector<HTMLElement>('.hud-inner:not(.is-leaving)');
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
    if (content) easeWidth(from);
  }

  function leave(): void {
    if (frame === null) return;
    frame = null;
    live = null;
    capsule.classList.remove('is-entering');
    capsule.classList.add('is-leaving');
    leaveTimer = window.setTimeout(() => {
      capsule.classList.remove('is-leaving');
      capsule.classList.add('is-hidden');
      capsule.replaceChildren();
      capsule.style.width = '';
    }, EXIT_MS);
  }

  /**
   * A button the pointer can click. The capsule as a whole takes the pointer (click-through
   * is off while it is over it) so it can be dragged; a press on a button is not a drag.
   */
  function button(className: string, label: string, action: HudAction, ...children: Array<Node | string>): HTMLButtonElement {
    const node = el('button', { class: className, type: 'button', 'aria-label': label }, ...children);
    node.addEventListener('click', () => void api.hudAction(action));
    return node;
  }

  // The window ignores the mouse except over the capsule; pressing on the capsule (not a
  // button) and moving drags the window. Main remembers where it was left, per display.
  let pendingMove: { x: number; y: number } | null = null;
  capsule.addEventListener('pointerenter', () => api.hudPointer(true));
  capsule.addEventListener('pointerleave', () => {
    if (!dragging) api.hudPointer(false);
  });
  capsule.addEventListener('pointerdown', (event) => {
    if (event.button !== 0 || (event.target as Element).closest('button')) return;
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
    // Released away from the capsule (it follows the pointer, so rarely): click-through again.
    if (!capsule.matches(':hover')) api.hudPointer(false);
  };
  capsule.addEventListener('pointerup', endDrag);
  capsule.addEventListener('pointercancel', endDrag);

  function closeButton(): HTMLButtonElement {
    return button('hud-x', 'Dismiss', 'dismiss', icon(ICON_PATHS.close, 14));
  }

  function buildContent(view: HudFrame): HTMLElement {
    switch (view.kind) {
      case 'recording': {
        const mark = createLandingMark({ size: 20, state: 'live' });
        paintLevels(mark);
        const time = el('span', { class: 'hud-time', 'aria-hidden': 'true' }, formatClock(view.elapsedSeconds));
        const stops = view.stopsIn !== undefined ? el('span', { class: 'hud-stops' }, `Stops in ${view.stopsIn} s`) : null;
        live = { mark, time, stops };
        return el('div', {}, el('span', { class: 'hud-dot' }), mark, time, stops, el('kbd', { class: 'hud-kbd' }, 'Esc'));
      }
      case 'transcribing':
        return el('div', {}, el('span', { class: 'hud-spin' }), 'Transcribing');
      case 'inserting':
        return el('div', {}, el('span', { class: 'hud-spin' }), 'Inserting');
      case 'saving':
        return el('div', {}, el('span', { class: 'hud-spin' }), 'Saving');
      case 'done':
        return el(
          'div',
          {},
          icon(ICON_PATHS.check, 16),
          view.saved ? 'Saved and copied' : 'Inserted',
          el('span', { class: 'hud-dim' }, `· ${formatWords(view.words)}`),
        );
      case 'copied':
        return el('div', { class: 'has-x' }, icon(ICON_PATHS.clipboard, 16), 'Copied. Press Ctrl+V to paste', closeButton());
      case 'cancelled':
        return el('div', {}, icon(ICON_PATHS.close, 16), 'Cancelled');
      case 'error': {
        const glyph =
          view.error.kind === 'micUnavailable' ? ICON_PATHS.micOff : view.error.kind === 'offline' ? ICON_PATHS.wifiOff : ICON_PATHS.alert;
        const label = fixLabel(view.error);
        const fix = view.error.fix;
        return el(
          'div',
          { class: 'has-x' },
          icon(glyph, 16),
          errorTitle(view.error),
          label && fix ? button('hud-btn', label, fix === 'retry' ? 'retry' : fix, label) : null,
          closeButton(),
        );
      }
      case 'language':
        return el('div', {}, icon(ICON_PATHS.globe, 16), el('span', { dir: 'auto' }, view.name));
    }
  }
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
