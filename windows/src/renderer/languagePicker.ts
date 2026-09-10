/**
 * A searchable, height-bounded language picker.
 *
 * Replaces the `<select>` the language row used to use. Two problems with a native
 * select here, and only one of them is cosmetic:
 *
 * 1. It is drawn by the OS, so it was the one control on the page that did not
 *    follow the design system — every other field is a bordered white box with a
 *    9px radius.
 * 2. It cannot be searched. Nova-3 speaks 60-odd languages and the list is only
 *    going to grow, so finding one by scrolling is the slow path.
 *
 * Layout rules, matching the macOS picker:
 *   * a fixed maximum height with internal scrolling, so a long list never stretches
 *     the settings page or pushes the rows below it off-screen;
 *   * left-aligned, full-width rows;
 *   * only existing tokens — no new hues.
 */

import {
  DEEPGRAM_LANGUAGES,
  MULTILINGUAL_CODE_SWITCHING,
  findLanguage,
} from '../core/transcription/languages.js';

/** A row entry: a mode or a language. */
interface PickerOption {
  /** The value stored in settings. */
  value: string;
  /** Primary label. */
  label: string;
  /** Secondary label, shown only when it adds information. */
  detail?: string;
  /** Right-aligned monospace hint, e.g. the code. */
  hint?: string;
  /** Extra words the search should match. */
  keywords?: string;
}

function el<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  props: Record<string, unknown> = {},
  ...children: Array<Node | string | null | undefined | false>
): HTMLElementTagNameMap[K] {
  const node = document.createElement(tag);
  const { class: className, dataset, ...rest } = props;
  if (typeof className === 'string') node.className = className;
  if (dataset && typeof dataset === 'object') {
    for (const [key, value] of Object.entries(dataset as Record<string, unknown>)) {
      node.dataset[key] = String(value);
    }
  }
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

/**
 * Every value the picker offers: the modes first, then the languages.
 *
 * The modes lead because they are the common case — most people dictate in one
 * language and never pick it — and because both do something other than name a
 * language, so burying them alphabetically would hide them.
 */
export function languagePickerOptions(): PickerOption[] {
  const modes: PickerOption[] = [
    {
      value: 'auto',
      label: 'Detect automatically',
      detail: 'Identifies the spoken language as you talk',
      keywords: 'automatic detection identify auto',
    },
    {
      value: MULTILINGUAL_CODE_SWITCHING.code,
      label: MULTILINGUAL_CODE_SWITCHING.name,
      detail: 'You switch language mid-sentence',
      keywords: 'multilingual code switching multi bilingual',
    },
  ];
  const languages: PickerOption[] = DEEPGRAM_LANGUAGES.map((language) => ({
    value: language.code,
    label: language.name,
    // Suppressed when the native name is identical: "English / English" is noise
    // in a list the user is scanning.
    detail: language.nativeName === language.name ? undefined : language.nativeName,
    hint: language.code,
    keywords: language.nativeName,
  }));
  return [...modes, ...languages];
}

/** Filter options by a free-text query, matching label, detail, hint and keywords. */
export function filterLanguageOptions(
  options: readonly PickerOption[],
  query: string,
): PickerOption[] {
  const trimmed = query.trim().toLowerCase();
  if (trimmed.length === 0) return [...options];
  return options.filter((option) => {
    const haystack = [option.label, option.detail ?? '', option.hint ?? '', option.keywords ?? '']
      .join(' ')
      .toLowerCase();
    return haystack.includes(trimmed);
  });
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
  /**
   * Open the popup as if the trigger had been clicked, and focus its search field.
   *
   * Exposed because the language hotkey is global: it has to open the picker from
   * outside the widget, and synthesising a click on the trigger would be a more
   * fragile way to say the same thing.
   */
  open: () => void;
}

/**
 * Render the picker. Returns the trigger element, which owns an absolutely
 * positioned popup, plus a handle for opening it programmatically.
 */
export function languagePicker({
  value,
  onChange,
  label = 'Spoken language',
}: LanguagePickerOptions): LanguagePickerHandle {
  const options = languagePickerOptions();
  let current = value;
  let isOpen = false;
  let query = '';
  let activeIndex = 0;
  let visible: PickerOption[] = [...options];

  const currentLabel = (): string =>
    options.find((option) => option.value === current)?.label
    ?? findLanguage(current)?.name
    ?? 'Detect automatically';

  const valueLabel = el('span', { class: 'lang-trigger-label' }, currentLabel());
  const trigger = el(
    'button',
    {
      class: 'lang-trigger',
      type: 'button',
      'aria-haspopup': 'listbox',
      'aria-expanded': 'false',
      'aria-label': label,
    },
    valueLabel,
    el('span', { class: 'lang-trigger-chevron', 'aria-hidden': 'true' }, '\u25BE'),
  );

  const search = el('input', {
    class: 'lang-search',
    type: 'search',
    placeholder: 'Search languages',
    'aria-label': 'Search languages',
    autocomplete: 'off',
  }) as HTMLInputElement;

  const list = el('div', { class: 'lang-list', role: 'listbox', 'aria-label': label });
  const empty = el('p', { class: 'lang-empty' }, 'No language matches that search.');
  empty.hidden = true;
  const popup = el('div', { class: 'lang-popup', role: 'dialog', 'aria-label': label }, search, list, empty);
  const wrapper = el('div', { class: 'lang-picker' }, trigger, popup);

  function renderList(): void {
    visible = filterLanguageOptions(options, query);
    list.replaceChildren();
    empty.hidden = visible.length > 0;
    activeIndex = Math.min(activeIndex, Math.max(0, visible.length - 1));
    for (const [index, option] of visible.entries()) {
      const isSelected = option.value === current;
      list.append(
        el(
          'button',
          {
            class: `lang-row${index === activeIndex ? ' is-active' : ''}${isSelected ? ' is-selected' : ''}`,
            type: 'button',
            role: 'option',
            'aria-selected': String(isSelected),
            dataset: { value: option.value },
            onclick: () => choose(option.value),
            onmousemove: () => {
              if (activeIndex === index) return;
              activeIndex = index;
              renderList();
            },
          },
          el('span', { class: 'lang-check', 'aria-hidden': 'true' }, isSelected ? '\u2713' : ''),
          el(
            'span',
            { class: 'lang-row-text' },
            el('span', { class: 'lang-row-label' }, option.label),
            option.detail ? el('span', { class: 'lang-row-detail' }, option.detail) : null,
          ),
          option.hint ? el('span', { class: 'lang-row-hint' }, option.hint) : null,
        ),
      );
    }
    // Keep the active row in view when arrowing past the visible window.
    const active = list.children[activeIndex] as HTMLElement | undefined;
    active?.scrollIntoView({ block: 'nearest' });
  }

  /** Clicking outside dismisses, matching a native select. */
  function onDocumentMouseDown(event: MouseEvent): void {
    if (!wrapper.contains(event.target as Node)) close();
  }

  function open(): void {
    if (isOpen) return;
    isOpen = true;
    query = '';
    search.value = '';
    activeIndex = Math.max(0, options.findIndex((option) => option.value === current));
    renderList();
    wrapper.classList.add('is-open');
    trigger.setAttribute('aria-expanded', 'true');
    document.addEventListener('mousedown', onDocumentMouseDown, true);
    search.focus();
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
    valueLabel.textContent = currentLabel();
    close();
    onChange(next);
  }

  trigger.addEventListener('click', () => (isOpen ? close() : open()));

  search.addEventListener('input', () => {
    query = search.value;
    activeIndex = 0;
    renderList();
  });

  wrapper.addEventListener('keydown', (event: KeyboardEvent) => {
    if (event.key === 'Escape') {
      if (!isOpen) return;
      event.preventDefault();
      // Escape closes only the popup, so it never propagates and dismisses a
      // surrounding dialog too.
      event.stopPropagation();
      close();
      return;
    }
    if (!isOpen) {
      if (event.key === 'ArrowDown' || event.key === 'Enter' || event.key === ' ') {
        event.preventDefault();
        open();
      }
      return;
    }
    if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
      event.preventDefault();
      const delta = event.key === 'ArrowDown' ? 1 : -1;
      activeIndex = Math.min(Math.max(0, activeIndex + delta), Math.max(0, visible.length - 1));
      renderList();
      return;
    }
    if (event.key === 'Enter') {
      event.preventDefault();
      const option = visible[activeIndex];
      if (option) choose(option.value);
    }
  });

  return { element: wrapper, open };
}
