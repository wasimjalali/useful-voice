import { api } from '../api.js';
import { el, icon, ICONS } from '../components/dom.js';
import { relativeTime } from '../components/format.js';
import { state, render, setNotice, refresh } from '../shell.js';
import type { NoteDTO } from '../../preload/types.js';

let undoTimer = 0;

// ---- Notes ------------------------------------------------------------

export function renderNotes(): Node {
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

// ---- Actions ----------------------------------------------------------

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

export async function undoDeleteNote(): Promise<void> {
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

/** The header buttons for the Notes page. */
export function notesHeaderActions(): Node[] {
  return [
    el(
      'button',
      { class: 'btn btn-primary', type: 'button', onclick: () => void createNote() } as never,
      icon(ICONS.plus, 14),
      'New note',
    ),
  ];
}

// TEMP until merge: the real Notes page replaces these.
export const renderNotesPage = renderNotes;
export const headerActionsForNotes = notesHeaderActions;
