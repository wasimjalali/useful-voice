import { describe, expect, it } from 'vitest';
import { EDITABLE_FOCUS_SCRIPT } from '../src/core/delivery/editableFocus.js';

/**
 * The page-side check that decides whether a dictation started in our own window may be
 * pasted there. Failure cases: pasting while a button or the page body has focus (the
 * keystroke lands nowhere), into a password box, into a read-only or disabled field.
 */

interface FakeElement {
  tagName?: string;
  type?: string;
  disabled?: boolean;
  readOnly?: boolean;
  isContentEditable?: boolean;
  shadowRoot?: { activeElement: FakeElement | null } | null;
}

function check(active: FakeElement | null): boolean {
  const body: FakeElement = { tagName: 'BODY' };
  const document = { activeElement: active, body };
  return new Function('document', `return ${EDITABLE_FOCUS_SCRIPT};`)(document) as boolean;
}

describe('EDITABLE_FOCUS_SCRIPT', () => {
  it('accepts text inputs of every textual type and textareas', () => {
    for (const type of ['text', 'search', 'email', 'url', 'tel', 'number', undefined]) {
      expect(check({ tagName: 'INPUT', type }), String(type)).toBe(true);
    }
    expect(check({ tagName: 'TEXTAREA' })).toBe(true);
  });

  it('accepts a contenteditable element', () => {
    expect(check({ tagName: 'DIV', isContentEditable: true })).toBe(true);
  });

  it('refuses a password box', () => {
    expect(check({ tagName: 'INPUT', type: 'password' })).toBe(false);
  });

  it('refuses inputs that take no text', () => {
    for (const type of ['checkbox', 'radio', 'button', 'submit', 'file', 'range', 'color']) {
      expect(check({ tagName: 'INPUT', type }), type).toBe(false);
    }
  });

  it('refuses a disabled or read-only field', () => {
    expect(check({ tagName: 'INPUT', type: 'text', disabled: true })).toBe(false);
    expect(check({ tagName: 'INPUT', type: 'text', readOnly: true })).toBe(false);
    expect(check({ tagName: 'TEXTAREA', readOnly: true })).toBe(false);
  });

  it('refuses a button, a link, the body, and nothing focused at all', () => {
    expect(check({ tagName: 'BUTTON' })).toBe(false);
    expect(check({ tagName: 'A' })).toBe(false);
    expect(check({ tagName: 'BODY' })).toBe(false);
    expect(check(null)).toBe(false);
  });

  it('looks inside an open shadow root', () => {
    const inner: FakeElement = { tagName: 'INPUT', type: 'text' };
    expect(check({ tagName: 'MY-FIELD', shadowRoot: { activeElement: inner } })).toBe(true);
    const button: FakeElement = { tagName: 'BUTTON' };
    expect(check({ tagName: 'MY-FIELD', shadowRoot: { activeElement: button } })).toBe(false);
  });
});
