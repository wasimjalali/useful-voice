import { describe, expect, it } from 'vitest';
import { isEditableField } from '../src/core/apps/ownField.js';

const field = (over: Record<string, unknown>) => ({
  tag: 'INPUT', type: 'text', contentEditable: false, readOnly: false, disabled: false, ...over,
});

describe('isEditableField', () => {
  it('takes text inputs, textareas and contenteditable elements', () => {
    for (const type of ['', 'text', 'search', 'url', 'email', 'tel', 'number', 'TEXT']) {
      expect(isEditableField(field({ type })), type).toBe(true);
    }
    expect(isEditableField(field({ tag: 'TEXTAREA', type: 'textarea' }))).toBe(true);
    expect(isEditableField(field({ tag: 'DIV', type: '', contentEditable: true }))).toBe(true);
  });

  it('never takes a password field', () => {
    expect(isEditableField(field({ type: 'password' }))).toBe(false);
    expect(isEditableField(field({ tag: 'TEXTAREA', type: 'password' }))).toBe(false);
  });

  it('says no to everything that does not take typed text', () => {
    for (const type of ['checkbox', 'radio', 'button', 'submit', 'range', 'file', 'color', 'date']) {
      expect(isEditableField(field({ type })), type).toBe(false);
    }
    expect(isEditableField(field({ tag: 'BUTTON', type: 'button' }))).toBe(false);
    expect(isEditableField(field({ tag: 'BODY', type: '' }))).toBe(false);
    expect(isEditableField(field({ tag: 'SELECT', type: 'select-one' }))).toBe(false);
  });

  it('says no to a read-only or disabled field, and to anything unknown', () => {
    expect(isEditableField(field({ readOnly: true }))).toBe(false);
    expect(isEditableField(field({ disabled: true }))).toBe(false);
    expect(isEditableField(field({ tag: 'DIV', contentEditable: true, readOnly: true }))).toBe(false);
    for (const unknown of [null, undefined, 'input', 42, {}, [], { tag: 5 }]) {
      expect(isEditableField(unknown), String(unknown)).toBe(false);
    }
  });
});
