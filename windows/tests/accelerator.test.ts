import { describe, expect, it } from 'vitest';
import { validateAccelerator } from '../src/core/settings/accelerator.js';

// Failure modes, written before the code. A bad accelerator makes Electron's
// globalShortcut.register THROW, and a saved bad one used to stop the next launch before
// IPC was registered, so every one of these must be refused up front:
//  1. empty, or only modifiers ('Ctrl', 'Ctrl+Alt')
//  2. a key Electron does not know ('Ctrl+DefinitelyNotAKey')
//  3. no Ctrl or Alt (a bare or Shift-only key would swallow typing everywhere)
//  4. two keys, empty tokens ('Ctrl++A'), a repeated modifier
//  5. Escape, which is the fixed cancel key
//  6. non-ASCII keys
//  7. the same combination as the other hotkey, in any spelling or order
// And the combinations people really use must pass.

describe('validateAccelerator', () => {
  it.each([
    '', '   ', 'Ctrl', 'Ctrl+Alt', 'Ctrl+DefinitelyNotAKey', 'Space', 'Shift+A', 'Ctrl+A+B',
    'Ctrl++A', 'Ctrl+Ctrl+A', 'Ctrl+Escape', 'Ctrl+Esc', 'Ctrl+é', 'Ctrl+', '+A',
  ])('refuses %j', (value) => {
    expect(validateAccelerator(value)).not.toBeNull();
  });

  it.each([
    'Control+Alt+Space', 'Ctrl+Shift+K', 'Alt+F9', 'Ctrl+Alt+Left', 'CommandOrControl+Plus',
    'Ctrl+Alt+7', 'Alt+;', 'Ctrl+Alt+PageUp', 'ctrl+alt+space',
  ])('accepts %j', (value) => {
    expect(validateAccelerator(value)).toBeNull();
  });

  it('refuses the other hotkey in any spelling or order', () => {
    expect(validateAccelerator('Ctrl+Alt+L', 'Control+Alt+L')).toMatch(/share/);
    expect(validateAccelerator('Alt+Ctrl+l', 'Control+Alt+L')).toMatch(/share/);
    expect(validateAccelerator('Ctrl+Alt+K', 'Control+Alt+L')).toBeNull();
    expect(validateAccelerator('Ctrl+Alt+K', '')).toBeNull();
  });
});
