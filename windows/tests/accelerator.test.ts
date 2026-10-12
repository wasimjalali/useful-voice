import { describe, expect, it } from 'vitest';
import { sameAccelerator, validateAccelerator } from '../src/core/settings/accelerator.js';

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
    'Ctrl++A', 'Ctrl+A+', 'Ctrl+Ctrl+A', 'Ctrl+Escape', 'Ctrl+Esc', 'Ctrl+é', 'Ctrl+', '+A',
    'Ctrl+F25', 'Ctrl+F0', 'Ctrl+num10', 'Ctrl+Alt+Super', "Ctrl+Alt+'",
  ])('refuses %j', (value) => {
    expect(validateAccelerator(value)).not.toBeNull();
  });

  it.each([
    'Control+Alt+Space', 'Ctrl+Shift+K', 'Alt+F9', 'Ctrl+Alt+Left', 'CommandOrControl+Plus',
    'Ctrl+Alt+7', 'Alt+;', 'Ctrl+Alt+PageUp', 'ctrl+alt+space',
    // The rest of Electron's documented key codes.
    'Ctrl+Alt+PrintScreen', 'Ctrl+Alt+num0', 'Ctrl+Alt+num9', 'Ctrl+Alt+numadd', 'Ctrl+Alt+numsub',
    'Ctrl+Alt+numdec', 'Ctrl+Alt+nummult', 'Ctrl+Alt+numdiv', 'Ctrl+Alt+Capslock', 'Ctrl+Alt+Numlock',
    'Ctrl+Alt+Scrolllock', 'Ctrl+Alt+VolumeUp', 'Ctrl+Alt+VolumeDown', 'Ctrl+Alt+VolumeMute',
    'Ctrl+Alt+MediaNextTrack', 'Ctrl+Alt+MediaPreviousTrack', 'Ctrl+Alt+MediaStop', 'Ctrl+Alt+MediaPlayPause',
    'Ctrl+Alt+F24', 'Ctrl+Alt+Insert', 'Ctrl+Alt+Delete', 'Ctrl+Alt+Home', 'Ctrl+Alt+End', 'Ctrl+Alt+Tab',
    'Ctrl+Alt+Backspace', 'Ctrl+Alt+Enter', 'Ctrl+Alt+Return', 'Ctrl+Alt+Down', 'Ctrl+Alt+Right',
    'Ctrl+Alt+\\', 'Ctrl+Alt+`', 'Ctrl+Alt+[', 'Ctrl+Alt+]', 'AltGr+K', 'Ctrl+Meta+K', 'Alt+Option+K'.replace('Alt+Option', 'Option'),
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

describe('sameAccelerator', () => {
  it('compares combinations, not spellings', () => {
    expect(sameAccelerator('control+alt+space', 'Control+Alt+Space')).toBe(true);
    expect(sameAccelerator('Alt+Ctrl+Space', 'Control+Alt+Space')).toBe(true);
    expect(sameAccelerator('Ctrl+Alt+K', 'Control+Alt+Space')).toBe(false);
    expect(sameAccelerator('Ctrl', 'Control+Alt+Space')).toBe(false);
  });
});
