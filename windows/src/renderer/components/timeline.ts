/**
 * The Stream's timeline: dictations grouped by day, newest at the bottom, with a sticky
 * opaque day band that opens the date jump.
 *
 * It renders a window, not the whole history. The newest ~40 dictations are built first
 * and older ones are prepended as the reader scrolls toward the top, so a thousand
 * dictations cost the same as forty. A search or filter change rebuilds the window; a
 * data change rebuilds it too but keeps the reader's place.
 */

import type { HistoryEntryDTO } from '../../preload/types.js';
import { el, icon } from './dom.js';
import { STREAM_ICONS } from './dockIcons.js';
import { measureBubbles } from './bubble.js';
import { dayKey, dayLabel } from './bubbleFormat.js';

const INITIAL = 40;
const PAGE = 30;
/** Scrolling closer than this to the top loads an older page. */
const LOAD_THRESHOLD = 500;
const NEAR_BOTTOM = 96;

export interface DayInfo {
  key: string;
  label: string;
  count: number;
}

export interface TimelineHooks {
  renderBubble: (entry: HistoryEntryDTO, rise: boolean) => HTMLElement;
  /** The day band was pressed. */
  openDayJump: (anchor: HTMLElement) => void;
}

export interface SetEntriesOptions {
  /** A search or filter changed: start again at the newest. */
  reset?: boolean;
  /** Ids that just arrived, which rise into place. */
  fresh?: ReadonlySet<string>;
}

export interface Timeline {
  element: HTMLElement;
  setEntries: (entries: readonly HistoryEntryDTO[], options?: SetEntriesOptions) => void;
  refreshBubble: (entry: HistoryEntryDTO) => void;
  days: () => DayInfo[];
  /** The day shown in the band right now. */
  currentDay: () => string | null;
  jumpToDay: (key: string) => void;
  scrollToBottom: () => void;
  isNearBottom: () => boolean;
  /** Re-checks which bubbles overflow four lines and which day band is stuck. Needs the timeline in the document. */
  measure: () => void;
  focusBubble: (id: string) => void;
}

export function createTimeline(hooks: TimelineHooks): Timeline {
  const col = el('div', { class: 'tl-col' });
  const scroll = el('div', { class: 'tl-scroll', role: 'list', 'aria-label': 'Dictations' }, col);

  let flat: readonly HistoryEntryDTO[] = [];
  /** Index in `flat` of the first rendered dictation. */
  let start = 0;
  let frame = 0;

  function dayLabelButton(key: string, date: Date): HTMLElement {
    const label = el(
      'button',
      {
        class: 'tl-day-label',
        type: 'button',
        'aria-haspopup': 'dialog',
        title: 'Jump to a day',
        onclick: (event: MouseEvent) => hooks.openDayJump(event.currentTarget as HTMLElement),
      },
      el('span', {}, dayLabel(date)),
      icon(STREAM_ICONS.chevronDown, 14),
    );
    label.dataset.day = key;
    return label;
  }

  function buildSections(slice: readonly HistoryEntryDTO[], fresh: ReadonlySet<string>): HTMLElement[] {
    const sections: HTMLElement[] = [];
    let currentKey = '';
    let section: HTMLElement | null = null;
    for (const entry of slice) {
      const date = new Date(entry.createdAt);
      const key = dayKey(date);
      if (key !== currentKey || section === null) {
        currentKey = key;
        section = el('section', { class: 'tl-day', dataset: { day: key } }, dayLabelButton(key, date));
        sections.push(section);
      }
      section.append(hooks.renderBubble(entry, fresh.has(entry.id)));
    }
    return sections;
  }

  function bubbles(): HTMLElement[] {
    return [...col.querySelectorAll<HTMLElement>('.bubble')];
  }

  function applyRoving(preferId?: string): void {
    const all = bubbles();
    if (all.length === 0) return;
    const keep = preferId !== undefined
      ? all.find((bubble) => bubble.dataset.id === preferId)
      : all.find((bubble) => bubble.tabIndex === 0 && bubble.isConnected);
    const target = keep ?? all[all.length - 1];
    for (const bubble of all) bubble.tabIndex = bubble === target ? 0 : -1;
  }

  function isNearBottom(): boolean {
    return scroll.scrollHeight - scroll.scrollTop - scroll.clientHeight < NEAR_BOTTOM;
  }

  function scrollToBottom(): void {
    scroll.scrollTop = scroll.scrollHeight;
  }

  /** The first bubble the reader can see, and how far below the top edge it sits. */
  function captureAnchor(): { id: string; offset: number } | null {
    const top = scroll.getBoundingClientRect().top;
    for (const bubble of bubbles()) {
      const rect = bubble.getBoundingClientRect();
      if (rect.bottom > top + 1) return { id: bubble.dataset.id ?? '', offset: rect.top - top };
    }
    return null;
  }

  function restoreAnchor(anchor: { id: string; offset: number } | null): boolean {
    if (anchor === null) return false;
    const target = bubbles().find((bubble) => bubble.dataset.id === anchor.id);
    if (!target) return false;
    const top = scroll.getBoundingClientRect().top;
    scroll.scrollTop += target.getBoundingClientRect().top - top - anchor.offset;
    return true;
  }

  function updateStuck(): void {
    const top = scroll.getBoundingClientRect().top;
    for (const label of col.querySelectorAll<HTMLElement>('.tl-day-label')) {
      label.classList.toggle('is-stuck', Math.abs(label.getBoundingClientRect().top - top) < 1.5);
    }
  }

  function currentDay(): string | null {
    const top = scroll.getBoundingClientRect().top;
    let found: string | null = null;
    for (const label of col.querySelectorAll<HTMLElement>('.tl-day-label')) {
      if (label.getBoundingClientRect().top <= top + 1.5) found = label.dataset.day ?? null;
    }
    return found ?? col.querySelector<HTMLElement>('.tl-day-label')?.dataset.day ?? null;
  }

  function render(fresh: ReadonlySet<string>): void {
    col.replaceChildren(...buildSections(flat.slice(start), fresh));
    measureBubbles(col);
    applyRoving();
  }

  function loadOlder(): void {
    if (start === 0) return;
    const newStart = Math.max(0, start - PAGE);
    const sections = buildSections(flat.slice(newStart, start), new Set());
    const firstExisting = col.querySelector<HTMLElement>('.tl-day');
    const lastNew = sections[sections.length - 1];
    if (lastNew && firstExisting && lastNew.dataset.day === firstExisting.dataset.day) {
      // The page ends mid-day: its bubbles join the day that is already on screen.
      const moved = [...lastNew.querySelectorAll<HTMLElement>('.bubble')];
      const label = firstExisting.querySelector('.tl-day-label');
      if (label) label.after(...moved);
      sections.pop();
    }
    const before = scroll.scrollHeight;
    const keepTop = scroll.scrollTop;
    col.prepend(...sections);
    measureBubbles(col);
    scroll.scrollTop = keepTop + (scroll.scrollHeight - before);
    start = newStart;
  }

  scroll.addEventListener('scroll', () => {
    if (frame !== 0) return;
    frame = requestAnimationFrame(() => {
      frame = 0;
      updateStuck();
      if (scroll.scrollTop < LOAD_THRESHOLD && start > 0) {
        loadOlder();
        updateStuck();
      }
    });
  }, { passive: true });

  // A new width re-wraps the text, so which bubbles overflow can change.
  let lastWidth = 0;
  new ResizeObserver(() => {
    if (scroll.clientWidth === lastWidth) return;
    lastWidth = scroll.clientWidth;
    requestAnimationFrame(() => measureBubbles(col));
  }).observe(scroll);

  scroll.addEventListener('focusin', (event) => {
    const bubble = (event.target as HTMLElement).closest<HTMLElement>('.bubble');
    if (bubble) applyRoving(bubble.dataset.id);
  });

  scroll.addEventListener('keydown', (event: KeyboardEvent) => {
    if (event.target instanceof HTMLElement && !event.target.classList.contains('bubble')) return;
    const all = bubbles();
    const at = all.indexOf(event.target as HTMLElement);
    if (at < 0) return;
    let next: HTMLElement | undefined;
    if (event.key === 'ArrowDown') next = all[at + 1];
    else if (event.key === 'ArrowUp') {
      if (at === 0 && start > 0) {
        loadOlder();
        next = bubbles()[Math.max(0, bubbles().length - all.length - 1)];
      } else next = all[at - 1];
    } else if (event.key === 'Home') {
      next = all[0];
    } else if (event.key === 'End') {
      next = all[all.length - 1];
    } else return;
    event.preventDefault();
    next?.focus();
    next?.scrollIntoView({ block: 'nearest' });
  });

  function setEntries(entries: readonly HistoryEntryDTO[], options: SetEntriesOptions = {}): void {
    const fresh = options.fresh ?? new Set<string>();
    const wasEmpty = flat.length === 0;
    const reset = options.reset === true || wasEmpty;
    const wasNearBottom = isNearBottom();
    const anchor = reset ? null : captureAnchor();
    const firstRendered = flat[start]?.id;
    const rendered = flat.length - start;
    const focusedId = (document.activeElement as HTMLElement | null)?.closest?.('.bubble') instanceof HTMLElement
      && scroll.contains(document.activeElement)
      ? (document.activeElement as HTMLElement).closest<HTMLElement>('.bubble')?.dataset.id
      : undefined;

    flat = entries;
    if (reset) {
      start = Math.max(0, flat.length - INITIAL);
    } else {
      const at = firstRendered === undefined ? -1 : flat.findIndex((entry) => entry.id === firstRendered);
      start = at >= 0 ? at : Math.max(0, flat.length - Math.max(INITIAL, rendered));
    }
    render(fresh);

    if (reset) {
      scrollToBottom();
    } else {
      if (!restoreAnchor(anchor)) scroll.scrollTop = Math.min(scroll.scrollTop, scroll.scrollHeight);
      // A new dictation slides into view instead of the whole timeline jumping up.
      if (wasNearBottom && fresh.size > 0) {
        const calm = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
        scroll.scrollTo({ top: scroll.scrollHeight, behavior: calm ? 'auto' : 'smooth' });
      }
    }
    updateStuck();
    if (focusedId !== undefined) focusBubble(focusedId);
  }

  function refreshBubble(entry: HistoryEntryDTO): void {
    const old = col.querySelector<HTMLElement>(`.bubble[data-id="${CSS.escape(entry.id)}"]`);
    if (!old) return;
    const hadFocus = old.contains(document.activeElement);
    const next = hooks.renderBubble(entry, false);
    next.tabIndex = old.tabIndex;
    old.replaceWith(next);
    measureBubbles(next.parentElement ?? col);
    if (hadFocus) next.focus();
  }

  function focusBubble(id: string): void {
    const target = bubbles().find((bubble) => bubble.dataset.id === id);
    if (!target) return;
    applyRoving(id);
    target.focus({ preventScroll: true });
  }

  function days(): DayInfo[] {
    const out: DayInfo[] = [];
    for (let i = flat.length - 1; i >= 0; i--) {
      const date = new Date((flat[i] as HistoryEntryDTO).createdAt);
      const key = dayKey(date);
      const last = out[out.length - 1];
      if (last && last.key === key) last.count++;
      else out.push({ key, label: dayLabel(date), count: 1 });
    }
    return out;
  }

  function jumpToDay(key: string): void {
    const index = flat.findIndex((entry) => dayKey(new Date(entry.createdAt)) === key);
    if (index < 0) return;
    if (index < start) {
      start = index;
      render(new Set());
    }
    const section = col.querySelector<HTMLElement>(`.tl-day[data-day="${key}"]`);
    if (section) scroll.scrollTop = section.offsetTop;
    updateStuck();
  }

  return {
    element: scroll,
    setEntries,
    refreshBubble,
    days,
    currentDay,
    jumpToDay,
    scrollToBottom,
    isNearBottom,
    measure: () => {
      measureBubbles(col);
      updateStuck();
    },
    focusBubble,
  };
}
