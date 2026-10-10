import { api } from '../api.js';
import { el, icon, ICONS } from '../components/dom.js';
import { relativeTime } from '../components/format.js';
import { state, render, setNotice } from '../shell.js';
import type { NoteDTO } from '../../preload/types.js';

const SEARCH_ICON = 'M11 19a8 8 0 1 0 0-16 8 8 0 0 0 0 16zM21 21l-4.3-4.3';
const AUTOSAVE_MS = 500;
const UNDO_MS = 5000;

// Module state: the page is rebuilt on every shell repaint, so anything the user is
// in the middle of (selection, search, an unsaved edit, the undo toast) lives here.
let selectedId: string | null = null;
let query = '';
let draft: { id: string; title: string; body: string } | null = null;
let saveTimer = 0;
let saveError: string | null = null;
let retryDelay = 1000;
// Bumped when a draft is discarded, so a save that is still in flight for it is ignored when it returns.
let generation = 0;
let focusRequest: { field: 'title' | 'body' | 'search'; start: number; end: number } | null = null;
let undo: { note: { id: string; title: string; body: string; createdAt: string; updatedAt: string }; index: number; timer: number } | null = null;

function wordCount(text: string): number {
  const trimmed = text.trim();
  return trimmed.length === 0 ? 0 : trimmed.split(/\s+/).length;
}

function formatCount(value: number): string {
  return value.toLocaleString('de-DE');
}

function firstLine(body: string): string {
  return body.split('\n').find((line) => line.trim().length > 0)?.trim() ?? '';
}

function currentTitle(note: NoteDTO): string {
  return draft && draft.id === note.id ? draft.title : note.title;
}

function currentBody(note: NoteDTO): string {
  return draft && draft.id === note.id ? draft.body : note.body;
}

function visibleNotes(): NoteDTO[] {
  const needle = query.trim().toLowerCase();
  if (needle.length === 0) return state.notes;
  return state.notes.filter(
    (note) => currentTitle(note).toLowerCase().includes(needle) || currentBody(note).toLowerCase().includes(needle),
  );
}

// ---- Page -------------------------------------------------------------

export function renderNotesPage(): HTMLElement {
  if (selectedId && !state.notes.some((note) => note.id === selectedId)) selectedId = null;
  if (!selectedId && state.notes.length > 0) selectedId = state.notes[0]!.id;

  // The shell rebuilds the page on any repaint (a notice, a background refresh). The old
  // DOM is still in the document here, so carry the caret over to the new one.
  const active = document.activeElement;
  if ((active instanceof HTMLInputElement || active instanceof HTMLTextAreaElement) && active.matches('.notes-title, .notes-body, .notes-search')) {
    focusRequest = {
      field: (active.dataset.field ?? 'search') as 'title' | 'body' | 'search',
      start: active.selectionStart ?? 0,
      end: active.selectionEnd ?? 0,
    };
  }

  const root = el('div', { class: 'notes-page' });

  if (state.notes.length === 0) {
    root.classList.add('notes-page-empty');
    root.append(
      el(
        'div',
        { class: 'empty-state notes-empty' },
        el('h3', {}, 'No notes yet'),
        el('p', {}, 'Notes keep what you want to reuse. Add the latest dictation to a note from the Stream, or start a blank one.'),
        el(
          'div',
          { class: 'notes-empty-action' },
          el('button', { class: 'btn btn-primary', type: 'button', onclick: () => void createNote() } as never, 'New note'),
        ),
      ),
    );
    appendToast(root);
    return root;
  }

  const selected = state.notes.find((note) => note.id === selectedId) ?? null;

  const search = el('input', {
    class: 'field-input notes-search',
    type: 'search',
    value: query,
    placeholder: 'Search notes',
    'aria-label': 'Search notes',
    dataset: { field: 'search' },
  } as never);
  const list = el('div', { class: 'notes-list', role: 'listbox', 'aria-label': 'Notes' } as never);

  const fillList = (): void => {
    const notes = visibleNotes();
    list.replaceChildren(
      ...(notes.length === 0
        ? [el('p', { class: 'notes-none muted' }, 'No notes match.')]
        : notes.map((note, index) => noteRow(note, index === 0 && !notes.some((n) => n.id === selectedId)))),
    );
  };
  search.addEventListener('input', () => {
    query = search.value;
    fillList();
  });
  list.addEventListener('keydown', (event) => {
    if (event.key !== 'ArrowDown' && event.key !== 'ArrowUp') return;
    const rows = [...list.querySelectorAll<HTMLButtonElement>('.notes-row')];
    const at = rows.indexOf(document.activeElement as HTMLButtonElement);
    if (at < 0) return;
    const next = rows[at + (event.key === 'ArrowDown' ? 1 : -1)];
    if (!next) return;
    event.preventDefault();
    rows.forEach((row) => (row.tabIndex = -1));
    next.tabIndex = 0;
    next.focus();
  });
  fillList();

  const listPane = el('div', { class: 'notes-listpane' }, el('div', { class: 'notes-searchwrap' }, icon(SEARCH_ICON, 15), search), list);
  root.append(el('div', { class: 'notes-layout' }, listPane, selected ? documentPane(selected, fillList) : el('div', { class: 'notes-doc' })));
  appendToast(root);

  if (focusRequest) {
    const request = focusRequest;
    focusRequest = null;
    requestAnimationFrame(() => {
      const target =
        root.querySelector<HTMLInputElement | HTMLTextAreaElement>(`[data-field="${request.field}"]`);
      if (!target) return;
      target.focus();
      target.setSelectionRange(request.start, request.end);
    });
  }
  return root;
}

function noteRow(note: NoteDTO, tabbable: boolean): HTMLElement {
  const title = currentTitle(note);
  const body = currentBody(note);
  const preview = firstLine(body);
  const isSelected = note.id === selectedId;
  return el(
    'button',
    {
      class: 'notes-row',
      type: 'button',
      role: 'option',
      'aria-selected': isSelected ? 'true' : 'false',
      tabIndex: isSelected || tabbable ? 0 : -1,
      onclick: () => selectNote(note.id),
    } as never,
    el('span', { class: 'notes-row-title truncate' }, title.trim() || 'Untitled note'),
    preview
      ? el('span', { class: 'notes-row-preview truncate', dir: 'auto' }, preview)
      : el('span', { class: 'notes-row-preview notes-row-none truncate' }, 'No text yet'),
    el('span', { class: 'notes-row-meta tnum' }, `${formatCount(wordCount(body))} words · ${relativeTime(note.updatedAt)}`),
  );
}

function documentPane(note: NoteDTO, refreshList: () => void): HTMLElement {
  const title = el('input', {
    class: 'notes-title',
    value: currentTitle(note),
    placeholder: 'Untitled note',
    'aria-label': 'Note title',
    dir: 'auto',
    dataset: { field: 'title' },
  } as never);
  const body = el('textarea', {
    class: 'notes-body',
    value: currentBody(note),
    placeholder: 'Write, or dictate with your hotkey',
    'aria-label': 'Note body',
    dataset: { field: 'body' },
  } as never);
  const meta = el('p', { class: 'notes-meta tnum' });
  const setMeta = (updatedAt: string): void => {
    meta.textContent = `${formatCount(wordCount(body.value))} words · Edited ${relativeTime(updatedAt)}`;
  };
  setMeta(note.updatedAt);

  const onEdit = (): void => {
    draft = { id: note.id, title: title.value, body: body.value };
    setMeta(new Date().toISOString());
    refreshList();
    window.clearTimeout(saveTimer);
    saveTimer = window.setTimeout(() => void flushSave(), AUTOSAVE_MS);
  };
  title.addEventListener('input', onEdit);
  body.addEventListener('input', onEdit);
  // Enter in the title moves to the text, like a document.
  title.addEventListener('keydown', (event) => {
    if (event.key === 'Enter') {
      event.preventDefault();
      body.focus();
    }
  });
  return el(
    'div',
    { class: 'notes-doc' },
    el(
      'div',
      { class: 'notes-toolbar' },
      el(
        'button',
        { class: 'btn btn-ghost', type: 'button', onclick: () => void copyMarkdown(title.value, body.value) } as never,
        icon(ICONS.copy, 15),
        'Copy as Markdown',
      ),
      el(
        'button',
        { class: 'btn btn-ghost', type: 'button', onclick: () => void deleteSelected(note.id) } as never,
        icon(ICONS.trash, 15),
        'Delete',
      ),
    ),
    draft && saveError
      ? el(
          'div',
          { class: 'notice notice-danger notes-saveerror', role: 'alert' },
          el('span', {}, `This note is not saved: ${saveError}. Retrying.`),
          el('button', { class: 'btn btn-secondary btn-sm', type: 'button', onclick: () => void flushSave() } as never, 'Retry now'),
          el('button', { class: 'btn btn-secondary btn-sm', type: 'button', onclick: discardChanges } as never, 'Discard changes'),
        )
      : null,
    el('div', { class: 'notes-scroll' }, el('div', { class: 'notes-column' }, title, meta, body)),
  );
}

function appendToast(root: HTMLElement): void {
  if (!undo) return;
  root.append(
    el(
      'div',
      { class: 'toast notes-toast', role: 'status' },
      el('span', {}, 'Note deleted.'),
      el('button', { class: 'toast-action', type: 'button', onclick: () => void undoDelete() } as never, 'Undo'),
    ),
  );
}

// ---- Actions ----------------------------------------------------------

function failure(action: string, error: unknown): void {
  setNotice('danger', `${action}: ${error instanceof Error ? error.message : String(error)}`);
}

function selectNote(id: string): void {
  if (id === selectedId) return;
  void flushSave().then((saved) => {
    if (!saved) return;
    selectedId = id;
    render();
  });
}

/**
 * Saves the pending edit. Resolves false (and tells the user) when the save fails; the draft is kept,
 * a banner offers Discard, and the autosave retries with a doubling delay (1 s up to 30 s).
 */
async function flushSave(): Promise<boolean> {
  window.clearTimeout(saveTimer);
  const pending = draft;
  if (!pending) {
    saveError = null;
    retryDelay = 1000;
    return true;
  }
  const started = generation;
  try {
    const saved = await api.saveNote({ id: pending.id, title: pending.title.trim() ? pending.title : '', body: pending.body });
    if (started !== generation) return true;
    // Patch the one note in place: a full refresh would replace the list under the editor.
    const at = state.notes.findIndex((note) => note.id === saved.id);
    if (at >= 0) state.notes[at] = saved;
    else state.notes.unshift(saved);
    if (draft === pending) draft = null;
    retryDelay = 1000;
    if (saveError) {
      saveError = null;
      render();
    }
    return true;
  } catch (error) {
    if (started !== generation) return true;
    const first = saveError === null;
    saveError = error instanceof Error ? error.message : String(error);
    if (first) failure('Could not save the note', error);
    saveTimer = window.setTimeout(() => void flushSave(), retryDelay);
    retryDelay = Math.min(retryDelay * 2, 30000);
    if (first) render();
    return false;
  }
}

function discardChanges(): void {
  window.clearTimeout(saveTimer);
  generation++;
  draft = null;
  saveError = null;
  retryDelay = 1000;
  render();
}

// An edit still inside the autosave window must not be lost when the window closes or hides.
window.addEventListener('pagehide', () => void flushSave());
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'hidden') void flushSave();
});

async function createNote(): Promise<void> {
  if (!(await flushSave())) return;
  try {
    const created = await api.saveNote({ title: '', body: '' });
    state.notes.unshift(created);
    selectedId = created.id;
    query = '';
    focusRequest = { field: 'title', start: 0, end: 0 };
    render();
  } catch (error) {
    failure('Could not create the note', error);
  }
}

async function copyMarkdown(title: string, body: string): Promise<void> {
  const heading = title.trim();
  try {
    await api.copyToClipboard(heading ? `# ${heading}\n\n${body}` : body);
  } catch (error) {
    failure('Could not copy the note', error);
    return;
  }
  setNotice('success', 'Copied as Markdown.');
}

async function deleteSelected(id: string): Promise<void> {
  if (draft?.id === id) {
    // Save the pending edit first so Undo brings back the latest text. If the save fails the note is
    // being deleted anyway, so go on and drop the draft instead of letting the failure block the delete.
    await flushSave();
    window.clearTimeout(saveTimer);
    generation++;
    draft = null;
    saveError = null;
    retryDelay = 1000;
  } else if (!(await flushSave())) return;
  let removed;
  try {
    removed = await api.deleteNote(id);
  } catch (error) {
    failure('Could not delete the note', error);
    return;
  }
  if (!removed) {
    // Already gone (deleted elsewhere): resync instead of pretending it worked.
    try {
      state.notes = await api.getNotes();
    } catch (error) {
      failure('Could not reload the notes', error);
      return;
    }
    setNotice('warning', 'That note was already deleted.');
    return;
  }
  const gone = state.notes.find((note) => note.id === id);
  state.notes = state.notes.filter((note) => note.id !== id);
  selectedId = state.notes[Math.min(removed.index, state.notes.length - 1)]?.id ?? null;
  if (undo) window.clearTimeout(undo.timer);
  const timer = window.setTimeout(() => {
    undo = null;
    document.querySelector('.notes-toast')?.remove();
  }, UNDO_MS);
  undo = {
    note: { id: removed.id, title: removed.title, body: removed.body, createdAt: gone?.createdAt ?? '', updatedAt: gone?.updatedAt ?? '' },
    index: removed.index,
    timer,
  };
  render();
}

async function undoDelete(): Promise<void> {
  const pending = undo;
  if (!pending) return;
  window.clearTimeout(pending.timer);
  try {
    // Restore puts the note back where it was, so Undo does not also reorder the list.
    await api.restoreNote(
      { id: pending.note.id, title: pending.note.title, body: pending.note.body, createdAt: pending.note.createdAt || undefined, updatedAt: pending.note.updatedAt || undefined },
      pending.index,
    );
    state.notes = await api.getNotes();
  } catch (error) {
    // Keep the toast so the user can try again; the note is not lost until it expires.
    pending.timer = window.setTimeout(() => {
      undo = null;
      document.querySelector('.notes-toast')?.remove();
    }, UNDO_MS);
    failure('Could not restore the note', error);
    return;
  }
  undo = null;
  selectedId = pending.note.id;
  render();
}

/** The header button for the Notes page. */
export function headerActionsForNotes(): HTMLElement[] {
  return [
    el(
      'button',
      { class: 'btn btn-primary', type: 'button', onclick: () => void createNote() } as never,
      icon(ICONS.plus, 14),
      'New note',
    ),
  ];
}
