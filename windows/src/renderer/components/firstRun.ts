import { api } from '../api.js';
import { el, icon } from './dom.js';
import { createLandingMark } from './landingMark.js';
import { languagePicker } from './languagePicker.js';
import { meterLevel } from '../../core/audio/wav.js';
import { navigate, refresh, render } from '../shell.js';
import type { FirstRunStep } from '../../core/firstRun/gate.js';
import type { FirstRunKeyCheck, FirstRunStateDTO } from '../../preload/types.js';

/**
 * The first-run setup: a full-window flow over the shell. Welcome, engine and Deepgram
 * key, microphone, try it, done. It mirrors the macOS flow (Sources/UsefulVoiceApp/FirstRun),
 * minus the Accessibility step Windows has no equivalent of; the dictation hotkey shows on
 * Try it and Done instead.
 *
 * Failure modes, and where each is handled:
 *  - Key check: a refused key (401/403), a dead network and any other answer are three
 *    messages. Nothing is saved unless the check passes. Editing the field while a check
 *    runs drops that check's answer.
 *  - Forced run (`--force-first-run`): main saves nothing at all; the flow also shows no
 *    saved key, so the claim card appears as designed.
 *  - Microphone denied, then allowed while the step is open: a one-second retry moves on.
 *  - Leaving the microphone step, closing the flow or hiding the window stops the meter.
 *  - Practice dictation fails: the pipeline's own error text shows and Retry re-runs it.
 *  - Window closed mid-flow: nothing is marked completed, so the flow shows again next time.
 */

type Page = 'welcome' | 'engine' | 'deepgramKey' | 'microphone' | 'tryIt' | 'done';

type KeyCheck = 'idle' | 'checking' | 'rejected' | 'network' | 'failed' | 'saveFailed';
type MicStatus = 'starting' | 'authorized' | 'denied' | 'missing';

const SIGNUP_URL = 'https://console.deepgram.com/signup?jump=keys';
const MIC_SETTINGS_URL = 'ms-settings:privacy-microphone';
const METER_BARS = 24;
/** The meter shape from the mockup, for sample renders. */
const SAMPLE_LEVELS = [6, 10, 16, 24, 14, 9, 18, 28, 22, 12, 8, 16, 25, 19, 11, 0, 0, 0, 0, 0, 0, 0, 0, 0].map((n) => n / 28);

const GLYPHS = {
  check: 'M5 12.5l4.5 4.5L19 7.5',
  alert: 'M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18zM12 8v5M12 16.5v.01',
  mic: 'M12 3a3 3 0 0 0-3 3v6a3 3 0 0 0 6 0V6a3 3 0 0 0-3-3zM5 11a7 7 0 0 0 14 0M12 18v3',
  external: 'M7 17 17 7M8 7h9v9',
};

interface Flow {
  page: Page;
  forced: boolean;
  /** Opened from Settings "Run setup again": it can be closed without finishing. */
  fromSettings: boolean;
  /** A `--first-run-step` jump: hardware is off and the page shows sample data. */
  frozen: boolean;
  step: FirstRunStep | null;
  keySaved: boolean;
  changingKey: boolean;
  keyText: string;
  keyCheck: KeyCheck;
  keyMessage: string;
  hotkey: string;
  language: string;
  practiceText: string;
  practiceWorked: boolean;
}

let flow: Flow | null = null;
let overlay: HTMLElement | null = null;
let stage: HTMLElement | null = null;
let live: HTMLElement | null = null;
/** Undoes whatever the current page set up (timers, streams, subscriptions). */
let teardown: (() => void) | null = null;
let checkToken = 0;
let firstPaint = true;

// ---- Entry points ---------------------------------------------------------

/** At boot: opens the flow if main says it is pending. */
export async function startFirstRunIfPending(): Promise<void> {
  const state = await api.firstRunState();
  if (!state.pending) return;
  open(state, false);
}

/** Settings "Run setup again": always starts at Welcome and saves normally. */
export async function runSetupAgain(): Promise<void> {
  if (flow) return;
  const state = await api.firstRunState();
  open({ ...state, step: null }, true);
}

function open(state: FirstRunStateDTO, fromSettings: boolean): void {
  const step = fromSettings ? null : state.step;
  const jump = step ? jumpFor(step) : null;
  flow = {
    page: jump?.page ?? 'welcome',
    forced: state.forced,
    fromSettings,
    frozen: step !== null,
    step,
    keySaved: state.keySaved || jump?.page === 'deepgramKey',
    changingKey: false,
    keyText: '',
    keyCheck: 'idle',
    keyMessage: '',
    hotkey: state.hotkey,
    language: state.language,
    practiceText: '',
    practiceWorked: false,
  };
  if (step === 'errKey') {
    flow.keyText = '3f9a1c7e5b2d8a64f0c1';
    flow.keyCheck = 'rejected';
    flow.keyMessage = KEY_MESSAGES.rejected;
  }
  if (step === 'tryItDone') {
    flow.practiceText = 'Hello from Useful Voice.';
    flow.practiceWorked = true;
  }

  const drag = el('div', { class: 'fr-drag' });
  stage = el('div', { class: 'fr-stage' });
  live = el('div', { class: 'sr-only', role: 'status', 'aria-live': 'polite', 'aria-atomic': 'true' });
  overlay = el('div', { class: 'fr', role: 'dialog', 'aria-modal': 'true', 'aria-label': 'Set up Useful Voice' } as never, drag, stage, live);
  overlay.addEventListener('keydown', onKeydown);
  document.body.append(overlay);
  // The shell underneath stays out of the tab order and the accessibility tree.
  document.getElementById('root')?.setAttribute('inert', '');
  firstPaint = true;
  void api.firstRunSetOpen(true);
  show(flow.page);
}

function jumpFor(step: FirstRunStep): { page: Page } {
  switch (step) {
    case 'engine':
    case 'errKey':
      return { page: 'engine' };
    case 'deepgramKey':
      return { page: 'deepgramKey' };
    case 'microphone':
    case 'errMic':
      return { page: 'microphone' };
    case 'tryIt':
    case 'tryItDone':
      return { page: 'tryIt' };
    case 'done':
      return { page: 'done' };
    default:
      return { page: 'welcome' };
  }
}

// ---- Navigation -------------------------------------------------------------

function go(next: Page): void {
  if (!flow || next === flow.page) return;
  flow.page = next;
  show(next);
}

function show(page: Page): void {
  if (!stage || !flow) return;
  teardown?.();
  teardown = null;
  checkToken += 1;
  const build: Record<Page, () => { node: HTMLElement; focus: () => void; announce: string; cleanup?: () => void }> = {
    welcome: welcomePage,
    engine: enginePage,
    deepgramKey: keyPage,
    microphone: microphonePage,
    tryIt: tryItPage,
    done: donePage,
  };
  const built = build[page]();
  built.node.classList.add('fr-page');
  // The first page appears with the window; later ones enter.
  if (firstPaint) built.node.classList.add('fr-first');
  firstPaint = false;
  built.node.dataset.page = page;
  teardown = built.cleanup ?? null;
  const skip = skipButton(page);
  stage.replaceChildren(built.node, ...(skip ? [skip] : []));
  built.focus();
  announce(built.announce);
}

function announce(text: string): void {
  if (!live) return;
  live.textContent = '';
  window.setTimeout(() => {
    if (live) live.textContent = text;
  }, 50);
}

function skipButton(page: Page): HTMLElement | null {
  if (page === 'done') return null;
  const label = flow?.fromSettings ? 'Close' : 'Skip setup';
  return el('button', { class: 'fr-skip', type: 'button', onclick: () => leave() } as never, label);
}

/**
 * Skip or Close. From Settings it only closes. On a first launch it counts as finished
 * (Settings "Run setup again" reopens it), so the flow does not nag on every start.
 */
function leave(): void {
  if (!flow) return;
  void close(!flow.fromSettings);
}

async function close(completed: boolean): Promise<void> {
  if (!flow) return;
  const wasFromSettings = flow.fromSettings;
  teardown?.();
  teardown = null;
  checkToken += 1;
  overlay?.remove();
  overlay = null;
  stage = null;
  live = null;
  flow = null;
  document.getElementById('root')?.removeAttribute('inert');
  await api.firstRunFinish(completed);
  await api.firstRunSetOpen(false);
  // The flow may have saved a key or changed the language: bring the shell up to date.
  try {
    await refresh();
  } catch (error) {
    console.warn('could not refresh after setup', error);
  }
  if (!wasFromSettings) navigate('stream');
  render();
}

function onKeydown(event: KeyboardEvent): void {
  if (!flow) return;
  if (event.key === 'Escape') {
    // Esc belongs to an open language list first.
    if (overlay?.querySelector('.lang-picker.is-open')) return;
    event.preventDefault();
    if (flow.page === 'done') void close(true);
    else leave();
    return;
  }
  if (event.key !== 'Enter' || event.defaultPrevented) return;
  const target = event.target as HTMLElement | null;
  if (target && target.closest('textarea, button, a, select, input, .lang-picker')) return;
  overlay?.querySelector<HTMLButtonElement>('[data-primary]:not(:disabled)')?.click();
}

// ---- Shared pieces -------------------------------------------------------------

function primary(label: string, onClick: () => void, disabled = false): HTMLButtonElement {
  const button = el('button', { class: 'fr-primary', type: 'button', onclick: onClick } as never, label);
  button.dataset.primary = '';
  button.disabled = disabled;
  return button;
}

function backLink(to: Page): HTMLElement {
  return el('button', { class: 'fr-back', type: 'button', 'aria-label': 'Back', onclick: () => go(to) } as never, '‹ Back');
}

function header(step: number, title: string): { node: HTMLElement; title: HTMLElement } {
  const heading = el('h1', { class: 'fr-title', tabindex: -1 } as never, title);
  return { node: el('div', { class: 'fr-head' }, el('span', { class: 'fr-step' }, `Step ${step} of 3`), heading), title: heading };
}

function alertBox(text: string): HTMLElement {
  return el('div', { class: 'fr-alert', role: 'alert' } as never, icon(GLYPHS.alert, 16), el('span', {}, text));
}

function tile(size: number, radius: number, mark: number): HTMLElement {
  const node = el('div', { class: 'fr-tile' }, createLandingMark({ size: mark, state: 'still' }));
  node.style.width = `${size}px`;
  node.style.height = `${size}px`;
  node.style.borderRadius = `${radius}px`;
  return node;
}

/** "Control+Alt+Space" as keycaps: Ctrl, Alt, Space. */
function caps(accelerator: string): HTMLElement {
  const parts = accelerator.replace(/\bControl\b/g, 'Ctrl').split('+').filter((part) => part.length > 0);
  return el('span', { class: 'fr-caps' }, ...parts.map((part) => el('span', { class: 'fr-cap' }, part)));
}

function hotkeyLabel(): string {
  return (flow?.hotkey ?? '').replace(/\bControl\b/g, 'Ctrl');
}

// ---- Welcome ----------------------------------------------------------------------

function welcomePage(): { node: HTMLElement; focus: () => void; announce: string } {
  const title = el('h1', { class: 'fr-title', tabindex: -1 } as never, 'Welcome to Useful Voice');
  const start = primary('Get started', () => go('engine'));
  const node = el(
    'div',
    {},
    el(
      'div',
      { class: 'fr-center' },
      tile(104, 26, 60),
      el(
        'div',
        { style: 'display:flex;flex-direction:column;gap:10px' as never },
        title,
        el('p', { class: 'fr-lead' }, "Tap a key and speak. Your words land wherever you're typing."),
      ),
      start,
    ),
  );
  return { node, focus: () => start.focus(), announce: 'Welcome to Useful Voice' };
}

// ---- Engine and key -------------------------------------------------------------

const KEY_MESSAGES = {
  rejected: "Deepgram didn't accept this key. Copy it again from console.deepgram.com and paste the whole key.",
  network: "Couldn't reach Deepgram. Check your connection, then try again.",
  saveFailed: "Couldn't save the key. Try again.",
};

function enginePage(): { node: HTMLElement; focus: () => void; announce: string; cleanup?: () => void } {
  const f = flow as Flow;
  const head = header(1, 'Choose how it listens');
  const cardHost = el('div', { class: 'fr-card', role: 'group', 'aria-label': 'Deepgram Nova-3' } as never);
  let focusTarget: HTMLElement | null = null;

  const drawCard = (): void => {
    const connected = f.keySaved && !f.changingKey;
    const children: Node[] = [
      el(
        'div',
        { class: 'fr-card-head' },
        el('span', { class: 'fr-card-name' }, 'Deepgram Nova-3'),
        el('span', { class: 'fr-card-tag' }, 'Selected'),
      ),
      el('p', { class: 'fr-card-sub' }, 'In the cloud. Fastest and most accurate.'),
      el('div', { class: 'fr-card-rule' }),
    ];
    if (connected) {
      const next = el('button', { class: 'fr-card-btn', type: 'button', onclick: () => go('microphone') } as never, 'Continue');
      next.dataset.primary = '';
      const change = el(
        'button',
        {
          class: 'fr-card-btn fr-card-btn-quiet',
          type: 'button',
          onclick: () => {
            f.changingKey = true;
            f.keyText = '';
            f.keyCheck = 'idle';
            drawCard();
          },
        } as never,
        'Change key',
      );
      children.push(
        el('div', { class: 'fr-connected' }, icon(GLYPHS.check, 18), el('span', {}, 'Key saved. Encrypted with your Windows account.')),
        el('div', { class: 'fr-actions' }, change, next),
      );
      focusTarget = next;
    } else {
      children.push(...claimBlock());
    }
    cardHost.replaceChildren(...children);
  };

  const claimBlock = (): Node[] => {
    const claim = el(
      'button',
      { class: 'fr-card-btn fr-card-btn-wide', type: 'button', onclick: () => void api.openExternal(SIGNUP_URL) } as never,
      'Claim your $200',
      icon(GLYPHS.external, 14),
    );
    const input = el('input', {
      class: `fr-keyfield${f.keyCheck === 'rejected' ? ' err' : ''}`,
      type: 'password',
      placeholder: 'Paste your API key',
      'aria-label': 'Deepgram API key',
      autocomplete: 'off',
      spellcheck: false,
      value: f.keyText,
    } as never);
    const connect = el('button', { class: 'fr-card-btn', type: 'button' } as never, 'Connect');
    const message = el('div', {});

    const paint = (): void => {
      const checking = f.keyCheck === 'checking';
      connect.textContent = checking ? 'Checking the key…' : 'Connect';
      connect.disabled = checking || f.keyText.trim().length === 0;
      input.classList.toggle('err', f.keyCheck === 'rejected');
      message.replaceChildren(...(f.keyMessage && f.keyCheck !== 'idle' && f.keyCheck !== 'checking' ? [alertBox(f.keyMessage)] : []));
    };
    const submit = (): void => {
      if (connect.disabled) return;
      void check(input.value, paint);
    };
    input.addEventListener('input', () => {
      f.keyText = input.value;
      // The text changed: a check still running was for the old text, so drop its answer.
      checkToken += 1;
      f.keyCheck = 'idle';
      f.keyMessage = '';
      paint();
    });
    input.addEventListener('keydown', (event) => {
      if (event.key === 'Enter') {
        event.preventDefault();
        submit();
      }
    });
    connect.addEventListener('click', submit);
    paint();
    focusTarget = input;

    const out: Node[] = [
      el(
        'div',
        { class: 'fr-credit' },
        el('span', { class: 'fr-credit-figure' }, '$200'),
        el('span', { class: 'fr-credit-label' }, 'free credit for new accounts'),
      ),
      el('p', { class: 'fr-card-note' }, "No card needed. That's 500+ hours of dictation."),
      claim,
      el(
        'div',
        { class: 'fr-recipe' },
        el('span', {}, el('b', {}, '1'), 'Sign up'),
        el('span', {}, el('b', {}, '2'), 'Create an API key'),
        el('span', {}, el('b', {}, '3'), 'Paste it here'),
      ),
      el('div', { class: 'fr-keyrow' }, input, connect),
      message,
    ];
    if (f.changingKey) {
      out.push(
        el(
          'button',
          {
            class: 'fr-card-link',
            type: 'button',
            onclick: () => {
              checkToken += 1;
              f.changingKey = false;
              f.keyText = '';
              f.keyCheck = 'idle';
              f.keyMessage = '';
              drawCard();
              focusTarget?.focus();
            },
          } as never,
          'Keep current key',
        ),
      );
    }
    return out;
  };

  /** Runs the check on the pasted key, and saves it only when Deepgram accepts it. */
  const check = async (raw: string, paint: () => void): Promise<void> => {
    const key = raw.trim();
    if (key.length === 0) return;
    const token = ++checkToken;
    f.keyCheck = 'checking';
    f.keyMessage = '';
    paint();
    let result: FirstRunKeyCheck;
    try {
      result = await api.firstRunCheckKey(key);
    } catch (error) {
      result = { ok: false, kind: 'failed', message: (error as Error).message };
    }
    if (token !== checkToken || !flow) return;
    if (!result.ok) {
      f.keyCheck = result.kind === 'rejected' ? 'rejected' : result.kind === 'network' ? 'network' : 'failed';
      f.keyMessage =
        result.kind === 'rejected' ? KEY_MESSAGES.rejected
        : result.kind === 'network' ? KEY_MESSAGES.network
        : `Couldn't check the key: ${result.message}`;
      paint();
      announce(f.keyMessage);
      return;
    }
    const saved = await api.firstRunSaveKey(key);
    if (token !== checkToken || !flow) return;
    if (!saved.ok) {
      f.keyCheck = 'saveFailed';
      f.keyMessage = KEY_MESSAGES.saveFailed;
      paint();
      announce(f.keyMessage);
      return;
    }
    f.keySaved = true;
    f.changingKey = false;
    f.keyText = '';
    f.keyCheck = 'idle';
    f.keyMessage = '';
    go('deepgramKey');
  };

  drawCard();
  if (f.step === 'errKey') {
    // The sample page shows the refusal the moment it opens.
    announce(f.keyMessage);
  }

  const local = el(
    'div',
    { class: 'fr-local' },
    ...[
      ['Whisper Turbo', 'Works offline'],
      ['Whisper Large', 'Most accurate offline'],
    ].map(([name, detail]) => {
      const row = el(
        'button',
        { class: 'fr-local-row', type: 'button', disabled: true, 'aria-label': `${name}. ${detail}. Coming to Windows.` } as never,
        el('span', { class: 'fr-local-name' }, name as string),
        el('span', { class: 'fr-local-detail' }, detail as string),
        el('span', { class: 'status-pill' }, 'Coming to Windows'),
      );
      return row;
    }),
  );

  const node = el(
    'div',
    {},
    el(
      'div',
      { class: 'fr-col' },
      backLink('welcome'),
      head.node,
      cardHost,
      el('p', { class: 'fr-subhead' }, 'Or keep everything on this PC'),
      local,
      el('p', { class: 'fr-fine' }, 'Deepgram receives your audio to transcribe it. Local models will keep it on this PC.'),
    ),
  );
  return {
    node,
    focus: () => (focusTarget ?? head.title).focus(),
    announce: 'Step 1 of 3. Choose how it listens',
  };
}

function keyPage(): { node: HTMLElement; focus: () => void; announce: string } {
  const f = flow as Flow;
  const head = header(1, 'Connect Deepgram');
  const next = primary('Continue', () => go('microphone'));
  const node = el(
    'div',
    {},
    el(
      'div',
      { class: 'fr-col' },
      backLink('engine'),
      head.node,
      el(
        'div',
        {},
        el('div', { class: 'fr-label' }, 'API key'),
        el('div', { class: 'fr-dots', role: 'img', 'aria-label': 'API key, hidden' } as never, '•'.repeat(40)),
      ),
      el(
        'div',
        { class: 'fr-ok' },
        icon(GLYPHS.check, 16),
        el('span', {}, f.forced ? 'Key works.' : "Key works. It's encrypted with your Windows account."),
      ),
      next,
    ),
  );
  return { node, focus: () => next.focus(), announce: 'Step 1 of 3. Connect Deepgram. The key works.' };
}

// ---- Microphone ---------------------------------------------------------------------

function microphonePage(): { node: HTMLElement; focus: () => void; announce: string; cleanup: () => void } {
  const f = flow as Flow;
  const head = header(2, 'Let it hear you');
  const bars = Array.from({ length: METER_BARS }, () => el('span', { class: 'fr-meter-bar' }));
  const meter = el('div', { class: 'fr-meter', role: 'img', 'aria-label': 'Input level' } as never, ...bars);
  const body = el('div', { class: 'fr-col-body', style: 'display:contents' as never });

  let status: MicStatus = f.step === 'errMic' ? 'denied' : f.frozen ? 'authorized' : 'starting';
  let deviceName = 'Microphone';
  let stream: MediaStream | null = null;
  let context: AudioContext | null = null;
  let timer = 0;
  let retry = 0;
  let disposed = false;
  const levels: number[] = new Array(METER_BARS).fill(0);

  const paintMeter = (): void => {
    levels.forEach((level, index) => {
      const bar = bars[index] as HTMLElement;
      const height = Math.max(4, Math.round(level * 28));
      bar.style.height = `${height}px`;
      bar.classList.toggle('lit', height > 4);
    });
  };

  const stopMeter = (): void => {
    window.clearInterval(timer);
    timer = 0;
    for (const track of stream?.getTracks() ?? []) track.stop();
    stream = null;
    void context?.close().catch(() => undefined);
    context = null;
  };

  const startMeter = async (): Promise<void> => {
    if (disposed || stream) return;
    let opened: MediaStream;
    try {
      opened = await navigator.mediaDevices.getUserMedia({ audio: true, video: false });
    } catch (error) {
      if (disposed) return;
      const name = (error as DOMException)?.name ?? '';
      status = name === 'NotFoundError' || name === 'OverconstrainedError' ? 'missing' : 'denied';
      draw();
      scheduleRetry();
      return;
    }
    if (disposed) {
      for (const track of opened.getTracks()) track.stop();
      return;
    }
    stream = opened;
    window.clearTimeout(retry);
    const wasWaiting = status === 'denied' || status === 'missing';
    deviceName = opened.getAudioTracks()[0]?.label || 'Microphone';
    status = 'authorized';
    context = new AudioContext();
    const analyser = context.createAnalyser();
    analyser.fftSize = 1024;
    context.createMediaStreamSource(opened).connect(analyser);
    const samples = new Float32Array(analyser.fftSize);
    timer = window.setInterval(() => {
      analyser.getFloatTimeDomainData(samples);
      levels.shift();
      levels.push(meterLevel(samples));
      paintMeter();
    }, 60);
    // Allowed while the step was open: no need to press anything.
    if (wasWaiting) {
      go('tryIt');
      return;
    }
    draw();
  };

  const scheduleRetry = (): void => {
    window.clearTimeout(retry);
    if (disposed || f.frozen) return;
    retry = window.setTimeout(() => void startMeter(), 1000);
  };

  const draw = (): void => {
    if (status === 'denied' || status === 'missing') {
      const denied = status === 'denied';
      body.replaceChildren(
        ...[
          alertBox(denied ? 'Microphone access is off for Useful Voice.' : 'No microphone found. Plug one in.'),
          el(
            'p',
            { class: 'fr-body' },
            denied
              ? 'Turn it on in Windows Settings under Privacy & security, then Microphone.'
              : 'Choose an input device in Windows Settings under System, then Sound.',
          ),
          denied ? primary('Open Windows Settings', () => void api.openExternal(MIC_SETTINGS_URL)) : null,
          el('div', { class: 'fr-wait', role: 'status' } as never, el('span', { class: 'fr-spin' }), 'Waiting for access. This moves on by itself.'),
        ].filter((item): item is HTMLElement => item !== null),
      );
      return;
    }
    const allowed = status === 'authorized';
    const next = primary('Continue', () => go('tryIt'), !allowed);
    body.replaceChildren(
      el('p', { class: 'fr-body' }, "Useful Voice only listens while you're dictating."),
      el(
        'div',
        { class: 'fr-panel' },
        el(
          'div',
          { class: 'fr-mic' },
          el('span', { class: 'fr-mic-disc' }, icon(GLYPHS.mic, 18)),
          el(
            'div',
            { class: 'fr-mic-text' },
            el('span', { class: 'fr-mic-name' }, deviceName),
            allowed ? el('span', { class: 'fr-mic-hint' }, 'Say something to test it') : null,
          ),
          allowed ? el('span', { class: 'fr-ok' }, icon(GLYPHS.check, 16), 'Allowed') : null,
        ),
        meter,
      ),
      next,
    );
    if (allowed) next.focus();
  };

  if (f.frozen) levels.splice(0, levels.length, ...SAMPLE_LEVELS);
  paintMeter();
  draw();
  if (!f.frozen) void startMeter();

  // A hidden window has no reason to hold the microphone.
  const onVisibility = (): void => {
    if (document.hidden) stopMeter();
    else if (!stream && status === 'authorized') void startMeter();
  };
  document.addEventListener('visibilitychange', onVisibility);

  const node = el('div', {}, el('div', { class: 'fr-col' }, backLink('engine'), head.node, body));
  return {
    node,
    focus: () => (body.querySelector<HTMLElement>('[data-primary]:not(:disabled)') ?? head.title).focus(),
    announce: 'Step 2 of 3. Let it hear you',
    cleanup: () => {
      disposed = true;
      window.clearTimeout(retry);
      document.removeEventListener('visibilitychange', onVisibility);
      stopMeter();
    },
  };
}

// ---- Try it ---------------------------------------------------------------------------

function tryItPage(): { node: HTMLElement; focus: () => void; announce: string; cleanup: () => void } {
  const f = flow as Flow;
  const head = header(3, 'Try it once');

  // Your key
  const keyValue = el('span', {});
  const keyError = el('div', { class: 'fr-inline-err', role: 'alert' } as never);
  let editingKey = false;
  const drawKey = (): void => {
    if (!editingKey) {
      keyValue.replaceChildren(
        caps(f.hotkey),
        el('button', { class: 'fr-link', type: 'button', onclick: () => { editingKey = true; drawKey(); } } as never, 'Change'),
      );
      return;
    }
    const input = el('input', {
      class: 'field-input fr-hotkey-field',
      value: hotkeyLabel(),
      'aria-label': 'Dictation hotkey',
      spellcheck: false,
    } as never);
    const commit = (): void => {
      const value = input.value.split('+').map((part) => part.trim()).filter(Boolean).join('+');
      if (!/(^|\+)(control|ctrl|alt|option)(\+|$)/i.test(value)) {
        keyError.textContent = 'Add Ctrl or Alt, like Ctrl+Alt+Space.';
        input.classList.add('err');
        return;
      }
      keyError.textContent = '';
      f.hotkey = value.replace(/\bctrl\b/gi, 'Control');
      void api.firstRunSetHotkey(f.hotkey);
      editingKey = false;
      drawKey();
      updatePlaceholder();
    };
    input.addEventListener('keydown', (event) => {
      if (event.key === 'Enter') {
        event.preventDefault();
        commit();
      }
    });
    keyValue.replaceChildren(input, el('button', { class: 'fr-secondary', type: 'button', onclick: commit } as never, 'Save'));
    input.focus();
  };

  // Language
  const picker = languagePicker({
    value: f.language,
    label: 'Spoken language',
    onChange: (code) => {
      f.language = code;
      void api.firstRunSetLanguage(code);
    },
  });

  const rows = el(
    'div',
    { class: 'fr-rows' },
    el('div', { class: 'fr-rows-row' }, el('span', { class: 'fr-rows-label' }, 'Your key'), keyValue),
    el('div', { class: 'fr-rows-row' }, el('span', { class: 'fr-rows-label' }, 'Language'), picker.element),
  );

  // The practice field
  const pad = el('textarea', { class: 'fr-pad', 'aria-label': 'Practice area', spellcheck: false } as never);
  pad.value = f.practiceText;
  const updatePlaceholder = (): void => {
    pad.placeholder = `Press ${hotkeyLabel()}, say "Hello from Useful Voice", then press it again.`;
  };
  updatePlaceholder();
  pad.addEventListener('input', () => {
    f.practiceText = pad.value;
  });

  const below = el('div', { style: 'display:contents' as never });
  let dictation: { state: string; message?: string } = { state: 'idle' };
  let canRetry = false;

  const drawBelow = (): void => {
    const worked = f.practiceWorked;
    pad.classList.toggle('worked', worked);
    const recording = dictation.state === 'recording';
    const busy = dictation.state === 'transcribing' || dictation.state === 'delivering';
    const record = el(
      'button',
      { class: 'fr-secondary', type: 'button', disabled: busy || f.frozen, onclick: () => void api.toggleDictation() } as never,
      recording ? 'Stop' : 'Start recording',
    );
    const status = el(
      'span',
      { class: 'fr-status', role: 'status' } as never,
      recording ? 'Listening…' : busy ? 'Transcribing…' : '',
    );
    const items: Array<Node | null> = [el('div', { class: 'fr-pad-row' }, status, record)];
    if (worked) {
      const finish = primary('Finish setup', () => go('done'));
      items.push(
        el('div', { class: 'fr-ok', role: 'status' } as never, icon(GLYPHS.check, 16), 'It worked. That\'s all there is to it.'),
        finish,
      );
    } else {
      if (dictation.state === 'error') {
        items.push(alertBox(dictation.message ?? 'The dictation failed.'));
        if (canRetry) items.push(el('button', { class: 'fr-secondary', type: 'button', onclick: () => void api.retryLast() } as never, 'Retry'));
      }
      items.push(el('button', { class: 'fr-link', type: 'button', onclick: () => go('done') } as never, 'Skip for now'));
    }
    below.replaceChildren(...items.filter((item): item is Node => item !== null));
  };

  const offState = api.onState((event) => {
    dictation = { state: event.state, message: event.message };
    canRetry = event.state === 'error';
    drawBelow();
  });
  const offPractice = api.onPracticeResult(({ text }) => {
    f.practiceText = text;
    pad.value = text;
    f.practiceWorked = true;
    drawBelow();
    announce('It worked. That\'s all there is to it.');
  });

  drawKey();
  drawBelow();
  const node = el('div', {}, el('div', { class: 'fr-col' }, backLink('microphone'), head.node, rows, keyError, pad, below));
  return {
    node,
    focus: () => pad.focus(),
    announce: 'Step 3 of 3. Try it once',
    cleanup: () => {
      offState();
      offPractice();
    },
  };
}

// ---- Done --------------------------------------------------------------------------------

function donePage(): { node: HTMLElement; focus: () => void; announce: string } {
  const f = flow as Flow;
  const title = el('h1', { class: 'fr-title', tabindex: -1 } as never, "You're all set");
  const open = primary('Open Useful Voice', () => void close(true));
  const row = (lead: Node, text: string): HTMLElement =>
    el('div', { class: 'fr-list-row' }, el('div', { class: 'fr-list-lead' }, lead), el('span', {}, text));
  const mark = el('div', { class: 'fr-tile' }, createLandingMark({ size: 16, state: 'still' }));
  mark.style.cssText = 'width:26px;height:26px;border-radius:6px';
  const node = el(
    'div',
    {},
    el(
      'div',
      { class: 'fr-center fr-wide' },
      tile(72, 18, 40),
      title,
      el(
        'div',
        { class: 'fr-list' },
        row(caps(f.hotkey), 'Start and stop dictation in any app'),
        row(caps('Esc'), 'Cancel a recording'),
        row(mark, 'Find Useful Voice in the system tray. It keeps running when you close the window.'),
        row(caps('Vocabulary'), 'Teach it names and words it gets wrong'),
      ),
      open,
    ),
  );
  // Reaching Done counts as finished, like the macOS flow: closing the window here
  // does not bring the flow back. A forced run saves nothing (main refuses).
  if (!f.frozen && !f.fromSettings) void api.firstRunFinish(true);
  return { node, focus: () => open.focus(), announce: "You're all set" };
}
