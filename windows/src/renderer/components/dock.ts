/**
 * The dock at the bottom of the Stream. One bar, every state: idle, recording, near the
 * silence limit, transcribing, done, error, and the multi-select bar that takes its
 * place. It listens to the dictation events itself and repaints only itself, so a state
 * change never rebuilds the timeline.
 */

import { api } from '../api.js';
import type { DictationError, DictationOutcomeEvent, DictationTelemetry, SettingsDTO } from '../../preload/types.js';
import { el, icon } from './dom.js';
import { STREAM_ICONS } from './dockIcons.js';
import { createLandingMark, setLandingMarkLevels, type LandingMarkOptions } from './landingMark.js';
import { languagePicker, type LanguagePickerHandle } from './languagePicker.js';
import { formatAccelerator, formatClock, pluralize } from './bubbleFormat.js';

export interface DockOptions {
  getSettings: () => SettingsDTO | null;
  setLanguage: (pin: string) => void;
  setFormatting: (enabled: boolean) => void;
  openSettings: (anchor?: string) => void;
}

export interface SelectionBar {
  count: number;
  onAdd: (anchor: HTMLElement) => void;
  onCancel: () => void;
}

export interface DockHandle {
  element: HTMLElement;
  /** Re-read the settings (hotkey, language, auto-format). */
  refresh: () => void;
  /** Replace the dock with the multi-select bar, or restore it with null. */
  setSelection: (bar: SelectionBar | null) => void;
  /** An element above which a popover for the dock opens. */
  anchor: () => HTMLElement;
}

type Mode = 'idle' | 'recording' | 'transcribing' | 'inserting' | 'done' | 'error';

type Done =
  | { kind: 'delivered'; words: number; result: 'pasted' | 'copiedNotPasted' | 'copied'; appName?: string }
  | { kind: 'cancelled' };

/** How long the done row stays before the dock returns to idle. */
const DONE_MS = 4000;
const CANCELLED_MS = 1500;
const COPIED_NOT_PASTED_MS = 8000;
/** The dock's state change, in ms. Matches --dur-state. */
const DOCK_SWAP_MS = 200;

/** Bar scale range the landing mark takes (see landingMark.ts). */
const BAR_MIN = 0.3;
const BAR_SPAN = 1.05;

export function createDock(options: DockOptions): DockHandle {
  let mode: Mode = 'idle';
  let done: Done | null = null;
  let error: DictationError | null = null;
  let elapsed = 0;
  let silenceRemaining: number | undefined;
  let maxRemaining: number | undefined;
  let transcribingFrom = 0;
  let doneTimer = 0;
  let ticker = 0;
  let selection: SelectionBar | null = null;
  let levels: [number, number, number] = [0, 0, 0];

  let language: LanguagePickerHandle | null = null;
  let languagePin = '';

  const root = el('div', { class: 'dock', role: 'group', 'aria-label': 'Dictation' });
  let inner = el('div', { class: 'dock-inner' });
  root.append(inner);

  // Live nodes of the current paint, updated in place so a tick never rebuilds the dock.
  const live: {
    time?: HTMLElement;
    stops?: HTMLElement;
    mark?: SVGSVGElement;
    since?: HTMLElement;
    mic?: HTMLButtonElement;
  } = {};

  const hotkeyLabel = (): string => {
    const accelerator = options.getSettings()?.hotkey.accelerator ?? '';
    return accelerator === '' ? '' : formatAccelerator(accelerator);
  };

  function clearDoneTimer(): void {
    if (doneTimer !== 0) window.clearTimeout(doneTimer);
    doneTimer = 0;
  }

  function clearTicker(): void {
    if (ticker !== 0) window.clearInterval(ticker);
    ticker = 0;
  }

  function micButton(): HTMLButtonElement {
    const recording = mode === 'recording';
    const busy = mode === 'transcribing' || mode === 'inserting';
    const label = recording ? 'Stop and transcribe' : busy ? 'Transcribing' : 'Start dictating';
    const button = el(
      'button',
      {
        class: `dock-mic${recording ? ' is-recording' : ''}${busy ? ' is-busy' : ''}`,
        type: 'button',
        disabled: busy,
        'aria-label': label,
        title: label,
        onclick: () => void api.toggleDictation(),
      },
      recording ? el('span', { class: 'dock-stop' }) : icon(STREAM_ICONS.mic, 20),
    );
    live.mic = button;
    return button;
  }

  function languageChip(): HTMLElement {
    const pin = options.getSettings()?.languagePin ?? 'auto';
    if (language === null || languagePin !== pin) {
      languagePin = pin;
      language = languagePicker({
        value: pin,
        label: 'Spoken language',
        onChange: (value) => options.setLanguage(value),
      });
      const trigger = language.element.querySelector('.lang-trigger');
      trigger?.prepend(icon(STREAM_ICONS.globe, 16));
      trigger?.querySelector('.lang-trigger-chevron')?.replaceChildren(icon(STREAM_ICONS.chevronDown, 14));
    }
    return language.element;
  }

  function engineChip(): HTMLElement {
    return el(
      'button',
      {
        class: 'dock-chip',
        type: 'button',
        title: 'Open engine settings',
        onclick: () => options.openSettings('engine'),
      },
      icon(STREAM_ICONS.cloud, 16),
      el('span', {}, 'Deepgram Nova-3'),
    );
  }

  function formatToggle(): HTMLElement {
    const on = options.getSettings()?.formattingEnabled === true;
    return el(
      'button',
      {
        class: 'dock-format',
        type: 'button',
        'aria-pressed': String(on),
        title: on ? 'Auto-format is on' : 'Auto-format is off',
        'aria-label': 'Auto-format',
        onclick: () => options.setFormatting(!on),
      },
      icon(STREAM_ICONS.format, 18),
    );
  }

  function cluster(): HTMLElement[] {
    return [languageChip(), engineChip(), formatToggle()];
  }

  function keycap(text: string): HTMLElement {
    return el('kbd', { class: 'kbd' }, text);
  }

  function readyStatus(): HTMLElement {
    const label = hotkeyLabel();
    return el(
      'div',
      { class: 'dock-status', role: 'status' },
      label === ''
        ? el('span', {}, 'Ready. Click the microphone to dictate')
        : el('span', {}, 'Ready. Press ', keycap(label), ' to dictate'),
    );
  }

  function recordingRow(): Array<Node | null> {
    const mark = createLandingMark({ size: 28, state: 'live' } satisfies LandingMarkOptions);
    live.mark = mark;
    setLandingMarkLevels(mark, barScales());
    const time = el('span', { class: 'dock-time tnum' }, formatClock(elapsed));
    live.time = time;
    const stops = el('span', { class: 'dock-stops' });
    live.stops = stops;
    paintStops();
    const switchKey = options.getSettings()?.languageSwitchHotkey?.accelerator ?? '';
    return [
      micButton(),
      el('span', { class: 'dock-dot', 'aria-hidden': 'true' }),
      mark,
      time,
      stops,
      el('span', { class: 'spacer' }),
      languageChip(),
      switchKey === '' ? null : keycap(formatAccelerator(switchKey)),
      el('span', { class: 'dock-cancel' }, keycap('Esc'), el('span', {}, 'to cancel')),
    ];
  }

  function paintStops(): void {
    const stops = live.stops;
    if (!stops) return;
    if (silenceRemaining !== undefined) {
      stops.replaceChildren(
        el('b', {}, `Stops in ${silenceRemaining} s`),
        el('span', { class: 'dock-muted' }, 'No speech for a while'),
      );
    } else if (maxRemaining !== undefined) {
      stops.replaceChildren(
        el('b', {}, `Stops in ${maxRemaining} s`),
        el('span', { class: 'dock-muted' }, 'Maximum length'),
      );
    } else {
      stops.replaceChildren();
    }
  }

  function barScales(): [number, number, number] {
    // While the room is quiet and a stop is near, the bars sit low and say so.
    if (silenceRemaining !== undefined) return [BAR_MIN, BAR_MIN, BAR_MIN];
    const scale = (value: number): number => BAR_MIN + BAR_SPAN * Math.min(1, value);
    return [scale(levels[1]), scale(levels[0]), scale(levels[2])];
  }

  function busyRow(): Node[] {
    const label = mode === 'inserting' ? 'Inserting' : 'Transcribing';
    const since = el('span', { class: 'dock-muted tnum' }, mode === 'transcribing' ? `${Math.max(0, Math.round((Date.now() - transcribingFrom) / 1000))} s` : '');
    live.since = since;
    return [
      micButton(),
      el(
        'div',
        { class: 'dock-status', role: 'status' },
        el('span', { class: 'dock-spinner', 'aria-hidden': 'true' }),
        el('b', {}, label),
        since,
      ),
      el('span', { class: 'spacer' }),
      ...cluster(),
    ];
  }

  function doneRow(info: Done): Node[] {
    if (info.kind === 'cancelled') {
      return [
        micButton(),
        el('div', { class: 'dock-status', role: 'status' }, icon(STREAM_ICONS.close, 16), el('b', {}, 'Cancelled')),
        el('span', { class: 'spacer' }),
        ...cluster(),
      ];
    }
    if (info.result === 'copiedNotPasted') {
      return [
        micButton(),
        el(
          'div',
          { class: 'dock-status', role: 'status' },
          el('span', { class: 'dock-tone-icon' }, icon(STREAM_ICONS.warning, 18)),
          el('span', {}, el('b', {}, 'Copied.'), ' Press Ctrl+V to paste'),
        ),
        el('span', { class: 'spacer' }),
        el('button', { class: 'btn btn-secondary dock-action', type: 'button', onclick: () => void api.copyLastTranscript() }, 'Copy last transcript'),
        dismissButton(),
      ];
    }
    const text = info.result === 'pasted'
      ? (info.appName ? `Inserted into ${info.appName}` : 'Inserted')
      : 'Saved and copied';
    return [
      micButton(),
      el(
        'div',
        { class: 'dock-status', role: 'status' },
        icon(STREAM_ICONS.check, 18),
        el('b', {}, text),
        el('span', { class: 'dock-muted' }, pluralize(info.words, 'word')),
      ),
      el('span', { class: 'spacer' }),
      ...cluster(),
    ];
  }

  function dismissButton(): HTMLElement {
    return el(
      'button',
      {
        class: 'icon-btn dock-dismiss',
        type: 'button',
        title: 'Dismiss',
        'aria-label': 'Dismiss',
        onclick: () => {
          clearDoneTimer();
          done = null;
          mode = 'idle';
          paint();
        },
      },
      icon(STREAM_ICONS.close, 16),
    );
  }

  /** The tone and icon for an error, from its kind. */
  function errorTone(failure: DictationError): { tone: 'warn' | 'bad'; glyph: string } {
    switch (failure.kind) {
      case 'micUnavailable':
        return { tone: 'warn', glyph: STREAM_ICONS.micOff };
      case 'noSpeech':
      case 'tooShort':
      case 'noProvider':
        return { tone: 'warn', glyph: STREAM_ICONS.warning };
      case 'offline':
      case 'timedOut':
        return { tone: 'bad', glyph: STREAM_ICONS.wifiOff };
      default:
        return { tone: 'bad', glyph: STREAM_ICONS.warning };
    }
  }

  function errorRow(failure: DictationError): Array<Node | null> {
    const { glyph } = errorTone(failure);
    // The first sentence is the headline; the rest says what it means.
    const split = failure.message.search(/[.!?](\s|$)/);
    const head = split < 0 ? failure.message : failure.message.slice(0, split + 1);
    const rest = split < 0 ? '' : failure.message.slice(split + 1).trim();
    const fix = failure.fix;
    let action: HTMLElement | null = null;
    if (fix === 'openMicrophoneSettings') {
      action = actionButton('Open settings', () => void api.openExternal('ms-settings:privacy-microphone'));
    } else if (fix === 'openEngineSettings') {
      action = actionButton('Open settings', () => options.openSettings('engine'));
    } else if (fix === 'retry') {
      action = actionButton('Retry last recording', () => void api.retryLast());
    }
    return [
      micButton(),
      el(
        'div',
        { class: 'dock-status dock-error', role: 'status' },
        el('span', { class: 'dock-tone-icon' }, icon(glyph, 18)),
        el('span', {}, el('b', {}, head), rest === '' ? null : ` ${rest}`),
      ),
      el('span', { class: 'spacer' }),
      action,
    ];
  }

  function actionButton(label: string, run: () => void): HTMLElement {
    return el('button', { class: 'btn btn-secondary dock-action', type: 'button', onclick: run }, label);
  }

  function selectionRow(bar: SelectionBar): Node[] {
    const add = el(
      'button',
      { class: 'dock-add', type: 'button', onclick: (event: MouseEvent) => bar.onAdd(event.currentTarget as HTMLElement) },
      `Add ${bar.count} to note`,
    );
    return [
      el('b', { class: 'dock-selected' }, `${bar.count} selected`),
      el('span', { class: 'dock-selection-hint' }, 'Shift-click to extend, Esc to clear'),
      el('span', { class: 'spacer' }),
      el('button', { class: 'dock-cancel-selection', type: 'button', onclick: () => bar.onCancel() }, 'Cancel'),
      add,
    ];
  }

  function toneClass(): string {
    if (selection) return 'is-selection';
    if (mode === 'error' && error) return errorTone(error).tone === 'warn' ? 'is-warn' : 'is-bad';
    if (mode === 'done' && done && done.kind === 'delivered' && done.result === 'copiedNotPasted') return 'is-warn';
    return '';
  }

  let lastShape = '';
  function paint(): void {
    live.time = live.stops = live.mark = live.since = live.mic = undefined;
    const shape = `${selection ? 'sel' : mode}`;
    let nodes: Array<Node | null>;
    if (selection) nodes = selectionRow(selection);
    else if (mode === 'recording') nodes = recordingRow();
    else if (mode === 'transcribing' || mode === 'inserting') nodes = busyRow();
    else if (mode === 'done' && done) nodes = doneRow(done);
    else if (mode === 'error' && error) nodes = errorRow(error);
    else nodes = [micButton(), readyStatus(), el('span', { class: 'spacer' }), ...cluster()];

    root.className = `dock ${toneClass()}`.trim();
    root.setAttribute('aria-label', mode === 'recording' && !selection ? `Recording, ${formatClock(elapsed)}` : 'Dictation');
    const swapping = shape !== lastShape;
    const next = el('div', { class: `dock-inner${swapping ? ' is-swapping' : ''}` }, ...nodes);
    if (swapping) {
      // Cross-fade: the old content fades out on top while the new content fades in.
      const leaving = inner;
      leaving.classList.add('is-leaving');
      leaving.setAttribute('aria-hidden', 'true');
      leaving.inert = true;
      window.setTimeout(() => leaving.remove(), DOCK_SWAP_MS);
      root.append(next);
    } else {
      inner.replaceWith(next);
    }
    inner = next;
    lastShape = shape;
  }

  function settle(next: Mode): void {
    clearDoneTimer();
    clearTicker();
    mode = next;
    if (next === 'transcribing') {
      transcribingFrom = Date.now();
      ticker = window.setInterval(() => {
        if (live.since) live.since.textContent = `${Math.round((Date.now() - transcribingFrom) / 1000)} s`;
      }, 1000);
    }
  }

  function showDone(info: Done): void {
    done = info;
    settle('done');
    const ms = info.kind === 'cancelled' ? CANCELLED_MS : info.result === 'copiedNotPasted' ? COPIED_NOT_PASTED_MS : DONE_MS;
    doneTimer = window.setTimeout(() => {
      doneTimer = 0;
      done = null;
      mode = 'idle';
      paint();
    }, ms);
    paint();
  }

  api.onState((event) => {
    switch (event.state) {
      case 'recording':
        done = null;
        error = null;
        elapsed = event.elapsedSeconds ?? 0;
        silenceRemaining = undefined;
        maxRemaining = undefined;
        levels = [0, 0, 0];
        settle('recording');
        break;
      case 'transcribing':
        settle('transcribing');
        break;
      case 'delivering':
        settle('inserting');
        break;
      case 'error':
        error = event.error ?? { kind: 'providerFailed', message: event.message ?? 'The dictation failed.', fix: 'retry' };
        done = null;
        settle('error');
        break;
      case 'idle':
        // The outcome arrives just before idle and keeps its row until its timer ends.
        if (done) return;
        settle('idle');
        break;
    }
    paint();
  });

  api.onOutcome((outcome: DictationOutcomeEvent) => {
    if (outcome.kind === 'cancelled') showDone({ kind: 'cancelled' });
    else showDone({ kind: 'delivered', words: outcome.words, result: outcome.result, appName: outcome.appName });
  });

  api.onTelemetry((telemetry: DictationTelemetry) => {
    if (mode !== 'recording') return;
    levels = [telemetry.level, levels[0], levels[1]];
    const wholeSecond = Math.floor(telemetry.elapsedSeconds);
    const stopsChanged = telemetry.silenceRemaining !== silenceRemaining || telemetry.maxRemaining !== maxRemaining;
    silenceRemaining = telemetry.silenceRemaining;
    maxRemaining = telemetry.maxRemaining;
    if (wholeSecond !== Math.floor(elapsed)) {
      root.setAttribute('aria-label', `Recording, ${formatClock(wholeSecond)}`);
      if (live.time) live.time.textContent = formatClock(wholeSecond);
    }
    elapsed = telemetry.elapsedSeconds;
    if (stopsChanged) paintStops();
    if (live.mark) setLandingMarkLevels(live.mark, barScales());
  });

  paint();

  return {
    element: root,
    refresh: () => paint(),
    setSelection: (bar) => {
      selection = bar;
      paint();
    },
    anchor: () => root,
  };
}
