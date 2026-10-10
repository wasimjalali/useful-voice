/**
 * A compact, on-brand dropdown for short, fixed option lists.
 *
 * Replaces the native `<select>` the settings rows used to use. A select is drawn
 * by the OS, so it was the one control on the page that ignored the design system —
 * every other field is a bordered white box with a 9px radius. Unlike the language
 * picker this list is short, so it needs no search field.
 *
 * Keyboard model: focus stays on the trigger, and Up/Down move a virtual highlight
 * (`aria-activedescendant`) rather than DOM focus. Tab therefore leaves the control
 * instead of walking through every option, and Enter always picks the highlighted
 * row — the two can never disagree.
 */

export interface DropdownOption {
  value: string;
  label: string;
}

export interface DropdownOptions {
  value: string;
  options: ReadonlyArray<DropdownOption>;
  onChange: (value: string) => void;
  /** Accessible label for the trigger. */
  label: string;
}

export interface DropdownHandle {
  /** The trigger element to place in the page. */
  element: HTMLElement;
}

/**
 * The one open dropdown, if any. Opening another closes the first, so two popups
 * can never be on screen at once.
 */
let openDropdown: { close: () => void } | null = null;
let nextInstanceId = 0;

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

export function dropdown({ value, options, onChange, label }: DropdownOptions): DropdownHandle {
  const instanceId = `uv-select-${nextInstanceId++}`;
  let current = value;
  let isOpen = false;
  let activeIndex = Math.max(0, options.findIndex((option) => option.value === current));

  const optionId = (index: number): string => `${instanceId}-option-${index}`;

  const currentLabel = (): string =>
    options.find((option) => option.value === current)?.label
    ?? options[0]?.label
    ?? '';

  const valueLabel = el('span', { class: 'select-trigger-label' }, currentLabel());
  const trigger = el(
    'button',
    {
      class: 'select-trigger',
      type: 'button',
      'aria-haspopup': 'listbox',
      'aria-expanded': 'false',
      'aria-controls': `${instanceId}-list`,
      'aria-label': label,
    },
    valueLabel,
    el('span', { class: 'select-trigger-chevron', 'aria-hidden': 'true' }, '\u25BE'),
  );

  const list = el('div', {
    class: 'select-list',
    id: `${instanceId}-list`,
    role: 'listbox',
    'aria-label': label,
  });
  const popup = el('div', { class: 'select-popup' }, list);
  const wrapper = el('div', { class: 'select-picker' }, trigger, popup);

  function renderList(): void {
    list.replaceChildren();
    activeIndex = Math.min(activeIndex, Math.max(0, options.length - 1));
    for (const [index, option] of options.entries()) {
      const isSelected = option.value === current;
      list.append(
        el(
          'button',
          {
            id: optionId(index),
            class: `lang-row${index === activeIndex ? ' is-active' : ''}${isSelected ? ' is-selected' : ''}`,
            type: 'button',
            role: 'option',
            tabindex: '-1',
            'aria-selected': String(isSelected),
            dataset: { value: option.value },
            // Keep DOM focus on the trigger: the highlight is virtual. This also
            // stops the popover from stealing focus from the settings page.
            onmousedown: (event: Event) => event.preventDefault(),
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
          ),
        ),
      );
    }
    list.setAttribute('aria-activedescendant', optionId(activeIndex));
    // Keep the active row in view when arrowing past the visible window.
    const active = list.children[activeIndex] as HTMLElement | undefined;
    active?.scrollIntoView({ block: 'nearest' });
  }

  /** Clicking outside dismisses, matching a native select. */
  function onDocumentMouseDown(event: MouseEvent): void {
    if (!wrapper.isConnected) {
      detachListeners();
      return;
    }
    if (!wrapper.contains(event.target as Node)) close();
  }

  /** Tabbing or clicking focus away closes the popup, as a select would. */
  function onFocusOut(event: FocusEvent): void {
    if (!wrapper.isConnected) {
      detachListeners();
      return;
    }
    const next = event.relatedTarget as Node | null;
    if (next && wrapper.contains(next)) return;
    close();
  }

  function attachListeners(): void {
    document.addEventListener('mousedown', onDocumentMouseDown, true);
    wrapper.addEventListener('focusout', onFocusOut);
  }

  function detachListeners(): void {
    document.removeEventListener('mousedown', onDocumentMouseDown, true);
    wrapper.removeEventListener('focusout', onFocusOut);
  }

  function open(): void {
    if (isOpen) return;
    if (openDropdown && openDropdown.close !== close) openDropdown.close();
    openDropdown = { close };
    isOpen = true;
    activeIndex = Math.max(0, options.findIndex((option) => option.value === current));
    renderList();
    wrapper.classList.add('is-open');
    trigger.setAttribute('aria-expanded', 'true');
    attachListeners();
  }

  function close(): void {
    if (!isOpen) return;
    isOpen = false;
    wrapper.classList.remove('is-open');
    trigger.setAttribute('aria-expanded', 'false');
    detachListeners();
    if (openDropdown?.close === close) openDropdown = null;
    // Deliberately no `trigger.focus()`: focus never left the trigger while the
    // popup was open, and refocusing here would fight Tab and outside clicks.
  }

  function choose(next: string): void {
    current = next;
    valueLabel.textContent = currentLabel();
    close();
    onChange(next);
  }

  trigger.addEventListener('click', () => (isOpen ? close() : open()));

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
      activeIndex = Math.min(Math.max(0, activeIndex + delta), Math.max(0, options.length - 1));
      renderList();
      return;
    }
    if (event.key === 'Enter') {
      event.preventDefault();
      const option = options[activeIndex];
      if (option) choose(option.value);
    }
  });

  return { element: wrapper };
}
