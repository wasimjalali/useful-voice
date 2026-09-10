import { startCapture, stopCapture, cancelCapture, isCapturing } from './capture.js';
import type {
  DictationStateEvent,
  HistoryEntryDTO,
  MemorySnapshotDTO,
  NoteDTO,
  SettingsDTO,
} from '../preload/types.js';

/**
 * The renderer entry point.
 *
 * Three views share this file, selected by the `view` query parameter the main
 * process passes when it loads the page:
 *
 *   * `recorder` — hidden; exists solely to host microphone capture.
 *   * `hud`      — the small always-on-top recording pill.
 *   * `main`     — the application window.
 *
 * Everything renders with DOM APIs and `textContent`. Transcripts and dictionary
 * terms are user data and routinely contain characters like `<` and `&`; building
 * HTML strings around them would be an injection bug, so no string interpolation
 * into markup happens anywhere in this file.
 */

const api = window.usefulVoice;
const view = new URLSearchParams(window.location.search).get('view') ?? 'main';

// ---------------------------------------------------------------------------
// Small DOM helpers
// ---------------------------------------------------------------------------

type Child = Node | string | null | undefined | false;

type ElProps = Record<string, unknown> & {
  class?: string;
  dataset?: Record<string, string>;
};

function el<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  props: ElProps = {},
  ...children: Child[]
): HTMLElementTagNameMap[K] {
  const node = document.createElement(tag);
  const { class: className, dataset, ...rest } = props as Record<string, unknown>;
  if (typeof className === 'string') node.className = className;
  if (dataset) for (const [key, value] of Object.entries(dataset)) node.dataset[key] = value;
  for (const [key, value] of Object.entries(rest)) {
    if (value === undefined || value === null) continue;
    if (key.startsWith('on') && typeof value === 'function') {
      node.addEventListener(key.slice(2).toLowerCase(), value as EventListener);
    } else if (key in node) {
      (node as unknown as Record<string, unknown>)[key] = value;
    } else {
      node.setAttribute(key, String(value));
    }
  }
  for (const child of children) {
    if (child === null || child === undefined || child === false) continue;
    node.append(typeof child === 'string' ? document.createTextNode(child) : child);
  }
  return node;
}

/** An inline SVG icon, built as real elements so no markup is parsed. */
function icon(path: string, size = 18): SVGSVGElement {
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.setAttribute('viewBox', '0 0 24 24');
  svg.setAttribute('fill', 'none');
  svg.setAttribute('stroke', 'currentColor');
  svg.setAttribute('stroke-width', '1.6');
  svg.setAttribute('stroke-linecap', 'round');
  svg.setAttribute('stroke-linejoin', 'round');
  svg.setAttribute('width', String(size));
  svg.setAttribute('height', String(size));
  const p = document.createElementNS('http://www.w3.org/2000/svg', 'path');
  p.setAttribute('d', path);
  svg.append(p);
  return svg;
}

const ICONS = {
  home: 'M3 10.5 12 3l9 7.5M5 9.5V21h14V9.5',
  dictionary: 'M4 5.5A2.5 2.5 0 0 1 6.5 3H20v18H6.5A2.5 2.5 0 0 1 4 18.5zM8 7h8M8 11h6',
  history: 'M12 8v4l3 2M3.5 12a8.5 8.5 0 1 0 2.6-6.1M3 4v4h4',
  notes: 'M5 4h9l5 5v11H5zM14 4v5h5',
  settings: 'M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM19.4 15a1.7 1.7 0 0 0 .3 1.9l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-2.9 1.2v.2a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-3-1.2l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1A1.7 1.7 0 0 0 2.9 14H2.7a2 2 0 1 1 0-4h.2a1.7 1.7 0 0 0 1.2-3l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 2.9-1.2V2.7a2 2 0 1 1 4 0v.2a1.7 1.7 0 0 0 2.9 1.2l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0 1.2 2.9h.2a2 2 0 1 1 0 4h-.2a1.7 1.7 0 0 0-1.5 1z',
  trash: 'M4 7h16M9 7V5h6v2M6 7l1 13h10l1-13M10 11v6M14 11v6',
  copy: 'M9 9h10v10H9zM5 15V5h10',
  plus: 'M12 5v14M5 12h14',
  close: 'M6 6l12 12M18 6L6 18',
  retry: 'M4 12a8 8 0 1 0 2.4-5.7M4 4v4h4',
};

// ---------------------------------------------------------------------------
// Recorder view (hidden): hosts audio capture only
// ---------------------------------------------------------------------------

function mountRecorder(): void {
  document.body.classList.add('recorder');
  const root = document.getElementById('root');
  if (root) {
    root.append(el('div', { class: 'recorder-note' }, 'Audio capture host. This window is never shown.'));
  }

  api.onStartRecording(() => {
    void (async () => {
      try {
        await startCapture();
      } catch (error) {
        // Report the failure so the main process can show actionable advice
        // instead of waiting for a capture that will never arrive.
        await api.sendAudioError((error as Error).message);
      }
    })();
  });

  api.onStopRecording(() => {
    void (async () => {
      if (!isCapturing()) return;
      try {
        const result = await stopCapture();
        await api.sendAudio(result.wav, {
          durationSeconds: result.durationSeconds,
          peak: result.peak,
          hadSpeech: result.hadSpeech,
        });
      } catch (error) {
        await api.sendAudioError((error as Error).message);
        await cancelCapture();
      }
    })();
  });
}

// ---------------------------------------------------------------------------
// HUD view
// ---------------------------------------------------------------------------

function mountHud(): void {
  document.body.classList.add('hud');
  const root = document.getElementById('root');
  if (!root) return;

  let startedAt = Date.now();
  let state: string = 'idle';

  const dot = el('span', { class: 'hud-dot' });
  const stateLabel = el('span', { class: 'hud-state' }, 'Listening');
  const meterFill = el('span', { class: 'hud-meter-fill' });
  const meter = el('span', { class: 'hud-meter' }, meterFill);
  const time = el('span', { class: 'hud-time' }, '0:00');

  const pill = el('div', { class: 'hud-pill' }, dot, stateLabel, meter, time);
  root.append(pill);

  const timer = window.setInterval(() => {
    if (state !== 'recording') return;
    const seconds = Math.floor((Date.now() - startedAt) / 1000);
    time.textContent = `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, '0')}`;
    // The cap is enforced in the main process; the HUD just stops counting.
  }, 250);

  window.addEventListener('beforeunload', () => window.clearInterval(timer));

  api.onLevel((level) => {
    meterFill.style.width = `${Math.round(Math.max(0, Math.min(1, level)) * 100)}%`;
  });

  api.onState((event) => {
    state = event.state;
    if (event.state === 'recording') {
      startedAt = Date.now();
      pill.classList.remove('hidden');
      stateLabel.textContent = 'Listening';
      dot.className = 'hud-dot busy';
      meter.classList.remove('hidden');
      time.classList.remove('hidden');
    } else if (event.state === 'transcribing') {
      stateLabel.textContent = 'Transcribing';
      dot.className = 'hud-dot working busy';
      meterFill.style.width = '100%';
      time.classList.add('hidden');
    } else if (event.state === 'delivering') {
      stateLabel.textContent = 'Pasting';
      dot.className = 'hud-dot working';
    } else if (event.state === 'error') {
      root.replaceChildren(
        el(
          'div',
          { class: 'hud-error' },
          icon('M12 9v4M12 17h.01M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z', 16),
          el('span', {}, event.message ?? 'Something went wrong.'),
        ),
      );
    }
  });
}

// ---------------------------------------------------------------------------
// Main view
// ---------------------------------------------------------------------------

type Page = 'home' | 'dictionary' | 'history' | 'notes' | 'settings';

const PAGES: Array<{ id: Page; label: string; icon: keyof typeof ICONS }> = [
  { id: 'home', label: 'Dictate', icon: 'home' },
  { id: 'dictionary', label: 'Dictionary', icon: 'dictionary' },
  { id: 'history', label: 'History', icon: 'history' },
  { id: 'notes', label: 'Notes', icon: 'notes' },
  { id: 'settings', label: 'Settings', icon: 'settings' },
];

interface State {
  page: Page;
  settings: SettingsDTO | null;
  memory: MemorySnapshotDTO | null;
  history: HistoryEntryDTO[];
  notes: NoteDTO[];
  dictation: DictationStateEvent;
  saveStatus: { ok: boolean; message?: string };
  dictionarySection: 'words' | 'fixes' | 'snippets';
  historyQuery: string;
  selectedNoteId: string | null;
  noteDraft: { title: string; body: string } | null;
  deletedNote: { note: NoteDTO; index: number } | null;
  notice: { kind: 'success' | 'warning' | 'danger'; message: string } | null;
  confirmNoteDelete: boolean;
}

const state: State = {
  page: 'home',
  settings: null,
  memory: null,
  history: [],
  notes: [],
  dictation: { state: 'idle' },
  saveStatus: { ok: true },
  dictionarySection: 'words',
  historyQuery: '',
  selectedNoteId: null,
  noteDraft: null,
  deletedNote: null,
  notice: null,
  confirmNoteDelete: false,
};

let undoTimer = 0;
let noticeTimer = 0;

/**
 * Assigned by `mountMain` once it has built the shell.
 *
 * Helpers like `setNotice` live outside `mountMain` (they are large and would make
 * it unwieldy), but still need to trigger a repaint. A no-op until the shell
 * exists, so nothing can call render before there is anything to render into.
 */
let render: () => void = () => {};

function setNotice(kind: 'success' | 'warning' | 'danger', message: string): void {
  state.notice = { kind, message };
  if (noticeTimer) window.clearTimeout(noticeTimer);
  noticeTimer = window.setTimeout(() => {
    state.notice = null;
    render();
  }, kind === 'danger' ? 12000 : 6000);
  render();
}

async function refresh(): Promise<void> {
  const [settings, memory, history, notes] = await Promise.all([
    api.getSettings(),
    api.getMemory(),
    api.getHistory(),
    api.getNotes(),
  ]);
  state.settings = settings;
  state.memory = memory;
  state.history = history;
  state.notes = notes;
}

/**
 * Refetch for the pages that show a kind of data, while one of them is on screen.
 *
 * Two deliberate limits:
 *
 *  - **Only a visible page.** An external change to a page the user is not looking at
 *    is picked up when they navigate to it, so a background broadcast never causes
 *    work nobody sees. Home counts as a visible page for memory and history because it
 *    renders the same counters and the four most recent dictations as those pages do —
 *    and it is the screen in front of the user while they dictate.
 *  - **The fetch is patched into state, never into the whole snapshot.** A full
 *    `refresh()` here would replace every collection and re-render forms, which is
 *    how a background event ends up discarding half-typed input. Replacing only the
 *    affected collection leaves in-progress UI state (`historyQuery`,
 *    `dictionarySection`, and the note draft) exactly as the user left it.
 *
 * A note being edited is never disturbed: its `noteDraft` is only ever cleared by
 * the user's own actions or when the underlying note no longer exists.
 */
async function loadIfActive(pages: Page | readonly Page[], load: () => Promise<void>): Promise<void> {
  const visible = typeof pages === 'string' ? [pages] : pages;
  if (!visible.includes(state.page)) return;
  try {
    await load();
    // Refreshing the data is always safe; repainting is not. See below.
    if (hasUnsubmittedInput()) return;
    render();
  } catch (error) {
    // A failed background refetch must not replace the page with an error state;
    // the next user action will surface a real problem through its own path.
    console.warn('background refresh failed', error);
  }
}

/**
 * Whether repainting now would throw away something the user has typed.
 *
 * The dictionary's add-forms are the only fields whose value lives in the DOM alone:
 * their buttons read the inputs when pressed and nothing mirrors them into `state`. A
 * background repaint would silently drop a half-typed word, so the repaint is skipped
 * instead — the freshly fetched data is already in `state` and appears the moment the
 * user does anything that repaints (pressing Add, switching section or page).
 *
 * The other pages do not need this. The history search box and the note editor mirror
 * their text into `state` (`historyQuery`, `noteDraft`), so it comes back with the
 * repaint.
 */
function hasUnsubmittedInput(): boolean {
  if (state.page !== 'dictionary') return false;
  return [...document.querySelectorAll<HTMLInputElement>('.stage-body .field-input')].some(
    (input) => input.value.trim().length > 0,
  );
}

function mountMain(): void {
  document.body.classList.add('main');

  const root = document.getElementById('root');
  if (!root) return;

  const brand = el(
    'div',
    { class: 'rail-brand' },
    brandMark(),
    el('span', { class: 'rail-wordmark' }, 'Useful Voice'),
  );
  const nav = el('nav', { class: 'rail-nav', 'aria-label': 'Sections' as never });
  const operator = el('div', { class: 'rail-operator' });
  const rail = el('aside', { class: 'rail' }, brand, nav, operator);

  const title = el('h1', { class: 'stage-title' }, 'Dictate');
  const subtitle = el('p', { class: 'stage-subtitle' }, '');
  const headerActions = el('div', { class: 'inline wrap' });
  const header = el(
    'header',
    { class: 'stage-header' },
    el('div', {}, title, subtitle),
    headerActions,
  );
  const body = el('div', { class: 'stage-body' });
  const stage = el('main', { class: 'stage' }, header, body);
  root.append(el('div', { class: 'shell' }, rail, el('div', { class: 'stage-wrap' }, stage)));

  function renderAll(): void {
    // Nav
    nav.replaceChildren(
      ...PAGES.map((page) =>
        el(
          'button',
          {
            class: 'nav-item',
            type: 'button',
            'aria-current': state.page === page.id ? 'page' : undefined,
            onclick: () => navigate(page.id),
          } as never,
          icon(ICONS[page.icon], 18),
          el('span', {}, page.label),
        ),
      ),
    );

    const page = PAGES.find((entry) => entry.id === state.page);

    // Operator row: the current dictation state, always visible.
    const stateLabel =
      state.dictation.state === 'recording'
        ? 'Listening…'
        : state.dictation.state === 'transcribing'
          ? 'Transcribing…'
          : state.dictation.state === 'delivering'
            ? 'Pasting…'
            : state.dictation.state === 'error'
              ? 'Last attempt failed'
              : 'Ready';
    operator.replaceChildren(
      el(
        'div',
        { class: 'inline', style: 'gap:8px' as never },
        el('span', {
          class: `list-row-title ${state.dictation.state === 'error' ? 'danger' : ''}`,
          style: 'font-size:12px' as never,
        }, stateLabel),
      ),
      el(
        'p',
        { class: 'tiny faint', style: 'margin:0;line-height:1.5' as never },
        state.settings?.hotkey.accelerator
          ? `Hotkey: ${state.settings.hotkey.accelerator}`
          : 'No hotkey set',
      ),
    );

    title.textContent = page?.label ?? 'Useful Voice';
    subtitle.textContent = pageSubtitle(state.page);

    headerActions.replaceChildren(...headerActionsFor(state.page));

    const pageNode = renderPage();
    body.replaceChildren(pageNode);

    // A persistence or notice banner is shown above whatever page is open, so a
    // save failure is visible no matter where the user is.
    const banners: Node[] = [];
    if (!state.saveStatus.ok && state.saveStatus.message) {
      banners.push(
        el(
          'div',
          { class: 'notice notice-danger', style: 'margin-bottom:14px' as never },
          icon('M12 9v4M12 17h.01M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z', 15),
          el('span', {}, state.saveStatus.message),
        ),
      );
    }
    if (state.notice) {
      banners.push(
        el(
          'div',
          { class: `notice notice-${state.notice.kind}`, style: 'margin-bottom:14px' as never },
          el('span', {}, state.notice.message),
        ),
      );
    }
    for (const banner of banners.reverse()) body.prepend(banner);

    // Undo bar for a deleted note, shown regardless of page.
    if (state.deletedNote) {
      body.prepend(
        el(
          'div',
          { class: 'undo-bar', style: 'margin-bottom:12px' as never },
          el('span', {}, `Deleted “${state.deletedNote.note.title || 'Untitled note'}”`),
          el('span', { class: 'spacer' }),
          el('button', { type: 'button', onclick: () => void undoDeleteNote() }, 'Undo'),
        ),
      );
    }
  }

  render = renderAll;

  function navigate(page: Page): void {
    state.page = page;
    render();
  }

  function pageSubtitle(page: Page): string {
    switch (page) {
      case 'home':
        return 'Press your hotkey anywhere, speak, and the text appears where you are working.';
      case 'dictionary':
        return 'Words and phrases Useful Voice should recognise, and the corrections it applies.';
      case 'history':
        return 'Everything you have dictated, newest first.';
      case 'notes':
        return 'Notes typed or dictated, stored on this computer only.';
      case 'settings':
        return 'Your key, language, hotkey and shortcuts.';
    }
  }

  function headerActionsFor(page: Page): Node[] {
    if (page === 'home') {
      return [
        el(
          'button',
          {
            class: 'btn btn-primary',
            type: 'button',
            onclick: () => void api.toggleDictation(),
            disabled: state.dictation.state === 'transcribing' || state.dictation.state === 'delivering',
          } as never,
          state.dictation.state === 'recording' ? 'Stop and transcribe' : 'Start dictating',
        ),
      ];
    }
    if (page === 'dictionary') {
      return [];
    }
    if (page === 'history') {
      return [
        el(
          'button',
          {
            class: 'btn btn-secondary',
            type: 'button',
            onclick: () => void exportHistoryCsv(),
          } as never,
          icon(ICONS.copy, 14),
          'Export CSV',
        ),
      ];
    }
    if (page === 'notes') {
      return [
        el(
          'button',
          { class: 'btn btn-primary', type: 'button', onclick: () => void createNote() } as never,
          icon(ICONS.plus, 14),
          'New note',
        ),
      ];
    }
    return [];
  }

  function renderPage(): Node {
    switch (state.page) {
      case 'home':
        return renderHome();
      case 'dictionary':
        return renderDictionary();
      case 'history':
        return renderHistory();
      case 'notes':
        return renderNotes();
      case 'settings':
        return renderSettings();
    }
  }

  // ---- Home -------------------------------------------------------------

  function renderHome(): Node {
    const page = el('div', { class: 'page' });
    const memory = state.memory;

    const stats = el(
      'div',
      { class: 'grid-3' },
      statCard('Words in your dictionary', String(memory?.terms.length ?? 0)),
      statCard('Corrections', String(memory?.replacements.length ?? 0)),
      statCard('Dictations', String(state.history.length)),
    );
    page.append(stats);

    const status = el('div', { class: 'card card-pad' });
    status.append(el('p', { class: 'section-label' }, 'Status'));

    if (!state.settings?.hasApiKey) {
      status.append(
        el(
          'div',
          { class: 'notice notice-danger', style: 'margin-top:10px' as never },
          icon('M12 9v4M12 17h.01M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z', 15),
          el('span', {}, 'No Deepgram API key is set. Add one in Settings to start dictating.'),
        ),
      );
      status.append(
        el(
          'div',
          { class: 'inline', style: 'margin-top:12px' as never },
          el('button', {
            class: 'btn btn-primary',
            type: 'button',
            onclick: () => navigate('settings'),
          } as never, 'Open Settings'),
        ),
      );
    } else if (state.dictation.state === 'error') {
      status.append(
        el(
          'div',
          { class: 'notice notice-danger', style: 'margin-top:10px' as never },
          el('span', {}, state.dictation.message ?? 'The last dictation failed.'),
        ),
      );
      status.append(
        el(
          'div',
          { class: 'inline', style: 'margin-top:12px' as never },
          el('button', {
            class: 'btn btn-secondary',
            type: 'button',
            onclick: () => void api.retryLast(),
          } as never, 'Retry last dictation'),
        ),
      );
    } else {
      status.append(
        el(
          'div',
          { class: 'notice notice-success', style: 'margin-top:10px' as never },
          el('span', {}, 'Ready. Press your hotkey and speak.'),
        ),
      );
    }
    page.append(status);

    const recent = state.history.slice(0, 4);
    const recentCard = el('div', { class: 'card card-pad' });
    recentCard.append(el('p', { class: 'section-label' }, 'Recent dictations'));
    if (recent.length === 0) {
      recentCard.append(
        el('p', { class: 'muted', style: 'margin:10px 0 0' as never }, 'Nothing yet. Your dictations will appear here.'),
      );
    } else {
      recentCard.append(
        el(
          'div',
          { class: 'list', style: 'margin-top:10px' as never },
          ...recent.map((record) =>
            el(
              'div',
              { class: 'list-row' },
              el(
                'div',
                { class: 'list-row-main' },
                el('div', { class: 'list-row-title truncate' }, record.text),
                el(
                  'div',
                  { class: 'list-row-sub' },
                  `${record.appName} · ${relativeTime(record.createdAt)}`,
                ),
              ),
              el(
                'div',
                { class: 'list-row-actions' },
                el(
                  'button',
                  {
                    class: 'icon-btn',
                    type: 'button',
                    title: 'Copy to clipboard',
                    onclick: () => void copyText(record.text),
                  } as never,
                  icon(ICONS.copy, 15),
                ),
              ),
            ),
          ),
        ),
      );
    }
    page.append(recentCard);

    return page;
  }

  function statCard(label: string, value: string): Node {
    return el(
      'div',
      { class: 'card card-pad' },
      el('div', { class: 'stat-value' }, value),
      el('div', { class: 'stat-label' }, label),
    );
  }

  // ---- Dictionary -------------------------------------------------------

  function renderDictionary(): Node {
    const page = el('div', { class: 'page page-wide' });
    const memory = state.memory;
    if (!memory) return el('div', { class: 'muted' }, 'Loading…');

    // Warn when the keyterm list had to be trimmed: the user should know their
    // dictionary is not fully active rather than silently getting worse results.
    const report = memory.keytermReport;
    if (report.dropped > 0 || report.rejected > 0) {
      page.append(
        el(
          'div',
          { class: 'notice notice-warning' },
          icon('M12 9v4M12 17h.01M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z', 15),
          el(
            'span',
            {},
            `${report.dropped + report.rejected} of your entries are not being sent to the recogniser `
            + `(the limit is ${report.limit} per request). The highest-priority entries are used first.`,
          ),
        ),
      );
    }

    const segmented = el(
      'div',
      { class: 'segmented' },
      ...([
        ['words', `Words (${memory.terms.length})`],
        ['fixes', `Corrections (${memory.replacements.length})`],
        ['snippets', `Shortcuts (${memory.snippets.length})`],
      ] as const).map(([id, label]) =>
        el(
          'button',
          {
            type: 'button',
            'aria-selected': state.dictionarySection === id ? 'true' : 'false',
            onclick: () => {
              state.dictionarySection = id;
              render();
            },
          } as never,
          label,
        ),
      ),
    );
    page.append(segmented);

    if (state.dictionarySection === 'words') page.append(wordsSection(memory));
    else if (state.dictionarySection === 'fixes') page.append(fixesSection(memory));
    else page.append(snippetsSection(memory));

    if (memory.suggestions.length > 0) page.append(suggestionsSection(memory));

    return page;
  }

  function wordsSection(memory: MemorySnapshotDTO): Node {
    const card = el('div', { class: 'card card-pad' });
    card.append(el('p', { class: 'section-label' }, 'Words'));

    const wordInput = el('input', {
      class: 'field-input',
      placeholder: 'Kubernetes',
      'aria-label': 'Word or phrase',
    } as never);
    const soundsInput = el('input', {
      class: 'field-input',
      placeholder: 'kubernets',
      'aria-label': 'Sounds like',
    } as never);

    const addRow = el(
      'div',
      { class: 'grid-3', style: 'margin-top:12px' as never },
      el('div', { class: 'field' }, el('label', { class: 'field-label' }, 'Word or phrase'), wordInput),
      el(
        'div',
        { class: 'field' },
        el('label', { class: 'field-label' }, 'Also sounds like'),
        soundsInput,
        el('span', { class: 'field-hint' }, 'What the recogniser often writes instead.'),
      ),
      el(
        'div',
        { class: 'field', style: 'justify-content:flex-end' as never },
        el(
          'button',
          {
            class: 'btn btn-primary',
            type: 'button',
            onclick: () => void addWord(wordInput, soundsInput),
          } as never,
          icon(ICONS.plus, 14),
          'Add word',
        ),
      ),
    );
    card.append(addRow);

    if (memory.terms.length === 0) {
      card.append(
        el(
          'p',
          { class: 'muted', style: 'margin:14px 0 0;line-height:1.55' as never },
          'No words yet. Add the names, products and jargon you use — the recogniser will be told about them before each dictation.',
        ),
      );
      return card;
    }

    card.append(
      el(
        'div',
        { class: 'list', style: 'margin-top:14px' as never },
        ...memory.terms.map((term) =>
          el(
            'div',
            { class: 'list-row' },
            el(
              'div',
              { class: 'list-row-main' },
              el('div', { class: 'list-row-title' }, term.phrase),
              term.pronunciations.length > 0 || term.usageCount > 0
                ? el(
                    'div',
                    { class: 'list-row-sub inline wrap' },
                    ...(term.pronunciations.length > 0
                      ? [el('span', {}, `sounds like “${term.pronunciations.join('”, “')}”`)]
                      : []),
                    ...(term.usageCount > 0
                      ? [el('span', { class: 'chip chip-mono tnum' }, `used ${term.usageCount}×`)]
                      : []),
                  )
                : null,
            ),
            el(
              'div',
              { class: 'list-row-actions' },
              el(
                'button',
                {
                  class: 'icon-btn',
                  type: 'button',
                  title: 'Remove',
                  onclick: () => void removeWord(term.id, term.phrase),
                } as never,
                icon(ICONS.trash, 15),
              ),
            ),
          ),
        ),
      ),
    );
    return card;
  }

  function fixesSection(memory: MemorySnapshotDTO): Node {
    const card = el('div', { class: 'card card-pad' });
    card.append(el('p', { class: 'section-label' }, 'Corrections'));
    card.append(
      el(
        'p',
        { class: 'muted', style: 'margin:8px 0 0;line-height:1.55' as never },
        'Replace what the recogniser heard with what you meant. Matched on whole words only.',
      ),
    );

    const heard = el('input', { class: 'field-input', placeholder: 'cloud code', 'aria-label': 'Heard' } as never);
    const write = el('input', { class: 'field-input', placeholder: 'Claude Code', 'aria-label': 'Write' } as never);
    card.append(
      el(
        'div',
        { class: 'grid-3', style: 'margin-top:12px' as never },
        el('div', { class: 'field' }, el('label', { class: 'field-label' }, 'When it hears'), heard),
        el('div', { class: 'field' }, el('label', { class: 'field-label' }, 'Write instead'), write),
        el(
          'div',
          { class: 'field', style: 'justify-content:flex-end' as never },
          el(
            'button',
            {
              class: 'btn btn-primary',
              type: 'button',
              onclick: () => void addFix(heard, write),
            } as never,
            icon(ICONS.plus, 14),
            'Add correction',
          ),
        ),
      ),
    );

    if (memory.replacements.length > 0) {
      card.append(
        el(
          'div',
          { class: 'list', style: 'margin-top:14px' as never },
          ...memory.replacements.map((rule) =>
            el(
              'div',
              { class: 'list-row' },
              el(
                'div',
                { class: 'list-row-main' },
                el(
                  'div',
                  { class: 'list-row-title' },
                  el('span', { class: 'mono' }, rule.match),
                  el('span', { class: 'muted' }, '  →  '),
                  el('span', {}, rule.replacement),
                ),
                rule.usageCount > 0
                  ? el('div', { class: 'list-row-sub' }, `applied ${rule.usageCount}×`)
                  : null,
              ),
              el(
                'div',
                { class: 'list-row-actions' },
                el(
                  'button',
                  {
                    class: 'switch',
                    type: 'button',
                    role: 'switch',
                    'aria-checked': rule.isEnabled ? 'true' : 'false',
                    title: rule.isEnabled ? 'Disable' : 'Enable',
                    onclick: () => void toggleFix(rule.id, !rule.isEnabled),
                  } as never,
                ),
                el(
                  'button',
                  {
                    class: 'icon-btn',
                    type: 'button',
                    title: 'Remove',
                    onclick: () => void removeFix(rule.id),
                  } as never,
                  icon(ICONS.trash, 15),
                ),
              ),
            ),
          ),
        ),
      );
    }
    return card;
  }

  function snippetsSection(memory: MemorySnapshotDTO): Node {
    const card = el('div', { class: 'card card-pad' });
    card.append(el('p', { class: 'section-label' }, 'Shortcuts'));
    card.append(
      el(
        'p',
        { class: 'muted', style: 'margin:8px 0 0;line-height:1.55' as never },
        'Say a short trigger and the full text is written instead.',
      ),
    );

    const trigger = el('input', { class: 'field-input', placeholder: 'my signature', 'aria-label': 'Trigger' } as never);
    const expansion = el('input', {
      class: 'field-input',
      placeholder: 'Best regards,\nWasim',
      'aria-label': 'Expansion',
    } as never);
    card.append(
      el(
        'div',
        { class: 'grid-3', style: 'margin-top:12px' as never },
        el('div', { class: 'field' }, el('label', { class: 'field-label' }, 'When you say'), trigger),
        el('div', { class: 'field' }, el('label', { class: 'field-label' }, 'Write'), expansion),
        el(
          'div',
          { class: 'field', style: 'justify-content:flex-end' as never },
          el(
            'button',
            {
              class: 'btn btn-primary',
              type: 'button',
              onclick: () => void addSnippet(trigger, expansion),
            } as never,
            icon(ICONS.plus, 14),
            'Add shortcut',
          ),
        ),
      ),
    );

    if (memory.snippets.length > 0) {
      card.append(
        el(
          'div',
          { class: 'list', style: 'margin-top:14px' as never },
          ...memory.snippets.map((snippet) =>
            el(
              'div',
              { class: 'list-row' },
              el(
                'div',
                { class: 'list-row-main' },
                el('div', { class: 'list-row-title mono' }, snippet.trigger),
                el('div', { class: 'list-row-sub truncate' }, snippet.expansion),
              ),
              el(
                'div',
                { class: 'list-row-actions' },
                el(
                  'button',
                  {
                    class: 'icon-btn',
                    type: 'button',
                    title: 'Remove',
                    onclick: () => void removeSnippet(snippet.id),
                  } as never,
                  icon(ICONS.trash, 15),
                ),
              ),
            ),
          ),
        ),
      );
    }
    return card;
  }

  function suggestionsSection(memory: MemorySnapshotDTO): Node {
    const card = el('div', { class: 'card card-pad' });
    card.append(el('p', { class: 'section-label' }, 'Suggested corrections'));
    card.append(
      el(
        'p',
        { class: 'muted', style: 'margin:8px 0 0;line-height:1.55' as never },
        'These appeared repeatedly in your edits. Nothing is applied until you accept it.',
      ),
    );
    card.append(
      el(
        'div',
        { class: 'list', style: 'margin-top:12px' as never },
        ...memory.suggestions.map((suggestion) =>
          el(
            'div',
            { class: 'list-row' },
            el(
              'div',
              { class: 'list-row-main' },
              el(
                'div',
                { class: 'list-row-title' },
                el('span', { class: 'mono' }, suggestion.observed),
                el('span', { class: 'muted' }, '  →  '),
                suggestion.corrected,
              ),
              el('div', { class: 'list-row-sub' }, `seen ${suggestion.evidenceCount}×`),
            ),
            el(
              'div',
              { class: 'list-row-actions' },
              el(
                'button',
                {
                  class: 'btn btn-secondary btn-sm',
                  type: 'button',
                  onclick: () => void acceptSuggestion(suggestion.id),
                } as never,
                'Accept',
              ),
              el(
                'button',
                {
                  class: 'btn btn-ghost btn-sm',
                  type: 'button',
                  onclick: () => void dismissSuggestion(suggestion.id),
                } as never,
                'Dismiss',
              ),
            ),
          ),
        ),
      ),
    );
    return card;
  }

  // ---- History ----------------------------------------------------------

  function renderHistory(): Node {
    const page = el('div', { class: 'page page-wide' });
    const query = state.historyQuery.trim().toLowerCase();
    const records = query.length === 0
      ? state.history
      : state.history.filter((record) => record.text.toLowerCase().includes(query));

    const search = el('input', {
      class: 'field-input',
      placeholder: 'Search your dictations',
      value: state.historyQuery,
    } as never);
    search.addEventListener('input', () => {
      state.historyQuery = search.value;
      // Re-render only the list, so typing does not lose input focus.
      list.replaceChildren(...historyRows(records));
      count.textContent = `${records.length} of ${state.history.length}`;
    });

    const count = el('span', { class: 'tiny faint tnum' }, `${records.length} of ${state.history.length}`);
    page.append(el('div', { class: 'inline' }, el('div', { style: 'flex:1' as never }, search), count));

    const list = el('div', { class: 'list' }, ...historyRows(records));
    page.append(list);

    if (state.history.length > 0) {
      page.append(
        el(
          'div',
          { class: 'inline' },
          el(
            'button',
            { class: 'btn btn-danger', type: 'button', onclick: () => void clearHistory() } as never,
            'Clear all history',
          ),
        ),
      );
    }
    return page;
  }

  function historyRows(records: HistoryEntryDTO[]): Node[] {
    if (records.length === 0) {
      return [
        el(
          'div',
          { class: 'empty-state' },
          el('h3', {}, state.history.length === 0 ? 'No dictations yet' : 'No matches'),
          el(
            'p',
            {},
            state.history.length === 0
              ? 'Once you dictate, every transcript is kept here so you can copy it again.'
              : 'Try a different word.',
          ),
        ),
      ];
    }
    return records.map((record) =>
      el(
        'div',
        { class: 'list-row', style: 'align-items:flex-start' as never },
        el(
          'div',
          { class: 'list-row-main' },
          el('div', { style: 'font-size:13px;line-height:1.55' as never }, record.text),
          el(
            'div',
            { class: 'list-row-sub inline wrap' },
            el('span', {}, record.appName),
            el('span', {}, '·'),
            el('span', {}, relativeTime(record.createdAt)),
            el('span', {}, '·'),
            el('span', { class: 'tnum' }, `${record.durationSeconds.toFixed(1)}s`),
            record.memoryHitCount > 0
              ? el('span', { class: 'chip chip-mono' }, `${record.memoryHitCount} word${record.memoryHitCount === 1 ? '' : 's'}`)
              : null,
          ),
        ),
        el(
          'div',
          { class: 'list-row-actions' },
          el(
            'button',
            {
              class: 'icon-btn',
              type: 'button',
              title: 'Copy',
              onclick: () => void copyText(record.text),
            } as never,
            icon(ICONS.copy, 15),
          ),
          el(
            'button',
            {
              class: 'icon-btn',
              type: 'button',
              title: 'Delete',
              onclick: () => void removeHistory(record.id),
            } as never,
            icon(ICONS.trash, 15),
          ),
        ),
      ),
    );
  }

  // ---- Notes ------------------------------------------------------------

  function renderNotes(): Node {
    const page = el('div', { class: 'page page-wide', style: 'gap:14px' as never });

    if (state.notes.length === 0 && !state.noteDraft) {
      page.append(
        el(
          'div',
          { class: 'empty-state' },
          el('h3', {}, 'No notes yet'),
          el('p', {}, 'Create a note and type or dictate into it. Notes stay on this computer.'),
          el(
            'div',
            { class: 'inline', style: 'margin-top:14px' as never },
            el('button', { class: 'btn btn-primary', type: 'button', onclick: () => void createNote() } as never, 'New note'),
          ),
        ),
      );
      return page;
    }

    const layout = el('div', { style: 'display:grid;grid-template-columns:minmax(200px,260px) minmax(0,1fr);gap:14px;align-items:start' as never });

    const list = el(
      'div',
      { class: 'list' },
      ...state.notes.map((note) =>
        el(
          'button',
          {
            class: 'nav-item',
            type: 'button',
            'aria-current': state.selectedNoteId === note.id ? 'page' : undefined,
            onclick: () => void openNote(note),
          } as never,
          el(
            'div',
            { style: 'min-width:0;text-align:left' as never },
            el('div', { class: 'truncate strong' }, note.title || 'Untitled note'),
            el('div', { class: 'tiny faint truncate' }, relativeTime(note.updatedAt)),
          ),
        ),
      ),
    );

    const editor = el('div', { class: 'card card-pad' });
    if (!state.noteDraft) {
      editor.append(
        el('p', { class: 'muted', style: 'margin:0' as never }, 'Select a note, or create a new one.'),
      );
    } else {
      const titleInput = el('input', {
        class: 'field-input',
        value: state.noteDraft.title,
        placeholder: 'Title',
        'aria-label': 'Note title',
      } as never);
      const bodyInput = el('textarea', {
        class: 'field-textarea',
        value: state.noteDraft.body,
        placeholder: 'Write, or dictate with your hotkey…',
        'aria-label': 'Note body',
        style: 'min-height:280px' as never,
      } as never);

      titleInput.addEventListener('input', () => {
        if (state.noteDraft) state.noteDraft.title = titleInput.value;
      });
      bodyInput.addEventListener('input', () => {
        if (state.noteDraft) state.noteDraft.body = bodyInput.value;
      });

      const saveButton = el(
        'button',
        {
          class: 'btn btn-primary',
          type: 'button',
          onclick: () => void saveNoteDraft(),
        } as never,
        'Save note',
      );

      editor.append(
        el(
          'div',
          { class: 'stack' },
          titleInput,
          bodyInput,
          el(
            'div',
            { class: 'inline' },
            saveButton,
            el(
              'button',
              {
                class: 'btn btn-danger',
                type: 'button',
                onclick: () => {
                  state.confirmNoteDelete = true;
                  render();
                },
              } as never,
              icon(ICONS.trash, 14),
              'Delete',
            ),
            el('span', { class: 'spacer' }),
            el(
              'span',
              { class: 'tiny faint' },
              'Changes are saved when you press Save.',
            ),
          ),
        ),
      );
    }

    layout.append(list, editor);
    page.append(layout);

    // A real confirmation for a destructive action, rather than deleting on click.
    if (state.confirmNoteDelete && state.selectedNoteId) {
      page.append(confirmDialog());
    }

    return page;
  }

  function confirmDialog(): Node {
    const overlay = el('div', { class: 'dialog-overlay' });
    const panel = el(
      'div',
      { class: 'dialog-panel', role: 'dialog', 'aria-modal': 'true' as never },
      el('h2', { class: 'dialog-title' }, 'Delete this note?'),
      el('p', { class: 'dialog-body' }, 'It will be removed from this computer. You can undo immediately afterwards.'),
      el(
        'div',
        { class: 'dialog-actions' },
        el(
          'button',
          {
            class: 'btn btn-secondary',
            type: 'button',
            onclick: () => {
              state.confirmNoteDelete = false;
              render();
            },
          } as never,
          'Cancel',
        ),
        el(
          'button',
          {
            class: 'btn btn-primary',
            type: 'button',
            onclick: () => void confirmDeleteNote(),
          } as never,
          'Delete',
        ),
      ),
    );
    overlay.append(panel);
    overlay.addEventListener('click', (event) => {
      if (event.target === overlay) {
        state.confirmNoteDelete = false;
        render();
      }
    });
    return overlay;
  }

  // ---- Settings ---------------------------------------------------------

  function renderSettings(): Node {
    const page = el('div', { class: 'page' });
    const settings = state.settings;
    if (!settings) return el('div', { class: 'muted' }, 'Loading…');

    // --- API key ---
    const keyCard = el('div', { class: 'card card-pad' });
    keyCard.append(el('p', { class: 'section-label' }, 'Deepgram API key'));
    keyCard.append(
      el(
        'p',
        { class: 'muted', style: 'margin:8px 0 0;line-height:1.55' as never },
        'Stored encrypted with your Windows account. It is never shown again after saving, and never sent anywhere except Deepgram.',
      ),
    );

    const keyInput = el('input', {
      class: 'field-input',
      type: 'password',
      placeholder: settings.hasApiKey ? '•••••••••••••••• (a key is saved)' : 'Paste your key',
      'aria-label': 'Deepgram API key',
    } as never);

    const keyStatus = el('span', { class: 'tiny faint' });
    keyCard.append(
      el(
        'div',
        { class: 'stack', style: 'margin-top:12px' as never },
        keyInput,
        el(
          'div',
          { class: 'inline wrap' },
          el(
            'button',
            {
              class: 'btn btn-primary',
              type: 'button',
              disabled: !settings.hasApiKey,
              onclick: () => void testKey(keyStatus),
            } as never,
            'Test key',
          ),
          el(
            'button',
            {
              class: 'btn btn-secondary',
              type: 'button',
              onclick: () => void saveKey(keyInput, keyStatus),
            } as never,
            'Save key',
          ),
          settings.hasApiKey
            ? el(
                'button',
                {
                  class: 'btn btn-ghost',
                  type: 'button',
                  onclick: () => void clearKey(keyStatus),
                } as never,
                'Remove key',
              )
            : null,
          keyStatus,
        ),
      ),
    );
    page.append(keyCard);

    // --- Dictation ---
    const dictationCard = el('div', { class: 'card card-pad' });
    dictationCard.append(el('p', { class: 'section-label' }, 'Dictation'));
    const rows = el('div', { class: 'rows', style: 'margin-top:12px' as never });

    rows.append(
      selectRow('Spoken language', settings.languagePin, [
        ['en', 'English'],
        ['de', 'German'],
        ['es', 'Spanish'],
        ['fr', 'French'],
        ['it', 'Italian'],
        ['pt', 'Portuguese'],
        ['nl', 'Dutch'],
        ['ja', 'Japanese'],
        ['zh', 'Chinese'],
        ['multi', 'Detect automatically'],
      ], (value) => void saveSettings({ languagePin: value })),
    );

    rows.append(
      switchRow('Format and punctuate', settings.formattingEnabled, 'Adds punctuation, capitalisation and paragraphs.', (value) => void saveSettings({ formattingEnabled: value })),
    );

    rows.append(
      switchRow('Sound cues', settings.soundEffectsEnabled, 'A short tone when recording starts and stops.', (value) => void saveSettings({ soundEffectsEnabled: value })),
    );

    rows.append(
      switchRow('Start with Windows', settings.launchAtLogin, 'Keeps the hotkey available without opening the app first.', (value) => void saveSettings({ launchAtLogin: value })),
    );

    rows.append(
      selectRow('Stop after silence', String(settings.silenceTimeoutSeconds), [
        ['15', '15 seconds'], ['30', '30 seconds'], ['45', '45 seconds'],
        ['60', '1 minute'], ['90', '1 minute 30'], ['120', '2 minutes'],
      ], (value) => void saveSettings({ silenceTimeoutSeconds: Number(value) })),
    );

    rows.append(
      selectRow('Maximum recording', String(settings.maxRecordingSeconds), [
        ['60', '1 minute'], ['180', '3 minutes'], ['300', '5 minutes'],
        ['600', '10 minutes'], ['900', '15 minutes'],
      ], (value) => void saveSettings({ maxRecordingSeconds: Number(value) })),
    );

    rows.append(
      textRow('Hotkey', settings.hotkey.accelerator, (value) => void saveSettings({
        hotkey: { ...settings.hotkey, accelerator: value },
      })),
    );

    dictationCard.append(rows);
    page.append(dictationCard);

    // --- Diagnostics ---
    const diagCard = el('div', { class: 'card card-pad' });
    diagCard.append(el('p', { class: 'section-label' }, 'Diagnostics'));
    diagCard.append(
      el(
        'p',
        { class: 'muted', style: 'margin:8px 0 0;line-height:1.55' as never },
        'Recent problems are recorded here. No transcript text and no API key is ever written to the log.',
      ),
    );
    const log = el('pre', {
      class: 'sunken mono tiny',
      style: 'margin:12px 0 0;padding:12px;max-height:200px;overflow:auto;white-space:pre-wrap' as never,
    }, 'Loading…');
    diagCard.append(
      log,
      el(
        'div',
        { class: 'inline', style: 'margin-top:12px' as never },
        el(
          'button',
          {
            class: 'btn btn-secondary',
            type: 'button',
            onclick: () => void loadDiagnostics(log),
          } as never,
          'Refresh log',
        ),
      ),
    );
    void loadDiagnostics(log);
    page.append(diagCard);

    // --- Backup ---
    const backupCard = el('div', { class: 'card card-pad' });
    backupCard.append(el('p', { class: 'section-label' }, 'Backup and transfer'));
    backupCard.append(
      el(
        'p',
        { class: 'muted', style: 'margin:8px 0 0;line-height:1.55' as never },
        'Files are written to your Documents folder. Importing never overwrites newer work with older.',
      ),
    );
    backupCard.append(
      el(
        'div',
        { class: 'inline wrap', style: 'margin-top:12px' as never },
        el('button', {
          class: 'btn btn-secondary',
          type: 'button',
          onclick: () => void runBackup('export'),
        } as never, 'Export everything'),
        el('button', {
          class: 'btn btn-secondary',
          type: 'button',
          onclick: () => void runBackup('import'),
        } as never, 'Import everything'),
        el('button', {
          class: 'btn btn-secondary',
          type: 'button',
          onclick: () => void runBackup('terms'),
        } as never, 'Export words (CSV)'),
        el('button', {
          class: 'btn btn-secondary',
          type: 'button',
          onclick: () => void runBackup('fixes'),
        } as never, 'Export corrections (CSV)'),
      ),
    );
    page.append(backupCard);

    return page;
  }

  function switchRow(label: string, checked: boolean, hint: string, onChange: (value: boolean) => void): Node {
    const button = el('button', {
      class: 'switch',
      type: 'button',
      role: 'switch',
      'aria-checked': checked ? 'true' : 'false',
      'aria-label': label,
      onclick: () => onChange(!checked),
    } as never);
    return el(
      'div',
      { class: 'row' },
      el(
        'div',
        {},
        el('div', { class: 'row-label' }, label),
        el('div', { class: 'tiny faint', style: 'margin-top:3px;line-height:1.5' as never }, hint),
      ),
      el('div', { class: 'row-value' }, button),
    );
  }

  function selectRow(
    label: string,
    value: string,
    options: Array<[string, string]>,
    onChange: (value: string) => void,
  ): Node {
    const select = el('select', { class: 'field-select', 'aria-label': label } as never);
    for (const [optionValue, optionLabel] of options) {
      const option = el('option', { value: optionValue } as never, optionLabel);
      if (optionValue === value) option.selected = true;
      select.append(option);
    }
    select.addEventListener('change', () => onChange(select.value));
    return el('div', { class: 'row' }, el('div', { class: 'row-label' }, label), el('div', { class: 'row-value' }, select));
  }

  function textRow(label: string, value: string, onChange: (value: string) => void): Node {
    const input = el('input', { class: 'field-input', value, 'aria-label': label } as never);
    input.addEventListener('change', () => onChange(input.value));
    return el('div', { class: 'row' }, el('div', { class: 'row-label' }, label), el('div', { class: 'row-value' }, input));
  }

  // ---- Actions ----------------------------------------------------------

  async function saveSettings(patch: Partial<SettingsDTO>): Promise<void> {
    state.settings = await api.saveSettings(patch);
    render();
  }

  async function saveKey(input: HTMLInputElement, status: HTMLElement): Promise<void> {
    const value = input.value.trim();
    if (value.length === 0) {
      status.textContent = 'Paste a key first.';
      status.className = 'tiny danger';
      return;
    }
    const result = await api.setApiKey(value);
    if (!result.ok) {
      status.textContent = result.error ?? 'The key could not be saved.';
      status.className = 'tiny danger';
      return;
    }
    input.value = '';
    await refresh();
    setNotice('success', 'API key saved.');
  }

  async function clearKey(status: HTMLElement): Promise<void> {
    await api.clearApiKey();
    await refresh();
    status.textContent = 'Key removed.';
    status.className = 'tiny faint';
    render();
  }

  async function testKey(status: HTMLElement): Promise<void> {
    status.textContent = 'Checking…';
    status.className = 'tiny faint';
    const result = await api.testApiKey();
    status.textContent = result.message;
    status.className = result.ok ? 'tiny success' : 'tiny danger';
  }

  async function loadDiagnostics(target: HTMLElement): Promise<void> {
    const info = await api.getDiagnostics();
    const lines = [
      `Useful Voice ${info.version}`,
      `Platform: ${info.platform}`,
      `Log: ${info.logPath}`,
      '',
      ...(info.recentErrors.length > 0 ? info.recentErrors : ['No problems recorded.']),
    ];
    target.textContent = lines.join('\n');
  }

  async function runBackup(kind: 'export' | 'import' | 'terms' | 'fixes'): Promise<void> {
    let result: { ok: boolean; message: string };
    if (kind === 'export') result = await api.exportBackup();
    else if (kind === 'import') result = await api.importBackup();
    else result = await api.exportCsv(kind);
    setNotice(result.ok ? 'success' : 'danger', result.message);
    if (kind === 'import') await refresh();
    render();
  }

  async function exportHistoryCsv(): Promise<void> {
    const result = await api.exportHistoryCsv();
    setNotice(result.ok ? 'success' : 'danger', result.message);
  }

  async function copyText(text: string): Promise<void> {
    await api.copyToClipboard(text);
    setNotice('success', 'Copied to clipboard.');
  }

  async function addWord(wordInput: HTMLInputElement, soundsInput: HTMLInputElement): Promise<void> {
    const phrase = wordInput.value.trim();
    if (phrase.length === 0) {
      setNotice('danger', 'Enter a word or phrase first.');
      return;
    }
    await api.addTerm({
      phrase,
      soundAlike: soundsInput.value.trim() || undefined,
      language: state.settings?.languagePin ?? 'auto',
    });
    await refresh();
    setNotice('success', `Added “${phrase}”.`);
  }

  async function removeWord(id: string, phrase: string): Promise<void> {
    await api.removeTerm(id);
    await refresh();
    setNotice('success', `Removed “${phrase}”.`);
  }

  async function addFix(heard: HTMLInputElement, write: HTMLInputElement): Promise<void> {
    const match = heard.value.trim();
    const replacement = write.value.trim();
    if (match.length === 0 || replacement.length === 0) {
      setNotice('danger', 'Fill in both boxes, so the app knows what to replace and with what.');
      return;
    }
    await api.addReplacement({ match, replacement, language: state.settings?.languagePin ?? 'auto' });
    await refresh();
    setNotice('success', `“${match}” will be written as “${replacement}”.`);
  }

  async function toggleFix(id: string, isEnabled: boolean): Promise<void> {
    await api.setReplacementEnabled(id, isEnabled);
    await refresh();
    render();
  }

  async function removeFix(id: string): Promise<void> {
    await api.removeReplacement(id);
    await refresh();
    setNotice('success', 'Correction removed.');
  }

  async function addSnippet(trigger: HTMLInputElement, expansion: HTMLInputElement): Promise<void> {
    const triggerText = trigger.value.trim();
    const expansionText = expansion.value.trim();
    if (triggerText.length === 0 || expansionText.length === 0) {
      setNotice('danger', 'Fill in both boxes: what you say, and what should be written.');
      return;
    }
    await api.addSnippet({ trigger: triggerText, expansion: expansionText, language: state.settings?.languagePin ?? 'auto' });
    await refresh();
    setNotice('success', `Say “${triggerText}” to write your text.`);
  }

  async function removeSnippet(id: string): Promise<void> {
    await api.removeSnippet(id);
    await refresh();
    setNotice('success', 'Shortcut removed.');
  }

  async function acceptSuggestion(id: string): Promise<void> {
    await api.acceptSuggestion(id);
    await refresh();
    setNotice('success', 'Correction added. It will apply from your next dictation.');
  }

  async function dismissSuggestion(id: string): Promise<void> {
    await api.dismissSuggestion(id);
    await refresh();
    render();
  }

  async function removeHistory(id: string): Promise<void> {
    await api.removeHistory(id);
    await refresh();
    render();
  }

  async function clearHistory(): Promise<void> {
    await api.clearHistory();
    await refresh();
    setNotice('success', 'History cleared.');
  }

  async function createNote(): Promise<void> {
    state.selectedNoteId = null;
    state.noteDraft = { title: '', body: '' };
    state.confirmNoteDelete = false;
    render();
  }

  async function openNote(note: NoteDTO): Promise<void> {
    state.selectedNoteId = note.id;
    state.noteDraft = { title: note.title, body: note.body };
    state.confirmNoteDelete = false;
    render();
  }

  async function saveNoteDraft(): Promise<void> {
    const draft = state.noteDraft;
    if (!draft) return;
    const saved = await api.saveNote({
      id: state.selectedNoteId ?? undefined,
      title: draft.title.trim() || 'Untitled note',
      body: draft.body,
    });
    state.selectedNoteId = saved.id;
    state.noteDraft = { title: saved.title, body: saved.body };
    await refresh();
    setNotice('success', 'Note saved.');
  }

  async function confirmDeleteNote(): Promise<void> {
    const id = state.selectedNoteId;
    state.confirmNoteDelete = false;
    if (!id) {
      // Unsaved draft: nothing on disk to delete.
      state.noteDraft = null;
      render();
      return;
    }
    const removed = await api.deleteNote(id);
    await refresh();
    state.noteDraft = null;
    state.selectedNoteId = null;

    if (removed) {
      state.deletedNote = {
        note: {
          id: removed.id,
          title: removed.title,
          body: removed.body,
          createdAt: '',
          updatedAt: '',
        },
        index: removed.index,
      };
      if (undoTimer) window.clearTimeout(undoTimer);
      undoTimer = window.setTimeout(() => {
        state.deletedNote = null;
        render();
      }, 8000);
    }
    render();
  }

  async function undoDeleteNote(): Promise<void> {
    const deleted = state.deletedNote;
    if (!deleted) return;
    if (undoTimer) window.clearTimeout(undoTimer);
    // Restore puts the note back at its original position, so undoing a mis-click
    // does not also reorder the list.
    await api.restoreNote(
      {
        id: deleted.note.id,
        title: deleted.note.title,
        body: deleted.note.body,
      },
      deleted.index,
    );
    state.deletedNote = null;
    await refresh();
    setNotice('success', 'Note restored.');
  }

  // ---- Boot and subscriptions ------------------------------------------

  api.onNavigate((page) => {
    if (PAGES.some((entry) => entry.id === page)) {
      state.page = page as Page;
      render();
    }
  });

  api.onState((event) => {
    state.dictation = event;
    render();
  });

  api.onSaveStatus((status) => {
    state.saveStatus = status;
    render();
  });

  // Data changed somewhere the renderer did not initiate: a hotkey dictation, a
  // tray action, or learning an entry. Without these the affected page kept a
  // stale list until it was reopened.
  api.onHistoryChanged(() => {
    void loadIfActive(['home', 'history'], () => api.getHistory().then((history) => {
      state.history = history;
    }));
  });

  api.onMemoryChanged(() => {
    void loadIfActive(['home', 'dictionary'], () => api.getMemory().then((memory) => {
      state.memory = memory;
    }));
  });

  api.onNotesChanged(() => {
    void loadIfActive('notes', () => api.getNotes().then((notes) => {
      state.notes = notes;
      // The selection must still exist. A note deleted from the tray would
      // otherwise leave the editor pointing at an id that is gone.
      if (state.selectedNoteId && !notes.some((note) => note.id === state.selectedNoteId)) {
        state.selectedNoteId = notes[0]?.id ?? null;
        state.noteDraft = null;
      }
    }));
  });

  void (async () => {
    await refresh();
    state.saveStatus = await api.getSaveStatus();
    render();
  })();
}

function relativeTime(iso: string): string {
  const then = Date.parse(iso);
  if (!Number.isFinite(then)) return '';
  const seconds = Math.max(0, Math.round((Date.now() - then) / 1000));
  if (seconds < 60) return 'just now';
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return `${minutes} min ago`;
  const hours = Math.round(minutes / 60);
  if (hours < 24) return `${hours} h ago`;
  const days = Math.round(hours / 24);
  if (days < 7) return `${days} d ago`;
  return new Date(then).toLocaleDateString();
}

/** The brand mark: a simple monochrome glyph, matching the macOS app. */
function brandMark(): SVGSVGElement {
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.setAttribute('class', 'rail-mark');
  svg.setAttribute('viewBox', '0 0 24 24');
  svg.setAttribute('fill', 'none');
  svg.setAttribute('stroke', 'currentColor');
  svg.setAttribute('stroke-width', '1.7');
  svg.setAttribute('stroke-linecap', 'round');
  const bar1 = document.createElementNS('http://www.w3.org/2000/svg', 'path');
  bar1.setAttribute('d', 'M6 9v6M12 4v16M18 8v8');
  svg.append(bar1);
  return svg;
}

if (view === 'recorder') mountRecorder();
else if (view === 'hud') mountHud();
else mountMain();
