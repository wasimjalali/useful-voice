import { api } from '../api.js';
import { el, icon } from '../components/dom.js';
import { STREAM_ICONS } from '../components/dockIcons.js';
import { createDock, type DockHandle } from '../components/dock.js';
import { createBubble, type BubbleHandlers, type BubbleView } from '../components/bubble.js';
import { createTimeline, type Timeline } from '../components/timeline.js';
import { openFloating, floatingIsOpen } from '../components/bubblePopover.js';
import { openNotePicker } from '../components/notePicker.js';
import { openTeachFix } from '../components/teachFix.js';
import {
  formatAccelerator,
  formatCount,
  isLanguageCode,
  isSameDay,
  languageLabel,
  pluralize,
  startOfWeek,
} from '../components/bubbleFormat.js';
import { previewFeatures } from '../components/flags.js';
import { state, render, navigate, setNotice } from '../shell.js';
import type { HistoryEntryDTO, NoteDTO } from '../../preload/types.js';

/**
 * The Stream: every stored dictation on one timeline, with search, filters and the dock.
 *
 * The page is one element that lives as long as the window. The shell asks for it on every
 * repaint, so `renderStreamPage` only brings it up to date: the timeline, scroll position,
 * search text, selection and open popovers all survive a repaint instead of being rebuilt.
 */

type Filter = 'all' | 'today' | 'week' | `lang:${string}`;

const ui = {
  query: '',
  filter: 'all' as Filter,
  expanded: new Set<string>(),
  original: new Set<string>(),
  selected: new Set<string>(),
  selectionAnchor: null as string | null,
  teachId: null as string | null,
  /** The history was just emptied here, which reads differently from a first launch. */
  justCleared: false,
};

const MAX_LANGUAGE_CHIPS = 8;
const TOAST_MS = 5000;
const PLAIN_TOAST_MS = 2500;

let root: HTMLElement | null = null;
let timeline: Timeline;
let dock: DockHandle;

// Header parts.
let titleCount: HTMLElement;
let searchInput: HTMLInputElement;
let searchClear: HTMLButtonElement;
let tools: HTMLElement;
let chipRow: HTMLElement;
let exportButton: HTMLButtonElement;
let deleteAllButton: HTMLButtonElement;
// Body parts.
let panel: HTMLElement;
let toasts: HTMLElement;

// Data derived from `state.history`.
let lastHistory: readonly HistoryEntryDTO[] | null = null;
let ascending: HistoryEntryDTO[] = [];
let visible: HistoryEntryDTO[] = [];
let knownIds: Set<string> | null = null;
let freshIds: Set<string> = new Set();
let lastKey = '';
let lastChipKey = '';

// What survives a repaint: where the reader was and what had focus.
const memo = { top: 0, bottom: true };
let pendingRestore: { top: number; bottom: boolean; focus: HTMLElement | null } | null = null;

let toastTimer = 0;
let searchFrame = 0;

export function renderStreamPage(): HTMLElement {
  const page = build();
  if (pendingRestore === null) {
    pendingRestore = {
      top: memo.top,
      bottom: memo.bottom,
      focus: root !== null && document.activeElement instanceof HTMLElement && root.contains(document.activeElement)
        ? document.activeElement
        : null,
    };
    requestAnimationFrame(restoreView);
  }
  sync();
  return page;
}

/** The header actions: the Stream draws its own header, so it adds none to the shell's. */
export function headerActionsForStream(): HTMLElement[] {
  return [];
}

function restoreView(): void {
  const restore = pendingRestore;
  pendingRestore = null;
  if (restore === null || root === null || !root.isConnected) return;
  timeline.measure();
  if (restore.bottom) timeline.scrollToBottom();
  else timeline.element.scrollTop = restore.top;
  timeline.measure();
  if (restore.focus?.isConnected) restore.focus.focus({ preventScroll: true });
}

// ---- Build ------------------------------------------------------------

function build(): HTMLElement {
  if (root !== null) return root;

  timeline = createTimeline({
    renderBubble: (entry, rise) => createBubble(viewFor(entry, rise), handlers),
    openDayJump,
  });
  timeline.element.addEventListener('scroll', () => {
    if (root?.isConnected) {
      memo.top = timeline.element.scrollTop;
      memo.bottom = timeline.isNearBottom();
    }
  }, { passive: true });

  dock = createDock({
    getSettings: () => state.settings,
    setLanguage: (pin) => void saveSetting({ languagePin: pin }),
    setFormatting: (enabled) => void saveSetting({ formattingEnabled: enabled }),
    openSettings: (anchor) => navigate('settings', anchor),
  });

  titleCount = el('span', { class: 'st-count', role: 'status' });
  searchInput = el('input', {
    class: 'st-search-input',
    type: 'text',
    placeholder: 'Search dictations',
    'aria-label': 'Search dictations',
    autocomplete: 'off',
    spellcheck: false,
  });
  searchClear = el(
    'button',
    { class: 'icon-btn st-search-clear', type: 'button', 'aria-label': 'Clear search', title: 'Clear search', onclick: () => setQuery('', true) },
    icon(STREAM_ICONS.close, 14),
  );
  searchClear.hidden = true;
  searchInput.addEventListener('input', () => setQuery(searchInput.value, false));
  searchInput.addEventListener('keydown', (event) => {
    if (event.key !== 'Escape') return;
    if (ui.query !== '') {
      event.preventDefault();
      setQuery('', true);
    } else searchInput.blur();
  });
  const search = el('label', { class: 'st-search' }, icon(STREAM_ICONS.search, 16), searchInput, searchClear);

  chipRow = el('div', { class: 'st-chips', role: 'group', 'aria-label': 'Filter dictations' });
  exportButton = el(
    'button',
    { class: 'icon-btn', type: 'button', title: 'Export as CSV', 'aria-label': 'Export as CSV', onclick: () => void exportCsv() },
    icon(STREAM_ICONS.download, 18),
  );
  deleteAllButton = el(
    'button',
    { class: 'icon-btn', type: 'button', title: 'Delete all dictations', 'aria-label': 'Delete all dictations', onclick: confirmDeleteAll },
    icon(STREAM_ICONS.trash, 18),
  );
  tools = el('div', { class: 'st-tools' }, chipRow, el('span', { class: 'spacer' }), exportButton, deleteAllButton);

  const header = el(
    'header',
    { class: 'st-header' },
    el('div', { class: 'st-title-row' }, el('h1', { class: 'st-title' }, 'Stream'), titleCount, el('span', { class: 'spacer' }), search),
    tools,
  );

  panel = el('div', { class: 'st-panel' });
  toasts = el('div', { class: 'st-toasts' });
  const body = el('div', { class: 'st-body' }, timeline.element, panel);
  const dockWrap = el('div', { class: 'st-dock' }, dock.element);

  root = el('div', { class: 'stream' }, header, body, dockWrap, toasts);

  document.addEventListener('keydown', onDocumentKeyDown);
  document.addEventListener('mouseup', () => window.setTimeout(onSelectionEnd, 0));
  document.addEventListener('keyup', (event) => {
    if (event.shiftKey || event.key === 'Shift') window.setTimeout(onSelectionEnd, 0);
  });
  document.addEventListener('selectionchange', trackSelection);
  return root;
}

// ---- Sync -------------------------------------------------------------

function filterKey(): string {
  return `${ui.query.trim().toLowerCase()}|${ui.filter}`;
}

function matchesFilter(entry: HistoryEntryDTO, now: Date, weekStart: Date): boolean {
  if (ui.filter === 'all') return true;
  const created = new Date(entry.createdAt);
  if (ui.filter === 'today') return isSameDay(created, now);
  if (ui.filter === 'week') return created >= weekStart;
  return entry.language === ui.filter.slice('lang:'.length);
}

function computeVisible(): HistoryEntryDTO[] {
  const query = ui.query.trim().toLowerCase();
  const now = new Date();
  const weekStart = startOfWeek(now);
  return ascending.filter(
    (entry) => matchesFilter(entry, now, weekStart) && (query === '' || entry.text.toLowerCase().includes(query)),
  );
}

function sync(): void {
  const history = state.history;
  const dataChanged = history !== lastHistory;
  if (dataChanged) {
    lastHistory = history;
    ascending = [...history].sort((a, b) => Date.parse(a.createdAt) - Date.parse(b.createdAt));
    const ids = new Set(history.map((entry) => entry.id));
    freshIds = new Set();
    if (knownIds !== null) for (const id of ids) if (!knownIds.has(id)) freshIds.add(id);
    knownIds = ids;
    for (const set of [ui.selected, ui.expanded, ui.original]) for (const id of set) if (!ids.has(id)) set.delete(id);
    if (ui.teachId !== null && !ids.has(ui.teachId)) ui.teachId = null;
    if (ui.filter.startsWith('lang:') && !ascending.some((entry) => entry.language === (ui.filter as string).slice(5))) ui.filter = 'all';
    if (history.length > 0) ui.justCleared = false;
  }

  const key = filterKey();
  if (dataChanged || key !== lastKey) {
    visible = computeVisible();
    timeline.setEntries(visible, { reset: key !== lastKey, fresh: freshIds });
    freshIds = new Set();
    lastKey = key;
  }
  paintChips();
  paintHeader();
  paintPanel();
  dock.refresh();
  paintSelection();
}

function languageChips(): Array<{ code: string; label: string }> {
  const counts = new Map<string, number>();
  for (const entry of ascending) if (isLanguageCode(entry.language)) counts.set(entry.language, (counts.get(entry.language) ?? 0) + 1);
  return [...counts.entries()]
    .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
    .slice(0, MAX_LANGUAGE_CHIPS)
    .map(([code]) => ({ code, label: languageLabel(code) }));
}

function paintChips(): void {
  const languages = languageChips();
  const key = `${ui.filter}|${languages.map((language) => language.code).join(',')}`;
  if (key === lastChipKey) return;
  lastChipKey = key;
  const chip = (filter: Filter, label: string, lang?: string): HTMLElement => {
    const on = ui.filter === filter;
    return el(
      'button',
      {
        class: `st-chip${on ? ' on' : ''}`,
        type: 'button',
        'aria-pressed': String(on),
        lang,
        onclick: () => setFilter(filter),
      },
      label,
    );
  };
  chipRow.replaceChildren(
    chip('all', 'All'),
    chip('today', 'Today'),
    chip('week', 'This week'),
    ...languages.map((language) => chip(`lang:${language.code}`, language.label, language.code)),
  );
}

function paintHeader(): void {
  const hasHistory = state.history.length > 0;
  tools.hidden = !hasHistory;
  exportButton.hidden = !hasHistory;
  deleteAllButton.hidden = !hasHistory;
  searchInput.closest<HTMLElement>('.st-search')!.hidden = !hasHistory;
  searchClear.hidden = ui.query === '';
  if (searchInput.value !== ui.query) searchInput.value = ui.query;
  const searching = ui.query.trim() !== '' && hasHistory;
  titleCount.textContent = searching
    ? `${pluralize(visible.length, 'dictation')} ${visible.length === 1 ? 'matches' : 'match'}`
    : '';
}

function paintPanel(): void {
  const hasHistory = state.history.length > 0;
  const showTimeline = hasHistory && visible.length > 0;
  timeline.element.hidden = !showTimeline;
  panel.hidden = showTimeline;
  if (showTimeline) return;

  const hotkey = state.settings?.hotkey.accelerator ?? '';
  const query = ui.query.trim();
  let heading: string;
  let body: Array<Node | string>;
  let action: HTMLElement | null = null;
  if (!hasHistory && ui.justCleared) {
    heading = 'All dictations deleted';
    body = ['Notes and vocabulary are untouched. The next dictation shows up here.'];
  } else if (!hasHistory) {
    heading = 'Nothing here yet';
    body = hotkey === ''
      ? ['Click the microphone below and start talking. Your dictations land here, newest at the bottom.']
      : ['Press ', el('kbd', { class: 'kbd' }, formatAccelerator(hotkey)), ' in any app and start talking. Your dictations land here, newest at the bottom.'];
  } else if (query !== '') {
    heading = `No dictations match “${query}”`;
    body = ['Check the spelling or clear the filters.'];
    action = el('button', { class: 'btn btn-primary', type: 'button', onclick: () => { ui.filter = 'all'; setQuery('', true); } }, 'Clear search');
  } else {
    heading = 'No dictations here';
    body = ['Nothing matches this filter yet.'];
    action = el('button', { class: 'btn btn-primary', type: 'button', onclick: () => setFilter('all') }, 'Show all');
  }
  panel.replaceChildren(
    el('div', { class: 'st-empty' }, el('h2', {}, heading), el('p', {}, ...body), action),
  );
}

// ---- Header actions ---------------------------------------------------

function setQuery(value: string, focus: boolean): void {
  ui.query = value;
  if (searchInput.value !== value) searchInput.value = value;
  if (focus) searchInput.focus();
  // One repaint per frame however fast the typing is.
  if (searchFrame !== 0) return;
  searchFrame = requestAnimationFrame(() => {
    searchFrame = 0;
    sync();
  });
}

function setFilter(filter: Filter): void {
  ui.filter = filter;
  sync();
}

async function exportCsv(): Promise<void> {
  const result = await api.exportHistoryCsv();
  setNotice(result.ok ? 'success' : 'danger', result.message);
}

async function saveSetting(patch: { languagePin?: string; formattingEnabled?: boolean }): Promise<void> {
  try {
    state.settings = await api.saveSettings(patch);
  } catch (error) {
    setNotice('danger', error instanceof Error ? error.message : String(error));
  }
  dock.refresh();
}

// ---- Bubbles ----------------------------------------------------------

function viewFor(entry: HistoryEntryDTO, rise: boolean): BubbleView {
  return {
    entry,
    query: ui.query.trim().toLowerCase(),
    expanded: ui.expanded.has(entry.id),
    showOriginal: ui.original.has(entry.id),
    selected: ui.selected.has(entry.id),
    teaching: ui.teachId === entry.id,
    rise,
  };
}

function toggleIn(set: Set<string>, entry: HistoryEntryDTO): void {
  if (!set.delete(entry.id)) set.add(entry.id);
  timeline.refreshBubble(entry);
}

const handlers: BubbleHandlers = {
  // Read when a bubble is built, not at module load: the launch flags load after this file runs.
  get previewFeatures(): boolean {
    return previewFeatures();
  },
  copy: (entry) => {
    api.copyToClipboard(entry.text).then(
      () => showToast('Copied'),
      (error: unknown) => setNotice('danger', error instanceof Error ? error.message : String(error)),
    );
  },
  addToNote: (entry, anchor) => pickNote([entry], anchor, 'auto'),
  teach: (entry) => teachFrom(entry),
  cancelTeach: () => endTeach(),
  toggleOriginal: (entry) => toggleIn(ui.original, entry),
  toggleExpand: (entry) => toggleIn(ui.expanded, entry),
  remove: (entry) => confirmDelete(entry),
  select: (entry, how) => selectEntry(entry, how),
};

// ---- Selection (Shift-click) -----------------------------------------

function selectEntry(entry: HistoryEntryDTO, how: 'range' | 'toggle'): void {
  const before = new Set(ui.selected);
  if (how === 'toggle' || ui.selectionAnchor === null || ui.selected.size === 0) {
    if (!ui.selected.delete(entry.id)) ui.selected.add(entry.id);
    ui.selectionAnchor = entry.id;
  } else {
    const a = visible.findIndex((item) => item.id === ui.selectionAnchor);
    const b = visible.findIndex((item) => item.id === entry.id);
    if (a < 0 || b < 0) return;
    ui.selected = new Set(visible.slice(Math.min(a, b), Math.max(a, b) + 1).map((item) => item.id));
  }
  refreshSelectionChanges(before);
}

function clearSelection(): void {
  if (ui.selected.size === 0) return;
  const before = new Set(ui.selected);
  ui.selected.clear();
  ui.selectionAnchor = null;
  refreshSelectionChanges(before);
}

function refreshSelectionChanges(before: Set<string>): void {
  for (const entry of visible) {
    if (before.has(entry.id) !== ui.selected.has(entry.id)) timeline.refreshBubble(entry);
  }
  paintSelection();
}

function paintSelection(): void {
  if (ui.selected.size === 0) {
    dock.setSelection(null);
    return;
  }
  dock.setSelection({
    count: ui.selected.size,
    onAdd: (anchor) => pickNote(selectedEntries(), anchor, 'above'),
    onCancel: clearSelection,
  });
}

function selectedEntries(): HistoryEntryDTO[] {
  return ascending.filter((entry) => ui.selected.has(entry.id));
}

// ---- Notes ------------------------------------------------------------

function pickNote(entries: HistoryEntryDTO[], anchor: HTMLElement, placement: 'auto' | 'above'): void {
  openNotePicker({
    anchor,
    notes: state.notes,
    placement,
    align: placement === 'above' ? 'end' : 'start',
    returnFocus: anchor,
    onPick: (note) => {
      void addToNote(note, entries.map((entry) => entry.text)).catch((error: unknown) => {
        setNotice('danger', error instanceof Error ? error.message : String(error));
      });
    },
  });
}

function titleFrom(text: string): string {
  const flat = text.replace(/\s+/g, ' ').trim();
  if (flat.length <= 40) return flat;
  const cut = flat.slice(0, 40);
  const space = cut.lastIndexOf(' ');
  return space > 16 ? cut.slice(0, space) : cut;
}

/** Appends to one note run one at a time, so two quick adds can never read the same body. */
const noteQueues = new Map<string, Promise<unknown>>();

function enqueueForNote<T>(noteId: string, job: () => Promise<T>): Promise<T> {
  const previous = noteQueues.get(noteId) ?? Promise.resolve();
  const next = previous.catch(() => undefined).then(job);
  noteQueues.set(noteId, next);
  next.then(
    () => undefined,
    () => undefined,
  ).then(() => {
    if (noteQueues.get(noteId) === next) noteQueues.delete(noteId);
  });
  return next;
}

async function freshNote(id: string): Promise<NoteDTO | undefined> {
  return (await api.getNotes()).find((note) => note.id === id);
}

async function addToNote(target: NoteDTO | null, texts: string[]): Promise<void> {
  const addition = texts.join('\n\n');
  let title: string;
  let undo: () => Promise<boolean>;
  if (target === null) {
    const created = await api.saveNote({ title: titleFrom(texts[0] ?? ''), body: addition });
    title = created.title;
    // Undo deletes the note only while it is exactly as it was created: same title, same
    // body and not saved again since (a rename in Notes changes the title and updatedAt).
    undo = () => enqueueForNote(created.id, async () => {
      const latest = await freshNote(created.id);
      if (
        latest === undefined
        || latest.title !== created.title
        || latest.body !== created.body
        || latest.updatedAt !== created.updatedAt
      ) return false;
      await api.deleteNote(created.id);
      return true;
    });
  } else {
    // Read inside the queue: the latest body, not the picker's copy and not what an add that
    // is still running was about to replace.
    const added = await enqueueForNote(target.id, async () => {
      const latest = (await freshNote(target.id)) ?? target;
      const suffix = latest.body.trim() === '' ? addition : `\n\n${addition}`;
      const next = latest.body.trim() === '' ? addition : `${latest.body}${suffix}`;
      await api.saveNote({ id: latest.id, title: latest.title, body: next });
      return { id: latest.id, title: latest.title, suffix };
    });
    title = added.title;
    // Undo takes back exactly the paragraph that was appended, and only while the note still
    // ends with exactly that text. Anything typed after it, even whitespace, makes it refuse.
    undo = () => enqueueForNote(added.id, async () => {
      const latest = await freshNote(added.id);
      if (latest === undefined || !latest.body.endsWith(added.suffix)) return false;
      await api.saveNote({
        id: latest.id,
        title: latest.title,
        body: latest.body.slice(0, latest.body.length - added.suffix.length),
      });
      return true;
    });
  }
  state.notes = await api.getNotes();
  clearSelection();
  showToast(`Added to ${title.trim() || 'Untitled note'}`, {
    label: 'Undo',
    run: () => {
      undo().then(
        async (done) => {
          state.notes = await api.getNotes();
          if (!done) showToast('Can’t undo: the note has changed since');
        },
        (error: unknown) => setNotice('danger', error instanceof Error ? error.message : String(error)),
      );
    },
  });
}

// ---- Toast ------------------------------------------------------------

function showToast(message: string, action?: { label: string; run: () => void }): void {
  if (toastTimer !== 0) window.clearTimeout(toastTimer);
  const dismiss = (): void => {
    if (toastTimer !== 0) window.clearTimeout(toastTimer);
    toastTimer = 0;
    toasts.replaceChildren();
  };
  toasts.replaceChildren(
    el(
      'div',
      { class: 'toast st-toast', role: 'status' },
      el('span', {}, message),
      action
        ? el('button', { class: 'toast-action', type: 'button', onclick: () => { dismiss(); action.run(); } }, action.label)
        : null,
    ),
  );
  toastTimer = window.setTimeout(dismiss, action ? TOAST_MS : PLAIN_TOAST_MS);
}

// ---- Teach a fix ------------------------------------------------------

interface SelectionInfo {
  id: string;
  text: string;
  rect: DOMRect;
  range: Range;
}

let lastSelection: SelectionInfo | null = null;
const MAX_FIX_CHARS = 80;

function readSelection(): SelectionInfo | null {
  const selection = window.getSelection();
  if (selection === null || selection.rangeCount === 0 || selection.isCollapsed) return null;
  const range = selection.getRangeAt(0);
  const startText = (range.startContainer.parentElement)?.closest<HTMLElement>('.bubble-text');
  const endText = (range.endContainer.parentElement)?.closest<HTMLElement>('.bubble-text');
  if (!startText || startText !== endText || root === null || !root.contains(startText)) return null;
  const text = selection.toString().replace(/\s+/g, ' ').trim();
  if (text === '' || text.length > MAX_FIX_CHARS) return null;
  const id = startText.closest<HTMLElement>('.bubble')?.dataset.id;
  if (id === undefined) return null;
  const rects = range.getClientRects();
  const rect = rects[rects.length - 1] ?? range.getBoundingClientRect();
  return { id, text, rect, range: range.cloneRange() };
}

function trackSelection(): void {
  const info = readSelection();
  if (info !== null) lastSelection = info;
  else if (!document.activeElement?.closest('.floating')) lastSelection = null;
}

/** A drag, double-click or Shift+arrow selection inside a dictation opens the fix form. */
function onSelectionEnd(): void {
  if (root === null || !root.isConnected || floatingIsOpen()) return;
  const info = readSelection();
  if (info !== null) openFix(info);
}

function teachFrom(entry: HistoryEntryDTO): void {
  if (lastSelection !== null && lastSelection.id === entry.id) {
    openFix(lastSelection);
    return;
  }
  // No selection: put the dictation in select mode and say what to do.
  const previous = ui.teachId;
  ui.teachId = entry.id;
  for (const id of [previous, entry.id]) {
    const target = ascending.find((item) => item.id === id);
    if (target) timeline.refreshBubble(target);
  }
}

function endTeach(): void {
  const id = ui.teachId;
  ui.teachId = null;
  const target = ascending.find((item) => item.id === id);
  if (target) timeline.refreshBubble(target);
}

function openFix(info: SelectionInfo): void {
  const entry = ascending.find((item) => item.id === info.id);
  if (!entry) return;
  const supported = typeof CSS !== 'undefined' && 'highlights' in CSS && typeof Highlight !== 'undefined';
  if (supported) CSS.highlights.set('uv-fix-target', new Highlight(info.range));
  openTeachFix({
    rect: info.rect,
    heard: info.text,
    onSave: async (replacement) => {
      await api.addReplacement({
        match: info.text,
        replacement,
        language: isLanguageCode(entry.language) ? entry.language : 'auto',
      });
      showToast(`Fix saved: ${info.text} → ${replacement}`);
    },
    onClose: () => {
      if (supported) CSS.highlights.delete('uv-fix-target');
      if (ui.teachId !== null) endTeach();
    },
  });
}

// ---- Delete -----------------------------------------------------------

interface ConfirmOptions {
  title: string;
  body: string;
  confirmLabel: string;
  onConfirm: () => Promise<void>;
}

function confirmDialog(options: ConfirmOptions): void {
  const opener = document.activeElement instanceof HTMLElement ? document.activeElement : null;
  const cancel = el('button', { class: 'btn btn-secondary', type: 'button' }, 'Cancel');
  const confirm = el('button', { class: 'btn btn-tone', type: 'button' }, options.confirmLabel);
  const panelEl = el(
    'div',
    { class: 'dialog-panel', role: 'alertdialog', 'aria-modal': 'true', 'aria-labelledby': 'st-dialog-title', 'aria-describedby': 'st-dialog-body' },
    el('h2', { class: 'dialog-title', id: 'st-dialog-title' }, options.title),
    el('p', { class: 'dialog-body', id: 'st-dialog-body' }, options.body),
    el('div', { class: 'dialog-actions' }, cancel, confirm),
  );
  const overlay = el('div', { class: 'dialog-overlay' }, panelEl);
  const close = (): void => {
    overlay.remove();
    document.removeEventListener('keydown', onKey, true);
    if (opener?.isConnected) opener.focus();
  };
  function onKey(event: KeyboardEvent): void {
    if (event.key === 'Escape') {
      event.preventDefault();
      event.stopPropagation();
      close();
    } else if (event.key === 'Tab') {
      // Two buttons: keep focus inside the dialog.
      event.preventDefault();
      (document.activeElement === cancel ? confirm : cancel).focus();
    }
  }
  cancel.addEventListener('click', close);
  overlay.addEventListener('mousedown', (event) => {
    if (event.target === overlay) close();
  });
  confirm.addEventListener('click', () => {
    confirm.disabled = true;
    options.onConfirm().then(close, (error: unknown) => {
      close();
      setNotice('danger', error instanceof Error ? error.message : String(error));
    });
  });
  document.addEventListener('keydown', onKey, true);
  document.body.append(overlay);
  cancel.focus();
}

function confirmDelete(entry: HistoryEntryDTO): void {
  confirmDialog({
    title: 'Delete this dictation?',
    body: 'It is removed from this PC. You can’t undo this.',
    confirmLabel: 'Delete',
    onConfirm: async () => {
      await api.removeHistory(entry.id);
      state.history = await api.getHistory();
      render();
    },
  });
}

function confirmDeleteAll(): void {
  const count = state.history.length;
  if (count === 0) return;
  confirmDialog({
    title: 'Delete all dictations?',
    body: `This removes ${pluralize(count, 'dictation')} from this PC. Notes and your vocabulary stay. You can’t undo this.`,
    confirmLabel: `Delete ${pluralize(count, 'dictation')}`,
    onConfirm: async () => {
      await api.clearHistory();
      state.history = await api.getHistory();
      ui.justCleared = true;
      ui.selected.clear();
      ui.query = '';
      ui.filter = 'all';
      render();
    },
  });
}

// ---- Date jump --------------------------------------------------------

const JUMP_ROWS = 7;

function openDayJump(anchor: HTMLElement): void {
  const days = timeline.days();
  const current = timeline.currentDay();
  const list = el('div', { class: 'dj-list', role: 'listbox', 'aria-label': 'Days' });
  const handleRef: { close: () => void } = { close: () => undefined };
  days.slice(0, JUMP_ROWS).forEach((day, index) => {
    const isCurrent = day.key === current;
    list.append(
      el(
        'button',
        {
          class: `dj-row${isCurrent ? ' is-current' : ''}`,
          type: 'button',
          role: 'option',
          'aria-selected': String(isCurrent),
          onclick: () => {
            handleRef.close();
            timeline.jumpToDay(day.key);
          },
        },
        el('span', {}, day.label),
        el('span', { class: 'dj-count tnum' }, index === 0 ? pluralize(day.count, 'dictation') : formatCount(day.count)),
      ),
    );
  });

  const dateInput = el('input', { class: 'field-input dj-date', type: 'date', 'aria-label': 'Choose a date' });
  const dateRow = el('div', { class: 'dj-date-row' }, dateInput);
  dateRow.hidden = true;
  const choose = el(
    'button',
    {
      class: 'dj-row dj-choose',
      type: 'button',
      onclick: () => {
        dateRow.hidden = !dateRow.hidden;
        if (!dateRow.hidden) dateInput.focus();
      },
    },
    icon(STREAM_ICONS.calendar, 16),
    el('span', {}, 'Choose a date'),
  );
  dateInput.addEventListener('change', () => {
    if (dateInput.value === '') return;
    // The newest day on or before the chosen date, or the oldest day if it is earlier than all.
    const target = days.find((day) => day.key <= dateInput.value) ?? days[days.length - 1];
    if (!target) return;
    handleRef.close();
    timeline.jumpToDay(target.key);
  });
  const content = el('div', { class: 'dj' }, list, el('div', { class: 'np-sep', role: 'separator' }), choose, dateRow);
  const handle = openFloating({
    content,
    anchor,
    placement: 'below',
    className: 'dj-surface',
    label: 'Jump to a day',
    returnFocus: anchor,
  });
  handleRef.close = handle.close;
  (list.querySelector<HTMLElement>('.is-current') ?? list.querySelector<HTMLElement>('.dj-row'))?.focus();
}

// ---- Keyboard ---------------------------------------------------------

function onDocumentKeyDown(event: KeyboardEvent): void {
  if (root === null || !root.isConnected || event.defaultPrevented) return;
  if (event.key === 'Escape') {
    if (ui.teachId !== null) {
      event.preventDefault();
      endTeach();
    } else if (ui.selected.size > 0) {
      event.preventDefault();
      clearSelection();
    }
  } else if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'f' && !searchInput.closest<HTMLElement>('.st-search')?.hidden) {
    event.preventDefault();
    searchInput.focus();
    searchInput.select();
  }
}
