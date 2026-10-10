/**
 * The language picker: one 300 by 400 surface panel (search, Auto-detect, Multiple
 * languages, native and English names, an arrow-key footer), used two ways.
 *
 *   * `languagePicker()` is the trigger the Settings row shows; its popup holds the panel.
 *   * `createLanguagePanel()` is also mounted by the floating picker window (see hud.ts),
 *     which the language hotkey and the tray open over whatever app the user is in.
 *
 * It replaced a native `<select>`, which was drawn by the OS and could not be searched
 * (Nova-3 speaks 60-odd languages).
 *
 * This file touches the DOM only inside functions and never the preload bridge, so the
 * option list and the filter stay testable on plain Node.
 */

import {
  DEEPGRAM_LANGUAGES,
  MULTILINGUAL_CODE_SWITCHING,
  findLanguage,
} from '../../core/transcription/languages.js';
import { languageLabel } from '../../core/hudModel.js';
import { el } from './dom.js';

/** A row entry: a mode or a language. */
interface PickerOption {
  /** The value stored in settings. */
  value: string;
  /** Primary label: the language's own name, or the mode's name. */
  label: string;
  /** English name, shown on the right when it differs from the label. */
  detail?: string;
  /** Extra words the search should match. */
  keywords?: string;
  /** A mode (Auto-detect, Multiple languages) rather than a language. */
  mode?: 'auto' | 'multi';
}

const SVG_NS = 'http://www.w3.org/2000/svg';

export const LANGUAGE_PATHS = {
  search: 'M11 19a8 8 0 1 0 0-16 8 8 0 0 0 0 16zM21 21l-4.3-4.3',
  check: 'M20 6 9 17l-5-5',
  languages: 'M5 8l6 6M4 14l6-6 2-3M2 5h12M7 2h1M22 22l-5-10-5 10M14 18h6',
  globe: 'M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18zM3 12h18M12 3c2.5 2.6 3.8 5.6 3.8 9S14.5 18.4 12 21c-2.5-2.6-3.8-5.6-3.8-9S9.5 5.6 12 3z',
};

function glyph(path: string, size: number): SVGSVGElement {
  const svg = document.createElementNS(SVG_NS, 'svg');
  svg.setAttribute('viewBox', '0 0 24 24');
  svg.setAttribute('width', String(size));
  svg.setAttribute('height', String(size));
  svg.setAttribute('fill', 'none');
  svg.setAttribute('stroke', 'currentColor');
  svg.setAttribute('stroke-width', '1.6');
  svg.setAttribute('stroke-linecap', 'round');
  svg.setAttribute('stroke-linejoin', 'round');
  svg.setAttribute('aria-hidden', 'true');
  const p = document.createElementNS(SVG_NS, 'path');
  p.setAttribute('d', path);
  svg.append(p);
  return svg;
}

/**
 * Every value the picker offers: the modes first, then the languages.
 *
 * The modes lead because they are the common case - most people dictate in one
 * language and never pick it - and because both do something other than name a
 * language, so burying them alphabetically would hide them.
 */
export function languagePickerOptions(): PickerOption[] {
  const modes: PickerOption[] = [
    {
      value: 'auto',
      mode: 'auto',
      label: 'Auto-detect',
      detail: 'Identifies the spoken language as you talk',
      keywords: 'automatic detection identify auto detect',
    },
    {
      value: MULTILINGUAL_CODE_SWITCHING.code,
      mode: 'multi',
      label: 'Multiple languages',
      detail: 'You switch language mid-sentence',
      keywords: 'multilingual code switching multi bilingual',
    },
  ];
  const languages: PickerOption[] = DEEPGRAM_LANGUAGES.map((language) => ({
    value: language.code,
    label: language.nativeName,
    // Suppressed when the native name is identical: "English / English" is noise
    // in a list the user is scanning.
    detail: language.nativeName === language.name ? undefined : language.name,
    keywords: `${language.name} ${language.code}`,
  }));
  return [...modes, ...languages];
}

/** Filter options by a free-text query, matching label, detail and keywords. */
export function filterLanguageOptions(
  options: readonly PickerOption[],
  query: string,
): PickerOption[] {
  const trimmed = query.trim().toLowerCase();
  if (trimmed.length === 0) return [...options];
  return options.filter((option) => {
    const haystack = [option.label, option.detail ?? '', option.keywords ?? ''].join(' ').toLowerCase();
    return haystack.includes(trimmed);
  });
}

export interface LanguagePanelOptions {
  /** Current value, checked in the list. */
  value: string;
  /** Called with the new value when the user picks one. */
  onChoose: (value: string) => void;
  /** Esc was pressed. */
  onClose: () => void;
  /** Accessible name for the panel. */
  label?: string;
}

export interface LanguagePanel {
  element: HTMLElement;
  /** Reset the search, check `value`, put the active row on it and focus the search field. */
  open: (value: string) => void;
}

/** The panel itself: search field, list and key-hint footer. */
export function createLanguagePanel({
  value,
  onChoose,
  onClose,
  label = 'Spoken language',
}: LanguagePanelOptions): LanguagePanel {
  const options = languagePickerOptions();
  let current = value;
  let query = '';
  let activeIndex = 0;
  let visible: PickerOption[] = [...options];
  let firstPaint = true;
  let rows: HTMLElement[] = [];

  const search = el('input', {
    class: 'lang-search',
    type: 'text',
    placeholder: 'Search languages',
    'aria-label': 'Search languages',
    role: 'combobox',
    'aria-expanded': 'true',
    'aria-controls': 'lang-list',
    autocomplete: 'off',
    spellcheck: false,
  }) as HTMLInputElement;
  const field = el('div', { class: 'lang-field' }, glyph(LANGUAGE_PATHS.search, 15), search);
  // The two modes stay pinned above the scrolling languages, so they are always in reach.
  const modeBox = el('div', { class: 'lang-modes' });
  const list = el('div', { class: 'lang-list' });
  const listbox = el('div', { class: 'lang-listbox', id: 'lang-list', role: 'listbox', 'aria-label': label }, modeBox, list);
  const empty = el('p', { class: 'lang-empty' }, 'No language matches that search.');
  empty.hidden = true;
  const footer = el(
    'div',
    { class: 'lang-foot', 'aria-hidden': 'true' },
    el('span', {}, el('kbd', { class: 'lang-kbd' }, '↑↓'), 'Move'),
    el('span', {}, el('kbd', { class: 'lang-kbd' }, 'Enter'), 'Select'),
    el('span', {}, el('kbd', { class: 'lang-kbd' }, 'Esc'), 'Close'),
  );
  const panel = el(
    'div',
    { class: 'lang-panel', role: 'dialog', 'aria-label': label },
    el('div', { class: 'lang-search-wrap' }, field),
    listbox,
    empty,
    footer,
  );

  function renderList(): void {
    visible = filterLanguageOptions(options, query);
    list.replaceChildren();
    modeBox.replaceChildren();
    rows = [];
    empty.hidden = visible.length > 0;
    activeIndex = Math.min(activeIndex, Math.max(0, visible.length - 1));
    visible.forEach((option, index) => {
      const isSelected = option.value === current;
      const row = el(
        'div',
        {
          class: `lang-row${index === activeIndex ? ' is-active' : ''}${isSelected ? ' is-selected' : ''}`,
          id: `lang-row-${index}`,
          role: 'option',
          'aria-selected': String(isSelected),
          dataset: { value: option.value },
          onclick: () => onChoose(option.value),
          onmousemove: () => {
            panel.dataset.input = 'pointer';
            if (activeIndex === index) return;
            setActive(index, false);
          },
        },
        option.mode ? glyph(option.mode === 'auto' ? LANGUAGE_PATHS.languages : LANGUAGE_PATHS.globe, 16) : null,
        el('span', { class: 'lang-name', ...(option.mode ? {} : { lang: findLanguage(option.value)?.code.split('-')[0] ?? '' }), dir: 'auto' }, option.label),
        !option.mode && option.detail ? el('span', { class: 'lang-english' }, option.detail) : null,
        isSelected ? el('span', { class: 'lang-check' }, glyph(LANGUAGE_PATHS.check, 16)) : null,
      );
      rows.push(row);
      (option.mode ? modeBox : list).append(row);
    });
    // The rule between the modes and the languages, only when both are showing.
    modeBox.classList.toggle('has-rule', modeBox.childElementCount > 0 && list.childElementCount > 0);
    search.setAttribute('aria-activedescendant', visible.length > 0 ? `lang-row-${activeIndex}` : '');
    scrollActiveIntoView(firstPaint ? 'center' : 'nearest');
    firstPaint = false;
  }

  function scrollActiveIntoView(block: ScrollLogicalPosition): void {
    rows[activeIndex]?.scrollIntoView({ block });
  }

  /** Move the active row without repainting the whole list, so a hover never flickers. */
  function setActive(index: number, scroll: boolean): void {
    rows[activeIndex]?.classList.remove('is-active');
    activeIndex = index;
    rows[activeIndex]?.classList.add('is-active');
    search.setAttribute('aria-activedescendant', `lang-row-${activeIndex}`);
    if (scroll) scrollActiveIntoView('nearest');
  }

  search.addEventListener('input', () => {
    query = search.value;
    activeIndex = 0;
    renderList();
  });

  panel.addEventListener('keydown', (event: KeyboardEvent) => {
    if (event.key === 'Escape') {
      event.preventDefault();
      // Only the picker closes: it never propagates and dismisses a surrounding dialog too.
      event.stopPropagation();
      onClose();
      return;
    }
    if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
      event.preventDefault();
      if (visible.length === 0) return;
      panel.dataset.input = 'keyboard';
      const delta = event.key === 'ArrowDown' ? 1 : -1;
      setActive(Math.min(Math.max(0, activeIndex + delta), visible.length - 1), true);
      return;
    }
    if (event.key === 'Enter') {
      event.preventDefault();
      const option = visible[activeIndex];
      if (option) onChoose(option.value);
    }
  });

  renderList();

  return {
    element: panel,
    open(next: string): void {
      current = next;
      query = '';
      search.value = '';
      panel.dataset.input = 'keyboard';
      visible = [...options];
      activeIndex = Math.max(0, options.findIndex((option) => option.value === next));
      firstPaint = true;
      renderList();
      search.focus();
    },
  };
}

export interface LanguagePickerOptions {
  /** Current value. */
  value: string;
  /** Called with the new value when the user picks one. */
  onChange: (value: string) => void;
  /** Accessible label for the trigger. */
  label?: string;
}

export interface LanguagePickerHandle {
  /** The trigger element to place in the page. */
  element: HTMLElement;
  /** Open the popup as if the trigger had been clicked, and focus its search field. */
  open: () => void;
}

/**
 * The trigger for the Settings row. Returns the trigger element, which owns an
 * absolutely positioned popup holding the panel, plus a handle for opening it
 * programmatically.
 */
export function languagePicker({
  value,
  onChange,
  label = 'Spoken language',
}: LanguagePickerOptions): LanguagePickerHandle {
  let current = value;
  let isOpen = false;

  const valueLabel = el('span', { class: 'lang-trigger-label' }, languageLabel(current));
  const trigger = el(
    'button',
    {
      class: 'lang-trigger',
      type: 'button',
      'aria-haspopup': 'dialog',
      'aria-expanded': 'false',
      'aria-label': label,
    },
    valueLabel,
    el('span', { class: 'lang-trigger-chevron', 'aria-hidden': 'true' }, '▾'),
  );

  const panel = createLanguagePanel({
    value,
    label,
    onChoose: (next) => choose(next),
    onClose: () => close(),
  });
  const popup = el('div', { class: 'lang-popup' }, panel.element);
  const wrapper = el('div', { class: 'lang-picker' }, trigger, popup);

  /** Clicking outside dismisses, matching a native select. */
  function onDocumentMouseDown(event: MouseEvent): void {
    if (!wrapper.contains(event.target as Node)) close();
  }

  function open(): void {
    if (isOpen) return;
    isOpen = true;
    wrapper.classList.add('is-open');
    trigger.setAttribute('aria-expanded', 'true');
    document.addEventListener('mousedown', onDocumentMouseDown, true);
    panel.open(current);
  }

  function close(): void {
    if (!isOpen) return;
    isOpen = false;
    wrapper.classList.remove('is-open');
    trigger.setAttribute('aria-expanded', 'false');
    document.removeEventListener('mousedown', onDocumentMouseDown, true);
    trigger.focus();
  }

  function choose(next: string): void {
    current = next;
    valueLabel.textContent = languageLabel(current);
    close();
    onChange(next);
  }

  trigger.addEventListener('click', () => (isOpen ? close() : open()));
  trigger.addEventListener('keydown', (event: KeyboardEvent) => {
    if (!isOpen && (event.key === 'ArrowDown' || event.key === 'Enter' || event.key === ' ')) {
      event.preventDefault();
      open();
    }
  });

  return { element: wrapper, open };
}
