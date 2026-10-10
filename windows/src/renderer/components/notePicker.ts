/**
 * The "Add to note" picker: a search field, the three most recent notes and New note.
 * Picking a row calls `onPick` with the note, or null for a new one.
 */

import type { NoteDTO } from '../../preload/types.js';
import { el, icon } from './dom.js';
import { STREAM_ICONS } from './dockIcons.js';
import { openFloating, type FloatingHandle } from './bubblePopover.js';

export interface NotePickerOptions {
  anchor: HTMLElement | DOMRect;
  notes: readonly NoteDTO[];
  placement?: 'below' | 'above' | 'auto';
  align?: 'start' | 'end';
  returnFocus?: HTMLElement | null;
  /** The note to append to, or null to start a new one. */
  onPick: (note: NoteDTO | null) => void;
}

const RECENT = 3;

/** "3 min ago", "2 h ago", "1 wk ago", "2 mo ago". */
function ago(iso: string): string {
  const minutes = Math.max(0, Math.round((Date.now() - Date.parse(iso)) / 60_000));
  if (minutes < 1) return 'just now';
  if (minutes < 60) return `${minutes} min ago`;
  const hours = Math.round(minutes / 60);
  if (hours < 24) return `${hours} h ago`;
  const days = Math.round(hours / 24);
  if (days < 7) return `${days} d ago`;
  if (days < 30) return `${Math.round(days / 7)} wk ago`;
  return `${Math.round(days / 30)} mo ago`;
}
const SEARCH_RESULTS = 6;

export function openNotePicker(options: NotePickerOptions): FloatingHandle {
  const byRecent = [...options.notes].sort((a, b) => Date.parse(b.updatedAt) - Date.parse(a.updatedAt));
  let query = '';
  let active = 0;
  /** What the rows currently stand for, in order; null is the New note row. */
  let rows: Array<NoteDTO | null> = [];

  const input = el('input', {
    class: 'field-input np-input',
    type: 'text',
    placeholder: 'Find a note',
    'aria-label': 'Find a note',
    autocomplete: 'off',
    role: 'combobox',
    'aria-expanded': 'true',
    'aria-controls': 'np-list',
  });
  const field = el('div', { class: 'np-field' }, icon(STREAM_ICONS.search, 16), input);
  const list = el('div', { class: 'np-list', id: 'np-list', role: 'listbox', 'aria-label': 'Notes' });
  const root = el('div', { class: 'np' }, field, list);

  let opened = false;
  // Rows first, so the surface is measured and placed with its real height.
  paint();
  const handle = openFloating({
    content: root,
    anchor: options.anchor,
    placement: options.placement ?? 'auto',
    align: options.align ?? 'start',
    className: 'np-surface',
    label: 'Add to note',
    returnFocus: options.returnFocus ?? null,
  });

  function pick(index: number): void {
    const row = rows[index];
    if (row === undefined) return;
    handle.close();
    options.onPick(row);
  }

  function row(note: NoteDTO | null, index: number): HTMLElement {
    const isActive = index === active;
    const label = note === null ? 'New note' : note.title.trim() || 'Untitled note';
    return el(
      'button',
      {
        class: `np-row${isActive ? ' is-active' : ''}${note === null ? ' np-new' : ''}`,
        type: 'button',
        role: 'option',
        id: `np-row-${index}`,
        'aria-selected': String(isActive),
        tabindex: -1,
        onmousemove: () => {
          if (active === index) return;
          active = index;
          paint();
        },
        onclick: () => pick(index),
      },
      icon(note === null ? STREAM_ICONS.plus : STREAM_ICONS.note, 16),
      el('span', { class: 'np-title' }, label),
      note === null ? null : el('span', { class: 'np-time' }, ago(note.updatedAt)),
    );
  }

  function paint(): void {
    const trimmed = query.trim().toLowerCase();
    const matches = trimmed === ''
      ? byRecent.slice(0, RECENT)
      : byRecent
        .filter((note) => `${note.title}\n${note.body}`.toLowerCase().includes(trimmed))
        .slice(0, SEARCH_RESULTS);
    rows = [...matches, null];
    active = Math.min(active, rows.length - 1);

    const children: Node[] = [];
    if (matches.length > 0) {
      children.push(el('div', { class: 'np-label' }, trimmed === '' ? 'Recent notes' : 'Notes'));
      matches.forEach((note, index) => children.push(row(note, index)));
    } else if (trimmed !== '') {
      children.push(el('p', { class: 'np-empty' }, 'No note matches that search.'));
    }
    children.push(el('div', { class: 'np-sep', role: 'separator' }));
    children.push(row(null, rows.length - 1));
    list.replaceChildren(...children);
    input.setAttribute('aria-activedescendant', `np-row-${active}`);
    // A search changes how many rows there are; keep the surface inside the window.
    if (opened) handle.reposition();
  }

  input.addEventListener('input', () => {
    query = input.value;
    active = 0;
    paint();
  });
  root.addEventListener('keydown', (event: KeyboardEvent) => {
    if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
      event.preventDefault();
      active = (active + (event.key === 'ArrowDown' ? 1 : -1) + rows.length) % rows.length;
      paint();
    } else if (event.key === 'Enter') {
      event.preventDefault();
      pick(active);
    }
  });

  opened = true;
  input.focus();
  return handle;
}
