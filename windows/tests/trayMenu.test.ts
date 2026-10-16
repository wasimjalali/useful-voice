import { describe, expect, it, vi } from 'vitest';

// The menu template is pure; only the controller around it touches Electron.
vi.mock('electron', () => ({
  app: { isPackaged: false },
  Menu: { buildFromTemplate: (template: unknown) => template },
  nativeImage: { createEmpty: () => ({ addRepresentation: () => undefined }) },
  nativeTheme: { on: () => undefined, off: () => undefined, shouldUseDarkColorsForSystemIntegratedUI: false },
  Tray: class {},
}));

const { buildTrayTemplate, formatAccelerator } = await import('../src/main/tray.js');
import type { TrayHandlers, TrayState } from '../src/main/tray.js';

/**
 * The tray menu's rules (WAS-54 item 2): "Copy last transcript" is always listed, works
 * after any finished dictation and not only after a failed one, and "Retry last
 * recording" is the one that waits for a failure.
 */

const idle: TrayState = {
  recording: false,
  transcribing: false,
  canRetry: false,
  canCopyLast: false,
  hotkeyLabel: 'Control+Alt+Space',
  languagePin: 'auto',
  formattingEnabled: true,
};

function handlers() {
  const calls: string[] = [];
  const spy = (name: string) => () => void calls.push(name);
  const value: TrayHandlers = {
    onToggleDictation: spy('toggle'),
    onOpenWindow: (page) => void calls.push(`open:${page}`),
    onQuit: spy('quit'),
    onRestartToUpdate: spy('restartToUpdate'),
    onRetry: spy('retry'),
    onCopyLast: spy('copyLast'),
    onCancel: spy('cancel'),
    onSetLanguage: (code) => void calls.push(`language:${code}`),
    onSetFormatting: (enabled) => void calls.push(`formatting:${enabled}`),
  };
  return { value, calls };
}

function item(state: TrayState, label: string) {
  const { value, calls } = handlers();
  const found = buildTrayTemplate(state, value).find((entry) => entry.label === label);
  return { found, calls };
}

describe('Copy last transcript', () => {
  it('is always in the menu', () => {
    for (const state of [idle, { ...idle, recording: true }, { ...idle, transcribing: true }, { ...idle, canCopyLast: true }]) {
      expect(item(state, 'Copy last transcript').found).toBeDefined();
    }
  });

  it('is disabled before anything was dictated and enabled once something was, with no failure needed', () => {
    expect(item(idle, 'Copy last transcript').found?.enabled).toBe(false);
    const afterNormalDictation = { ...idle, canRetry: false, canCopyLast: true };
    expect(item(afterNormalDictation, 'Copy last transcript').found?.enabled).toBe(true);
  });

  it('copies when clicked', () => {
    const { found, calls } = item({ ...idle, canCopyLast: true }, 'Copy last transcript');
    (found?.click as () => void)();
    expect(calls).toEqual(['copyLast']);
  });
});

describe('Retry last recording', () => {
  it('waits for a failed dictation whose audio is still held', () => {
    expect(item(idle, 'Retry last recording').found?.enabled).toBe(false);
    expect(item({ ...idle, canCopyLast: true }, 'Retry last recording').found?.enabled).toBe(false);
    expect(item({ ...idle, canRetry: true }, 'Retry last recording').found?.enabled).toBe(true);
  });
});

describe('the rest of the menu follows the dictation state', () => {
  const labels = (state: TrayState): string[] => {
    const { value } = handlers();
    return buildTrayTemplate(state, value).map((entry) => entry.label ?? '-');
  };

  it('says Ready, Recording or Transcribing on the first line', () => {
    expect(labels(idle)[0]).toBe('Ready');
    expect(labels({ ...idle, recording: true })[0]).toBe('Recording');
    expect(labels({ ...idle, transcribing: true })[0]).toBe('Transcribing');
  });

  it('offers Cancel dictation only while something is running', () => {
    expect(labels(idle)).not.toContain('Cancel dictation');
    expect(labels({ ...idle, recording: true })).toContain('Cancel dictation');
    expect(labels({ ...idle, transcribing: true })).toContain('Cancel dictation');
  });

  it('shows where the text will go while recording', () => {
    expect(labels({ ...idle, recording: true, insertingInto: 'Slack' })).toContain('Inserting into: Slack');
    expect(labels({ ...idle, insertingInto: 'Slack' })).not.toContain('Inserting into: Slack');
  });

  it('spells the hotkey the way the app does', () => {
    expect(labels(idle)).toContain('Start dictation (Ctrl+Alt+Space)');
    expect(labels({ ...idle, recording: true })).toContain('Stop dictation (Ctrl+Alt+Space)');
    expect(formatAccelerator('')).toBe('no hotkey');
    expect(formatAccelerator('CommandOrControl+Shift+D')).toBe('Ctrl+Shift+D');
  });

  it('opens Settings from its own item', () => {
    const { value, calls } = handlers();
    const settings = buildTrayTemplate(idle, value).find((entry) => entry.label === 'Open settings');
    (settings?.click as () => void)();
    expect(calls).toEqual(['open:settings']);
  });
});
