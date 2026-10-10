import { api } from './api.js';
import { el, icon, ICONS } from './components/dom.js';
import { createLandingMark } from './components/landingMark.js';
import type {
  DictationStateEvent,
  HistoryEntryDTO,
  MemorySnapshotDTO,
  NoteDTO,
  SettingsDTO,
} from '../preload/types.js';

/**
 * The main window's shell: the rail, the stage, navigation, the shared state and the
 * subscriptions that keep it fresh.
 *
 * Pages live in `pages/` and are handed to `mountMain` by the entry point, so this
 * module never imports a page and the pages can import it freely.
 */

export type Page = 'home' | 'dictionary' | 'history' | 'notes' | 'settings';

export const PAGES: Array<{ id: Page; label: string; icon: keyof typeof ICONS }> = [
  { id: 'home', label: 'Dictate', icon: 'home' },
  { id: 'dictionary', label: 'Dictionary', icon: 'dictionary' },
  { id: 'history', label: 'History', icon: 'history' },
  { id: 'notes', label: 'Notes', icon: 'notes' },
  { id: 'settings', label: 'Settings', icon: 'settings' },
];

/** What a page contributes to the shell. */
export interface PageModule {
  render: () => Node;
  headerActions: () => Node[];
}

export interface State {
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

export const state: State = {
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

let noticeTimer = 0;

/**
 * Assigned by `mountMain` once it has built the shell.
 *
 * Helpers like `setNotice` live outside `mountMain` (they are large and would make
 * it unwieldy), but still need to trigger a repaint. A no-op until the shell
 * exists, so nothing can call render before there is anything to render into.
 */
let renderImpl: () => void = () => {};

export function render(): void {
  renderImpl();
}

/**
 * The language picker currently on screen, if Settings is open.
 *
 * A single mutable reference rather than a captured one: `renderSettings` runs on
 * every render and builds a fresh picker, so a listener holding the first instance
 * would be opening a detached element - silently doing nothing, which is the worst
 * way for a hotkey to fail.
 */
export const activeLanguagePicker: { current: { open: () => void } | null } = { current: null };

/**
 * Set when the user navigates, consumed by the next render so only real page
 * switches animate. Without the flag the page entrance animation would replay on
 * every unrelated repaint (a toast, a dictation state tick), which reads as a
 * flicker rather than a transition.
 */
export const nextPageAnimates = { value: false };

export function setNotice(kind: 'success' | 'warning' | 'danger', message: string): void {
  state.notice = { kind, message };
  if (noticeTimer) window.clearTimeout(noticeTimer);
  noticeTimer = window.setTimeout(() => {
    state.notice = null;
    render();
  }, kind === 'danger' ? 12000 : 6000);
  render();
}

export async function refresh(): Promise<void> {
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

export function navigate(page: Page): void {
  if (state.page === page) return;
  state.page = page;
  nextPageAnimates.value = true;
  render();
}

/**
 * Refetch for the pages that show a kind of data, while one of them is on screen.
 *
 * Two deliberate limits:
 *
 *  - **Only a visible page.** An external change to a page the user is not looking at
 *    is picked up when they navigate to it, so a background broadcast never causes
 *    work nobody sees. Home counts as a visible page for memory and history because it
 *    renders the same counters and the four most recent dictations as those pages do -
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
 * instead - the freshly fetched data is already in `state` and appears the moment the
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

export function mountMain(pages: Record<Page, PageModule>, undoDeleteNote: () => Promise<void>): void {
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
  root.append(
    el('div', { class: 'titlebar' }),
    el('div', { class: 'shell' }, rail, el('div', { class: 'stage-wrap' }, stage)),
  );

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

    renderOperator();

    title.textContent = page?.label ?? 'Useful Voice';
    subtitle.textContent = pageSubtitle(state.page);

    headerActions.replaceChildren(...pages[state.page].headerActions());

    const animatePage = nextPageAnimates.value;
    nextPageAnimates.value = false;
    const pageNode = pages[state.page].render();
    body.replaceChildren(pageNode);
    if (animatePage) {
      (pageNode as HTMLElement).classList.add('page-enter');
    }

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

  /** The rail's operator row. Updated on its own for dictation state changes. */
  function renderOperator(): void {
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
  }

  renderImpl = renderAll;

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

  // ---- Boot and subscriptions ------------------------------------------

  // The language hotkey is global, so it can fire from any page. The picker lives in
  // Settings, so navigate there first when it is not already showing.
  api.onOpenLanguagePicker(() => {
    if (state.page !== 'settings') {
      state.page = 'settings';
      nextPageAnimates.value = true;
      render();
    }
    // After render(), so this opens the instance that is actually in the document.
    activeLanguagePicker.current?.open();
  });

  api.onNavigate((page) => {
    if (PAGES.some((entry) => entry.id === page) && state.page !== page) {
      state.page = page as Page;
      nextPageAnimates.value = true;
      render();
    }
  });

  api.onState((event) => {
    state.dictation = event;
    // Dictation state shows in the rail everywhere, and in the page body only on
    // Home. Rebuilding every page for a state tick would drop focus from any
    // in-progress input and re-create every row for no visible change.
    if (state.page === 'home') render();
    else renderOperator();
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

/** The brand mark: the Landing mark, matching the macOS app. */
function brandMark(): SVGSVGElement {
  const svg = createLandingMark({ size: 24, state: 'still' });
  svg.classList.add('rail-mark');
  return svg;
}
