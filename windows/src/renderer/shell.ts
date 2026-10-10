import { api } from './api.js';
import { el, icon, ICONS } from './components/dom.js';
import { createBanner } from './components/banners.js';
import { computeHealth, createStatusButton, type HealthInput } from './components/statusPopover.js';
import { mountAnnouncer } from './components/announcer.js';
import { createLandingMark } from './components/landingMark.js';
import type {
  DictationError,
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

export type Page = 'stream' | 'notes' | 'vocabulary' | 'insights' | 'settings';

const PAGE_ICONS = {
  stream:
    'M2 13a2 2 0 0 0 2-2V7a2 2 0 0 1 4 0v13a2 2 0 0 0 4 0V4a2 2 0 0 1 4 0v13a2 2 0 0 0 4 0v-4a2 2 0 0 1 2-2',
  notes: ICONS.notes,
  vocabulary: 'M3 15l3-8 3 8M4.2 12.5h3.6M13 6v9h3a2.2 2.2 0 0 0 0-4.4h-3M3 20h18',
  insights: 'M4 4v16h16M9 20v-7M14 20V9M19 20v-5',
  settings: ICONS.settings,
};

export const PAGES: Array<{ id: Page; label: string; icon: string }> = [
  { id: 'stream', label: 'Stream', icon: PAGE_ICONS.stream },
  { id: 'notes', label: 'Notes', icon: PAGE_ICONS.notes },
  { id: 'vocabulary', label: 'Vocabulary', icon: PAGE_ICONS.vocabulary },
  { id: 'insights', label: 'Insights', icon: PAGE_ICONS.insights },
  { id: 'settings', label: 'Settings', icon: PAGE_ICONS.settings },
];

/** Old page ids (the tray, an older window) map onto the new ones. */
const LEGACY_PAGES: Record<string, Page> = { home: 'stream', history: 'stream', dictionary: 'vocabulary' };

export function normalizePage(id: string): Page | null {
  if (PAGES.some((entry) => entry.id === id)) return id as Page;
  return LEGACY_PAGES[id] ?? null;
}

/** What a page contributes to the shell. */
export interface PageModule {
  render: (anchor?: string) => Node;
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
  /** The last dictation error, until the next dictation starts or succeeds. */
  lastError: DictationError | null;
  /** The last hotkey dictation was copied because the paste was blocked. */
  pasteBlocked: boolean;
  /** The OS microphone permission reads as denied. */
  micDenied: boolean;
}

export const state: State = {
  page: 'stream',
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
  lastError: null,
  pasteBlocked: false,
  micDenied: false,
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

/** The settings group the next render should scroll to, consumed by that render. */
let pendingAnchor: string | undefined;
/** True from a page switch until its exit beat ends; the body is not repainted meanwhile. */
let swapPending = false;
let swapTimer = 0;

const EXIT_MS = 120;

/**
 * The one navigation call. A real page switch plays two beats, never a cross-fade:
 * the old page fades and lifts out (120 ms), then the new one rises in (260 ms,
 * `.page-enter`). Reduced motion swaps at once.
 */
export function navigate(page: Page, anchor?: string): void {
  if (state.page === page && anchor === undefined) return;
  const sameTarget = state.page === page;
  pendingAnchor = anchor;
  if (swapTimer) window.clearTimeout(swapTimer);
  state.page = page;
  nextPageAnimates.value = !sameTarget;
  const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  if (sameTarget || reduce) {
    swapPending = false;
    document.querySelector('.stage-body')?.classList.remove('leaving');
    render();
    return;
  }
  swapPending = true;
  renderImpl();
  document.querySelector('.stage-body')?.classList.add('leaving');
  swapTimer = window.setTimeout(() => {
    swapPending = false;
    render();
  }, EXIT_MS);
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
  if (state.page !== 'vocabulary') return false;
  return [...document.querySelectorAll<HTMLInputElement>('.stage-body .field-input')].some(
    (input) => input.value.trim().length > 0,
  );
}

export function mountMain(pages: Record<Page, PageModule>): void {
  mountAnnouncer();
  document.body.classList.add('main');

  const root = document.getElementById('root');
  if (!root) return;

  const goToEngine = (): void => navigate('settings', 'engine');
  const health = (): HealthInput => ({
    hasApiKey: state.settings?.hasApiKey ?? true,
    lastError: state.lastError,
    micDenied: state.micDenied,
    pasteBlocked: state.pasteBlocked,
    saveStatus: state.saveStatus,
  });

  const brand = el('div', { class: 'rail-brand' }, createLandingMark({ size: 28, state: 'still' }));
  const navItems = new Map<Page, HTMLButtonElement>();
  for (const page of PAGES) {
    navItems.set(
      page.id,
      el(
        'button',
        { class: 'rail-item', type: 'button', onclick: () => navigate(page.id) } as never,
        el('span', { class: 'rail-glyph' }, icon(page.icon, 22)),
        el('span', { class: 'rail-label' }, page.label),
      ),
    );
  }
  const status = createStatusButton();
  const rail = el(
    'aside',
    { class: 'rail' },
    brand,
    el(
      'nav',
      { class: 'rail-nav', 'aria-label': 'Sections' as never },
      ...PAGES.filter((page) => page.id !== 'settings').map((page) => navItems.get(page.id) as HTMLElement),
    ),
    el('div', { class: 'rail-foot' }, navItems.get('settings') as HTMLElement, status.element),
  );

  const title = el('h1', { class: 'stage-title' }, 'Stream');
  const headerActions = el('div', { class: 'inline wrap' });
  const header = el('header', { class: 'stage-header' }, title, headerActions);
  const bannerHost = el('div', { class: 'banner-host' });
  const body = el('div', { class: 'stage-body' });
  const stage = el('main', { class: 'stage' }, header, bannerHost, body);
  root.append(
    el('div', { class: 'titlebar' }),
    el('div', { class: 'shell' }, rail, el('div', { class: 'stage-wrap' }, stage)),
  );

  function renderAll(): void {
    for (const [id, item] of navItems) {
      if (state.page === id) item.setAttribute('aria-current', 'page');
      else item.removeAttribute('aria-current');
    }
    renderChrome();
    // The old page is mid exit: the swap repaints the body.
    if (swapPending) return;

    const page = PAGES.find((entry) => entry.id === state.page);
    title.textContent = page?.label ?? 'Useful Voice';
    headerActions.replaceChildren(...pages[state.page].headerActions());

    const animatePage = nextPageAnimates.value;
    nextPageAnimates.value = false;
    const anchor = pendingAnchor;
    pendingAnchor = undefined;
    const pageNode = pages[state.page].render(anchor);
    body.classList.remove('leaving');
    if (animatePage) body.scrollTop = 0;
    body.replaceChildren(pageNode);
    if (animatePage) {
      (pageNode as HTMLElement).classList.add('page-enter');
    }

    if (state.notice) {
      body.prepend(
        el(
          'div',
          { class: `notice notice-${state.notice.kind}`, style: 'margin-bottom:14px' as never },
          el('span', {}, state.notice.message),
        ),
      );
    }
  }

  /** The status button and the window banner. Cheap, so dictation events can repaint it alone. */
  function renderChrome(): void {
    const input = health();
    status.update(computeHealth(input, goToEngine));
    const banner = createBanner(input, goToEngine);
    bannerHost.replaceChildren(...(banner ? [banner] : []));
  }

  renderImpl = renderAll;

  // ---- Boot and subscriptions ------------------------------------------

  // The language hotkey is global, so it can fire from any page. The picker lives in
  // Settings, so navigate there first when it is not already showing.
  api.onOpenLanguagePicker(() => {
    if (state.page !== 'settings') {
      if (swapTimer) window.clearTimeout(swapTimer);
      swapPending = false;
      state.page = 'settings';
      nextPageAnimates.value = true;
      render();
    }
    // After render(), so this opens the instance that is actually in the document.
    activeLanguagePicker.current?.open();
  });

  api.onNavigate((page, anchor) => {
    const target = normalizePage(page);
    if (target) navigate(target, anchor);
  });

  api.onState((event) => {
    state.dictation = event;
    if (event.state === 'error' && event.error) state.lastError = event.error;
    if (event.state === 'recording') {
      state.lastError = null;
      state.pasteBlocked = false;
    }
    // Dictation state shows in the page body only on the Stream. Rebuilding every page
    // for a state tick would drop focus from any in-progress input and re-create every
    // row for no visible change.
    if (state.page === 'stream') render();
    else renderChrome();
  });

  api.onOutcome((outcome) => {
    if (outcome.kind !== 'delivered') return;
    state.lastError = null;
    state.pasteBlocked = outcome.result === 'copiedNotPasted';
    renderChrome();
  });

  api.onSaveStatus((status) => {
    state.saveStatus = status;
    render();
  });

  // Data changed somewhere the renderer did not initiate: a hotkey dictation, a
  // tray action, or learning an entry. Without these the affected page kept a
  // stale list until it was reopened.
  api.onHistoryChanged(() => {
    void loadIfActive('stream', () => api.getHistory().then((history) => {
      state.history = history;
    }));
  });

  // Tray and floating-picker changes (language, auto-format) land in Settings too.
  api.onSettingsChanged(() => void refresh());

  api.onMemoryChanged(() => {
    void loadIfActive(['stream', 'vocabulary'], () => api.getMemory().then((memory) => {
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
    // Read after the first paint: a missing permission API leaves the button on the
    // last dictation error alone.
    if (navigator.permissions) {
      const permission = await navigator.permissions.query({ name: 'microphone' as PermissionName });
      const apply = (): void => {
        state.micDenied = permission.state === 'denied';
        renderChrome();
      };
      apply();
      permission.addEventListener('change', apply);
    }
  })();
}
