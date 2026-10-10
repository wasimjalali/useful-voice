/**
 * One dictation in the Stream: a lifted bubble with the text, a meta row and the actions
 * that appear on hover and on focus. The bubble is built from a view description and
 * rebuilt as a whole when any part of it changes, so there is no half-updated state.
 */

import type { HistoryEntryDTO } from '../../preload/types.js';
import { el, icon } from './dom.js';
import { STREAM_ICONS } from './dockIcons.js';
import { openFloating } from './bubblePopover.js';
import {
  countWords,
  formatDuration,
  formatTime,
  excerptAround,
  isLanguageCode,
  isRtlText,
  languageLabel,
  pluralize,
  wordDiff,
  type DiffToken,
} from './bubbleFormat.js';

export interface BubbleView {
  entry: HistoryEntryDTO;
  /** Lower-cased search text, or ''. */
  query: string;
  expanded: boolean;
  showOriginal: boolean;
  selected: boolean;
  /** The words-it-got-wrong select mode. */
  teaching: boolean;
  /** Animate in: the dictation just arrived. */
  rise: boolean;
}

export interface BubbleHandlers {
  copy: (entry: HistoryEntryDTO) => void;
  addToNote: (entry: HistoryEntryDTO, anchor: HTMLElement) => void;
  teach: (entry: HistoryEntryDTO, bubble: HTMLElement) => void;
  cancelTeach: () => void;
  toggleOriginal: (entry: HistoryEntryDTO) => void;
  toggleExpand: (entry: HistoryEntryDTO) => void;
  remove: (entry: HistoryEntryDTO) => void;
  /** Extend the selection to this bubble (`range`) or flip just this one (`toggle`). */
  select: (entry: HistoryEntryDTO, how: 'range' | 'toggle') => void;
  previewFeatures: boolean;
}

/** A dictation counts as having an original when the engine's raw text differs. */
export function hasOriginal(entry: HistoryEntryDTO): boolean {
  return entry.rawText.trim() !== '' && entry.rawText.trim() !== entry.text.trim();
}

function highlight(text: string, query: string): Node[] {
  if (query === '') return [document.createTextNode(text)];
  const nodes: Node[] = [];
  const lower = text.toLowerCase();
  let from = 0;
  for (;;) {
    const at = lower.indexOf(query, from);
    if (at < 0) break;
    if (at > from) nodes.push(document.createTextNode(text.slice(from, at)));
    nodes.push(el('mark', { class: 'hit' }, text.slice(at, at + query.length)));
    from = at + query.length;
  }
  if (from < text.length) nodes.push(document.createTextNode(text.slice(from)));
  return nodes;
}

function originalNodes(entry: HistoryEntryDTO): Node[] {
  const tokens = wordDiff(entry.rawText, entry.text);
  if (tokens === null) {
    return [el('s', {}, entry.rawText), document.createTextNode(' '), el('ins', {}, entry.text)];
  }
  // Consecutive words of one kind share a node.
  const nodes: Node[] = [];
  let index = 0;
  while (index < tokens.length) {
    const kind = (tokens[index] as DiffToken).kind;
    const words: string[] = [];
    while (index < tokens.length && (tokens[index] as DiffToken).kind === kind) {
      words.push((tokens[index] as DiffToken).text);
      index++;
    }
    if (nodes.length > 0) nodes.push(document.createTextNode(' '));
    const text = words.join(' ');
    nodes.push(kind === 'same' ? document.createTextNode(text) : el(kind === 'removed' ? 's' : 'ins', {}, text));
  }
  return nodes;
}

function bodyNodes(view: BubbleView): Node[] {
  if (view.showOriginal && hasOriginal(view.entry)) return originalNodes(view.entry);
  if (view.query !== '' && !view.expanded) {
    return highlight(excerptAround(view.entry.text, view.query).text, view.query);
  }
  return highlight(view.entry.text, view.query);
}

function metaParts(entry: HistoryEntryDTO): string[] {
  const parts = [formatTime(entry.createdAt)];
  if (isLanguageCode(entry.language)) parts.push(languageLabel(entry.language));
  parts.push(pluralize(countWords(entry.text), 'word'));
  parts.push(formatDuration(entry.durationSeconds));
  parts.push(entry.appName !== '' ? `into ${entry.appName}` : 'saved and copied');
  return parts;
}

interface MenuItem {
  label: string;
  icon: string;
  danger?: boolean;
  disabled?: boolean;
  title?: string;
  run: () => void;
}

function openMenu(anchor: HTMLElement, items: MenuItem[], returnFocus: HTMLElement | null): void {
  const buttons: HTMLButtonElement[] = [];
  const menu = el('div', { class: 'bm', role: 'menu' });
  items.forEach((item, index) => {
    if (item.danger && index > 0) menu.append(el('div', { class: 'bm-sep', role: 'separator' }));
    const button = el(
      'button',
      {
        class: `bm-item${item.danger ? ' is-danger' : ''}`,
        type: 'button',
        role: 'menuitem',
        disabled: item.disabled === true,
        title: item.title,
        onclick: () => {
          handle.close();
          item.run();
        },
      },
      icon(item.icon, 16),
      el('span', {}, item.label),
    );
    buttons.push(button);
    menu.append(button);
  });
  const handle = openFloating({
    content: menu,
    anchor,
    placement: 'auto',
    align: 'end',
    className: 'bm-surface',
    label: 'Dictation actions',
    role: 'menu',
    returnFocus,
  });
  menu.addEventListener('keydown', (event: KeyboardEvent) => {
    if (event.key !== 'ArrowDown' && event.key !== 'ArrowUp') return;
    event.preventDefault();
    const enabled = buttons.filter((button) => !button.disabled);
    const at = enabled.indexOf(document.activeElement as HTMLButtonElement);
    const next = (at + (event.key === 'ArrowDown' ? 1 : -1) + enabled.length) % enabled.length;
    enabled[next]?.focus();
  });
  buttons.find((button) => !button.disabled)?.focus();
}

/** The actions in the order the strip shows them, plus the extra ones the More menu holds. */
function menuItems(entry: HistoryEntryDTO, handlers: BubbleHandlers, view: BubbleView, anchor: HTMLElement, bubble: HTMLElement, all: boolean): MenuItem[] {
  const items: MenuItem[] = [];
  if (all) {
    items.push(
      { label: 'Copy', icon: STREAM_ICONS.copy, run: () => handlers.copy(entry) },
      { label: 'Add to note', icon: STREAM_ICONS.notePlus, run: () => handlers.addToNote(entry, anchor) },
      { label: 'Teach a fix', icon: STREAM_ICONS.fix, run: () => handlers.teach(entry, bubble) },
    );
  }
  if (handlers.previewFeatures) {
    items.push({
      label: 'Reprocess',
      icon: STREAM_ICONS.reprocess,
      disabled: true,
      title: 'Saved recordings are not available on Windows yet.',
      run: () => undefined,
    });
  }
  if (hasOriginal(entry)) {
    items.push({
      label: view.showOriginal ? 'Hide original' : 'Show original',
      icon: STREAM_ICONS.original,
      run: () => handlers.toggleOriginal(entry),
    });
  }
  items.push({ label: 'Delete', icon: STREAM_ICONS.trash, danger: true, run: () => handlers.remove(entry) });
  return items;
}

function actionButton(label: string, path: string, run: (button: HTMLButtonElement) => void): HTMLButtonElement {
  const button = el(
    'button',
    {
      class: 'icon-btn bubble-action',
      type: 'button',
      title: label,
      'aria-label': label,
      tabindex: -1,
      // Keep a text selection alive: pressing the button must not clear it, because
      // Teach a fix reads it on click.
      onmousedown: (event: MouseEvent) => event.preventDefault(),
      onclick: () => run(button),
    },
    icon(path, 16),
  );
  return button;
}

/** Builds the bubble. Once it is in the document, `measureBubbles` decides whether it collapses. */
export function createBubble(view: BubbleView, handlers: BubbleHandlers): HTMLElement {
  const { entry } = view;
  const text = el(
    'p',
    {
      class: `bubble-text${isRtlText(entry.text) ? ' is-rtl' : ''}`,
      dir: 'auto',
      lang: isLanguageCode(entry.language) ? entry.language : undefined,
    },
    ...bodyNodes(view),
  );

  const bubble = el('article', {
    class: `bubble lift${view.selected ? ' is-selected' : ''}${view.teaching ? ' is-teaching' : ''}${view.rise ? ' is-rising' : ''}`,
    role: 'listitem',
    tabindex: -1,
    dataset: { id: entry.id },
    'aria-selected': view.selected ? 'true' : undefined,
  });

  if (view.selected) bubble.append(el('span', { class: 'bubble-check', 'aria-hidden': 'true' }, icon(STREAM_ICONS.check, 12)));

  if (view.teaching) {
    bubble.append(
      el(
        'div',
        { class: 'bubble-teach' },
        el('span', { class: 'bubble-teach-hint' }, 'Select the words it got wrong'),
        el('button', { class: 'bubble-link', type: 'button', onclick: () => handlers.cancelTeach() }, 'Cancel'),
      ),
    );
  }

  bubble.append(text);

  const collapsible = !view.showOriginal && !view.expanded;
  const showAll = el(
    'button',
    { class: 'bubble-more', type: 'button', onclick: () => handlers.toggleExpand(entry) },
    'Show all',
    icon(STREAM_ICONS.chevronDown, 14),
  );
  showAll.hidden = true;
  if (view.expanded) {
    showAll.textContent = '';
    showAll.append('Show less', el('span', { class: 'bubble-more-up' }, icon(STREAM_ICONS.chevronDown, 14)));
    showAll.hidden = false;
  }
  if (collapsible) {
    text.classList.add('is-clamped');
    bubble.dataset.clampable = '1';
  }
  bubble.append(showAll);

  const meta = el('div', { class: 'bubble-meta' });
  metaParts(entry).forEach((part, index) => {
    if (index > 0) meta.append(el('i', { 'aria-hidden': 'true' }, '·'));
    meta.append(el('span', {}, part));
  });
  if (view.showOriginal && hasOriginal(entry)) {
    meta.append(
      el('i', { 'aria-hidden': 'true' }, '·'),
      el('button', { class: 'bubble-link', type: 'button', onclick: () => handlers.toggleOriginal(entry) }, 'Hide original'),
    );
  }

  const strip = el('div', { class: 'bubble-actions' });
  const more = actionButton('More', STREAM_ICONS.more, (button) => {
    openMenu(button, menuItems(entry, handlers, view, button, bubble, false), button);
  });
  strip.append(
    actionButton('Copy', STREAM_ICONS.copy, () => handlers.copy(entry)),
    actionButton('Add to note', STREAM_ICONS.notePlus, (button) => handlers.addToNote(entry, button)),
    actionButton('Teach a fix', STREAM_ICONS.fix, () => handlers.teach(entry, bubble)),
    more,
  );
  meta.append(strip);
  bubble.append(meta);

  bubble.addEventListener('mousedown', (event: MouseEvent) => {
    // Shift-click selects bubbles; without this the browser would also extend a text selection.
    if (event.shiftKey || event.ctrlKey) event.preventDefault();
  });
  bubble.addEventListener('click', (event: MouseEvent) => {
    if (!(event.shiftKey || event.ctrlKey || event.metaKey)) return;
    handlers.select(entry, event.shiftKey ? 'range' : 'toggle');
  });
  bubble.addEventListener('keydown', (event: KeyboardEvent) => {
    if (event.target !== bubble) return;
    if (event.key === 'Enter' || event.key === 'ContextMenu') {
      event.preventDefault();
      openMenu(more, menuItems(entry, handlers, view, more, bubble, true), bubble);
    } else if (event.key === ' ') {
      event.preventDefault();
      handlers.select(entry, 'toggle');
    }
  });

  return bubble;
}

/**
 * Decides which collapsed bubbles really overflow four lines and shows "Show all" on
 * those only. It needs layout, so it does nothing for bubbles that are not on screen yet;
 * the page calls it again once the stream is attached and when the width changes. It
 * writes, reads, then writes again, so it costs one layout however many bubbles it checks.
 */
export function measureBubbles(container: ParentNode): void {
  const all = [...container.querySelectorAll<HTMLElement>('.bubble[data-clampable="1"]')];
  const first = all[0];
  if (first === undefined || !first.isConnected || first.offsetWidth === 0) return;
  const texts = all.map((bubble) => bubble.querySelector<HTMLElement>('.bubble-text'));
  for (const text of texts) text?.classList.add('is-clamped');
  const overflowing = texts.map((text) => text !== null && text.scrollHeight > text.clientHeight + 1);
  all.forEach((bubble, index) => {
    const toggle = bubble.querySelector<HTMLElement>('.bubble-more');
    if (toggle) toggle.hidden = !overflowing[index];
    if (!overflowing[index]) texts[index]?.classList.remove('is-clamped');
  });
}
