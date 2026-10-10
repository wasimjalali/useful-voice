/**
 * The teach-a-fix popover. It opens 6 px under the selected words, shows what was heard
 * (read-only) and a Write as field, and saves a vocabulary fix.
 */

import { el } from './dom.js';
import { openFloating, type FloatingHandle } from './bubblePopover.js';

export interface TeachFixOptions {
  /** The selection's rectangle. */
  rect: DOMRect;
  heard: string;
  /** Saves the fix. A rejection is shown in the popover and keeps it open. */
  onSave: (replacement: string) => Promise<void>;
  onClose?: () => void;
  returnFocus?: HTMLElement | null;
}

export function openTeachFix(options: TeachFixOptions): FloatingHandle {
  const heardField = el('input', {
    class: 'field-input tf-heard',
    type: 'text',
    readOnly: true,
    value: options.heard,
    'aria-label': 'Heard',
    id: 'tf-heard',
  });
  const writeField = el('input', {
    class: 'field-input',
    type: 'text',
    id: 'tf-write',
    autocomplete: 'off',
    spellcheck: false,
    dir: 'auto',
  });
  const error = el('p', { class: 'tf-error', role: 'alert' });
  error.hidden = true;
  const save = el('button', { class: 'btn btn-primary', type: 'submit', disabled: true }, 'Save fix');

  const form = el(
    'form',
    { class: 'tf', autocomplete: 'off' },
    el('h3', { class: 'tf-title' }, 'Teach a fix'),
    el('div', { class: 'tf-field' }, el('label', { for: 'tf-heard' }, 'Heard'), heardField),
    el('div', { class: 'tf-field' }, el('label', { for: 'tf-write' }, 'Write as'), writeField),
    error,
    el('div', { class: 'tf-actions' }, save),
  );

  const handle = openFloating({
    content: form,
    anchor: options.rect,
    placement: 'below',
    gap: 6,
    className: 'tf-surface',
    label: 'Teach a fix',
    returnFocus: options.returnFocus ?? null,
    onClose: options.onClose,
  });

  const valid = (): boolean => {
    const value = writeField.value.trim();
    return value !== '' && value !== options.heard;
  };
  writeField.addEventListener('input', () => {
    save.disabled = !valid();
    error.hidden = true;
  });
  form.addEventListener('submit', (event) => {
    event.preventDefault();
    if (!valid()) return;
    save.disabled = true;
    options.onSave(writeField.value.trim()).then(
      () => handle.close(),
      (failure: unknown) => {
        error.textContent = failure instanceof Error ? failure.message : String(failure);
        error.hidden = false;
        save.disabled = false;
      },
    );
  });

  writeField.focus();
  return handle;
}
