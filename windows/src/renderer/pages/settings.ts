import { api } from '../api.js';
import { el, icon, ICONS } from '../components/dom.js';
import { dropdown } from '../components/dropdown.js';
import { previewFeatures } from '../components/flags.js';
import { languagePicker } from '../components/languagePicker.js';
import { state, refresh, activeLanguagePicker } from '../shell.js';
import type { SettingsDTO } from '../../preload/types.js';

// ---- Settings ---------------------------------------------------------
//
// One page, nine groups, an index on the left that follows the scroll. Every control
// saves the moment it changes and says so with a quiet "Saved" toast: there is no
// global Save. The page repaints only the parts that changed, never the whole page,
// so a save never costs the user their scroll position or focus.

const GROUPS: Array<[string, string]> = [
  ['general', 'General'],
  ['engine', 'Engine'],
  ['formatting', 'Formatting'],
  ['hotkeys', 'Hotkeys'],
  ['appearance', 'Appearance'],
  ['data', 'Data'],
  ['importExport', 'Import and export'],
  ['diagnostics', 'Diagnostics'],
  ['about', 'About'],
];

const FIRST_GROUP = 'general';
const LAST_GROUP = 'about';
const MIN_GOAL = 100;
const MAX_GOAL = 100000;

/** German grouping: 2500 -> 2.500. */
function grouped(value: number): string {
  return Math.round(value).toLocaleString('de-DE');
}

/** Electron writes Control, the UI writes Ctrl. Both are accepted on the way in. */
function displayAccelerator(value: string): string {
  return value.replace(/\bControl\b/g, 'Ctrl');
}
function storedAccelerator(value: string): string {
  return value.trim().replace(/\bCtrl\b/g, 'Control');
}

/** The toast host of the page on screen. Replaced on every page render. */
let toastHost: HTMLElement | null = null;
let toastTimer = 0;

function toast(message: string, kind: 'ok' | 'bad' = 'ok'): void {
  if (!toastHost) return;
  window.clearTimeout(toastTimer);
  toastHost.replaceChildren(
    el(
      'div',
      { class: `toast s-toast ${kind === 'bad' ? 's-toast-bad' : ''}` },
      kind === 'ok' ? icon('M5 12.5l4.5 4.5L19 7.5', 16) : el('span', { class: 's-toast-dot' }),
      el('span', {}, message),
    ),
  );
  const host = toastHost;
  toastTimer = window.setTimeout(() => host.replaceChildren(), kind === 'bad' ? 6000 : 1800);
}

/** Save one patch. Failures surface as a toast; the caller decides how to roll back. */
async function save(patch: Partial<SettingsDTO>): Promise<boolean> {
  try {
    state.settings = await api.saveSettings(patch);
  } catch (error) {
    toast(error instanceof Error ? error.message : 'The setting could not be saved.', 'bad');
    return false;
  }
  toast('Saved');
  return true;
}

export function renderSettingsPage(anchor?: string): HTMLElement {
  const settings = state.settings;
  if (!settings) return el('div', { class: 'muted' }, 'Loading…');

  const page = el('div', { class: 'settings-page' });
  const host = el('div', { class: 's-toasts', role: 'status', 'aria-live': 'polite' } as never);
  toastHost = host;

  const diagnostics = api.getDiagnostics();

  const sections = new Map<string, HTMLElement>();
  const groupsColumn = el('div', { class: 's-groups' });
  const addGroup = (id: string, ...children: Array<Node | null>): void => {
    const title = GROUPS.find(([groupId]) => groupId === id)?.[1] ?? id;
    const section = el(
      'section',
      { class: 's-group', id: `settings-${id}`, 'aria-labelledby': `settings-${id}-title` } as never,
      el('h2', { class: 's-group-title', id: `settings-${id}-title` }, title),
      ...children,
    );
    sections.set(id, section);
    groupsColumn.append(section);
  };

  addGroup('general', generalGroup(settings));
  addGroup('engine', engineGroup());
  addGroup('formatting', formattingGroup(settings));
  addGroup('hotkeys', hotkeysGroup(settings));
  addGroup('appearance', appearanceGroup(settings));
  addGroup('data', dataGroup(settings, page));
  addGroup('importExport', importExportGroup());
  addGroup('diagnostics', diagnosticsGroup(diagnostics));
  addGroup('about', aboutGroup(diagnostics));

  // ---- Index and scroll-spy ----
  const items = new Map<string, HTMLButtonElement>();
  let lockUntil = 0;
  const setActive = (id: string): void => {
    for (const [itemId, item] of items) {
      if (itemId === id) item.setAttribute('aria-current', 'true');
      else item.removeAttribute('aria-current');
    }
  };
  const index = el('nav', { class: 's-index', 'aria-label': 'Settings groups' } as never);
  for (const [id, label] of GROUPS) {
    const item = el('button', { class: 's-index-item', type: 'button' } as never, label);
    item.addEventListener('click', () => {
      lockUntil = Date.now() + 700;
      setActive(id);
      scrollToGroup(page, sections.get(id), true);
    });
    items.set(id, item);
    index.append(item);
  }
  setActive(FIRST_GROUP);

  page.append(index, groupsColumn, host);

  // The page is in the document only after this function returns, and the scroll
  // container is the shell's stage body. Wire the spy and the anchor then.
  queueMicrotask(() => {
    detachSpy?.();
    detachSpy = null;
    const scroller = page.closest<HTMLElement>('.stage-body');
    if (!scroller) return;
    const update = (): void => {
      if (!page.isConnected || Date.now() < lockUntil) return;
      const line = scroller.getBoundingClientRect().top + 40;
      let current = FIRST_GROUP;
      for (const [id] of GROUPS) {
        const section = sections.get(id);
        if (section && section.getBoundingClientRect().top <= line) current = id;
      }
      // A short last group never reaches the top line: the end of the scroll counts.
      if (scroller.scrollTop > 0 && scroller.scrollTop + scroller.clientHeight >= scroller.scrollHeight - 2) {
        current = LAST_GROUP;
      }
      setActive(current);
    };
    scroller.addEventListener('scroll', update, { passive: true });
    detachSpy = () => scroller.removeEventListener('scroll', update);
    const target = anchor ? sections.get(anchor) : undefined;
    if (anchor && target) {
      lockUntil = Date.now() + 300;
      setActive(anchor);
      scrollToGroup(page, target, false);
    } else {
      update();
    }
  });

  return page;
}

let detachSpy: (() => void) | null = null;

function scrollToGroup(page: HTMLElement, section: HTMLElement | undefined, smooth: boolean): void {
  const scroller = page.closest<HTMLElement>('.stage-body');
  if (!scroller || !section) return;
  const delta = section.getBoundingClientRect().top - scroller.getBoundingClientRect().top;
  const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  scroller.scrollTo({
    top: scroller.scrollTop + delta - 8,
    behavior: smooth && !reduce ? 'smooth' : 'auto',
  });
}

// ---- Groups -----------------------------------------------------------------

function surface(...rows: Array<Node | null>): HTMLElement {
  return el('div', { class: 's-surface' }, ...rows);
}

function row(label: string, control: Node | null, hint?: string | Node | null): HTMLElement {
  return el(
    'div',
    { class: 's-row' },
    el('div', { class: 's-label' }, el('span', {}, label), hint ? el('span', { class: 's-hint' }, hint) : null),
    el('div', { class: 's-control' }, control),
  );
}

function generalGroup(settings: SettingsDTO): HTMLElement {
  // Registered once the row is in the page: the language hotkey is global, so it has
  // to be able to open the picker from outside the widget.
  const languagePickerControl = languagePicker({
    value: settings.languagePin,
    onChange: (value) => void save({ languagePin: value }),
  });
  activeLanguagePicker.current = languagePickerControl;

  return surface(
    row('Language', languagePickerControl.element),
    row(
      'Start at login',
      switchControl('Start at login', settings.launchAtLogin, (value) => save({ launchAtLogin: value })),
    ),
    row(
      'Sound cues',
      switchControl('Sound cues', settings.soundEffectsEnabled, (value) => save({ soundEffectsEnabled: value })),
    ),
    goalRow(settings),
  );
}

function goalRow(settings: SettingsDTO): HTMLElement {
  const input = el('input', {
    class: 'field-input s-goal',
    inputMode: 'numeric',
    value: grouped(settings.dailyWordGoal),
    'aria-label': 'Daily goal in words',
  } as never);
  const hint = el('span', { class: 's-hint' });
  const wrapper = el(
    'div',
    { class: 's-row' },
    el('div', { class: 's-label' }, el('span', {}, 'Daily goal'), hint),
    el('div', { class: 's-control' }, input, el('span', { class: 'muted' }, 'words')),
  );
  const fail = (message: string): void => {
    input.classList.add('err');
    hint.textContent = message;
    hint.classList.add('s-hint-bad');
  };
  input.addEventListener('input', () => {
    input.classList.remove('err');
    hint.textContent = '';
    hint.classList.remove('s-hint-bad');
  });
  input.addEventListener('change', () => {
    const digits = input.value.replace(/[.\s]/g, '');
    const value = Number(digits);
    if (!/^\d+$/.test(digits) || value < MIN_GOAL || value > MAX_GOAL) {
      fail(`Pick a number from ${grouped(MIN_GOAL)} to ${grouped(MAX_GOAL)}.`);
      return;
    }
    void save({ dailyWordGoal: value }).then((ok) => {
      if (ok && state.settings) input.value = grouped(state.settings.dailyWordGoal);
    });
  });
  return wrapper;
}

function engineGroup(): HTMLElement {
  return surface(
    row('Engine', el('span', {}, 'Deepgram Nova-3')),
    keyRow(),
    // The local engine does not exist on Windows yet. Preview builds show where it
    // will go, as a status and nothing to press.
    previewFeatures()
      ? row('Whisper (local)', el('span', { class: 'status-pill' }, 'Coming later'))
      : null,
  );
}

/**
 * The Deepgram key row. It owns its own states and repaints only itself:
 *  - no key: two verbs, "Add key" and "Get a key" (a-61)
 *  - key saved: Test connection, Change key, Remove key
 *  - editing: a field, Save key (the only primary), and a status line. A rejected
 *    key puts the field in the danger edge and shows the server's message (a-60).
 */
function keyRow(): HTMLElement {
  const container = el('div', { class: 's-key' });
  let editing = false;
  let status: { kind: 'ok' | 'bad' | 'busy'; text: string } | null = null;

  const pill = (): HTMLElement | null =>
    status
      ? el(
          'span',
          { class: `status-pill ${status.kind === 'ok' ? 'ok' : status.kind === 'bad' ? 'bad' : ''}`, role: 'status' } as never,
          el('span', { class: 'status-dot' }),
          status.text,
        )
      : null;

  const getKey = el(
    'button',
    {
      class: 'btn btn-ghost',
      type: 'button',
      onclick: () => void api.openExternal('https://console.deepgram.com/'),
    } as never,
    'Get a key',
  );

  const draw = (): void => {
    const hasKey = state.settings?.hasApiKey ?? false;
    const label = el('div', { class: 's-label' }, el('span', {}, 'Deepgram key'));
    const control = el('div', { class: 's-control s-key-control' });

    if (!hasKey && !editing) {
      control.append(
        el('span', { class: 'muted' }, 'No key added'),
        el('button', { class: 'btn btn-primary', type: 'button', onclick: () => { editing = true; draw(); } } as never, 'Add key'),
        el('button', { class: 'btn btn-secondary', type: 'button', onclick: () => void api.openExternal('https://console.deepgram.com/') } as never, 'Get a key'),
      );
    } else if (editing) {
      label.append(el('span', { class: 's-hint' }, 'Stored encrypted with your Windows account.'));
      const input = el('input', {
        class: `field-input ${status?.kind === 'bad' ? 'err' : ''}`,
        type: 'password',
        placeholder: hasKey ? 'Paste a new key' : 'Paste your key',
        'aria-label': 'Deepgram API key',
        autocomplete: 'off',
      } as never);
      const submit = (): void => void saveKey(input.value);
      input.addEventListener('keydown', (event) => {
        if (event.key === 'Enter') submit();
      });
      control.append(
        input,
        el(
          'div',
          { class: 's-buttons' },
          el('button', { class: 'btn btn-primary', type: 'button', onclick: submit } as never, 'Save key'),
          hasKey
            ? el('button', { class: 'btn btn-secondary', type: 'button', onclick: () => { editing = false; status = null; draw(); } } as never, 'Cancel')
            : null,
          getKey,
        ),
        ...(status ? [pill() as HTMLElement] : []),
      );
      queueMicrotask(() => input.focus());
    } else {
      label.append(el('span', { class: 's-hint' }, 'Stored encrypted with your Windows account.'));
      control.append(
        ...(status ? [pill() as HTMLElement] : []),
        el('button', { class: 'btn btn-secondary', type: 'button', onclick: () => void testKey() } as never, 'Test connection'),
        el('button', { class: 'btn btn-secondary', type: 'button', onclick: () => { editing = true; status = null; draw(); } } as never, 'Change key'),
        el('button', { class: 'btn btn-ghost', type: 'button', onclick: () => void removeKey() } as never, 'Remove key'),
      );
    }
    container.replaceChildren(label, control);
  };

  const saveKey = async (raw: string): Promise<void> => {
    const value = raw.trim();
    if (value.length === 0) {
      status = { kind: 'bad', text: 'Paste a key first.' };
      draw();
      return;
    }
    const result = await api.setApiKey(value);
    if (!result.ok) {
      status = { kind: 'bad', text: result.error ?? 'The key could not be saved.' };
      draw();
      return;
    }
    state.settings = await api.getSettings();
    editing = false;
    status = null;
    draw();
    toast('Saved');
  };

  const testKey = async (): Promise<void> => {
    status = { kind: 'busy', text: 'Checking…' };
    draw();
    const result = await api.testApiKey();
    if (result.ok) {
      status = { kind: 'ok', text: result.message };
    } else {
      // A rejected key is replaced, not retried: open the field with the danger edge.
      status = { kind: 'bad', text: result.message };
      editing = true;
    }
    draw();
  };

  const removeKey = async (): Promise<void> => {
    await api.clearApiKey();
    state.settings = await api.getSettings();
    editing = false;
    status = null;
    draw();
    toast('Key removed');
  };

  draw();
  container.className = 's-row s-row-key';
  return container;
}

function formattingGroup(settings: SettingsDTO): HTMLElement {
  const wrapper = el('div', {});
  wrapper.append(
    surface(
      row(
        'Auto-format transcript',
        switchControl('Auto-format transcript', settings.formattingEnabled, (value) => save({ formattingEnabled: value })),
      ),
      row(
        'Speak punctuation',
        switchControl('Speak punctuation', settings.spokenPunctuationEnabled, (value) => save({ spokenPunctuationEnabled: value })),
        'English only. Say period, comma or new line.',
      ),
    ),
    // Disclosed because it is charged: the app sends a keyterm for every dictionary
    // term on every request and Deepgram bills Keyterm Prompting separately.
    el(
      'p',
      { class: 's-note' },
      'Deepgram bills Keyterm Prompting separately: $0,0013 per minute on top of $0,0043 per minute for Nova-3. '
        + 'That is about 30 % more while your dictionary is in use.',
    ),
  );
  return wrapper;
}

function hotkeysGroup(settings: SettingsDTO): HTMLElement {
  return surface(
    hotkeyRow('Dictation', settings.hotkey.accelerator, false, (value) =>
      save({ hotkey: { ...(state.settings?.hotkey ?? settings.hotkey), accelerator: value } }),
    ),
    hotkeyRow(
      'Language picker',
      settings.languageSwitchHotkey?.accelerator ?? '',
      true,
      (value) => save({ languageSwitchHotkey: { accelerator: value, pushToTalk: false } }),
      'Opens the language picker while you dictate. Leave empty to turn it off.',
    ),
    row('Cancel dictation', el('span', { class: 's-fixed' }, el('span', { class: 'kbd' }, 'Esc'), 'Fixed')),
  );
}

/**
 * A hotkey row. Capturing a combination by pressing it is a preview feature; today's
 * control is a text field holding the combination.
 */
function hotkeyRow(
  label: string,
  current: string,
  allowEmpty: boolean,
  onSave: (accelerator: string) => Promise<boolean>,
  hintText?: string,
): HTMLElement {
  const hint = el('span', { class: 's-hint' }, hintText ?? '');
  const showHint = (text: string | undefined, bad: boolean): void => {
    hint.textContent = text ?? '';
    hint.classList.toggle('s-hint-bad', bad);
  };

  const wrapper = el('div', { class: 's-row' });
  const control = el('div', { class: 's-control' });
  wrapper.append(el('div', { class: 's-label' }, el('span', {}, label), hint), control);

  if (!previewFeatures()) {
    const input = el('input', {
      class: 'field-input s-hotkey',
      value: displayAccelerator(current),
      'aria-label': label,
      placeholder: allowEmpty ? 'Off' : '',
    } as never);
    input.addEventListener('change', () => {
      const value = input.value.trim();
      if (value.length === 0 && !allowEmpty) {
        input.value = displayAccelerator(state.settings?.hotkey.accelerator ?? current);
        showHint('A dictation hotkey is required.', true);
        return;
      }
      showHint(hintText, false);
      void onSave(storedAccelerator(value)).then((ok) => {
        if (!ok) input.value = displayAccelerator(current);
      });
    });
    control.append(input);
    return wrapper;
  }

  let value = current;
  const draw = (listening: boolean): void => {
    if (!listening) {
      control.replaceChildren(
        el(
          'button',
          { class: 'btn btn-secondary s-capture', type: 'button', onclick: () => listen() } as never,
          value.length > 0 ? displayAccelerator(value) : 'Off',
        ),
      );
      return;
    }
    control.replaceChildren(
      el('span', { class: 's-capture-field' }, el('span', {}, 'Press a key'), el('span', { class: 'muted' }, 'Esc to cancel')),
      el('button', { class: 'btn btn-secondary', type: 'button', onclick: () => stop() } as never, 'Cancel'),
    );
  };

  let onKey: ((event: KeyboardEvent) => void) | null = null;
  const stop = (): void => {
    if (onKey) window.removeEventListener('keydown', onKey, true);
    onKey = null;
    draw(false);
  };
  const listen = (): void => {
    showHint(hintText, false);
    draw(true);
    onKey = (event) => {
      event.preventDefault();
      event.stopPropagation();
      if (event.key === 'Escape') {
        stop();
        return;
      }
      if (['Control', 'Alt', 'Shift', 'Meta'].includes(event.key)) return;
      const main = keyName(event.code);
      if (!main) {
        showHint("That key can't be used.", true);
        return;
      }
      if (!event.ctrlKey && !event.altKey) {
        showHint('Add Ctrl or Alt, like Ctrl+Alt+Space.', true);
        return;
      }
      const accelerator = [
        event.ctrlKey ? 'Control' : null,
        event.altKey ? 'Alt' : null,
        event.shiftKey ? 'Shift' : null,
        main,
      ].filter(Boolean).join('+');
      showHint(hintText, false);
      void onSave(accelerator).then((ok) => {
        if (ok) value = accelerator;
        stop();
      });
    };
    window.addEventListener('keydown', onKey, true);
  };
  draw(false);
  return wrapper;
}

function keyName(code: string): string | null {
  const letter = /^Key([A-Z])$/.exec(code);
  if (letter?.[1]) return letter[1];
  const digit = /^Digit(\d)$/.exec(code);
  if (digit?.[1]) return digit[1];
  if (/^F\d{1,2}$/.test(code)) return code;
  const named: Record<string, string> = {
    Space: 'Space', ArrowUp: 'Up', ArrowDown: 'Down', ArrowLeft: 'Left', ArrowRight: 'Right',
    Enter: 'Return', Tab: 'Tab', Backspace: 'Backspace',
  };
  return named[code] ?? null;
}

function appearanceGroup(settings: SettingsDTO): HTMLElement {
  const buttons = new Map<string, HTMLButtonElement>();
  const mark = (value: string): void => {
    for (const [id, button] of buttons) button.setAttribute('aria-pressed', id === value ? 'true' : 'false');
  };
  const group = el('div', { class: 'segmented', role: 'group', 'aria-label': 'Theme' } as never);
  for (const [value, label] of [['system', 'System'], ['light', 'Light'], ['dark', 'Dark']] as const) {
    const button = el('button', { type: 'button' } as never, label);
    button.addEventListener('click', () => {
      const before = state.settings?.appearance ?? settings.appearance;
      mark(value);
      void save({ appearance: value }).then((ok) => {
        if (!ok) mark(before);
      });
    });
    buttons.set(value, button);
    group.append(button);
  }
  mark(settings.appearance);
  return surface(row('Theme', group));
}

function dataGroup(settings: SettingsDTO, page: HTMLElement): HTMLElement {
  return surface(
    selectRow('Stop after silence', settings.silenceTimeoutSeconds, [
      [15, '15 seconds'], [30, '30 seconds'], [45, '45 seconds'],
      [60, '1 minute'], [90, '1 minute 30'], [120, '2 minutes'],
    ], (value) => save({ silenceTimeoutSeconds: value })),
    selectRow('Maximum recording', settings.maxRecordingSeconds, [
      [60, '1 minute'], [180, '3 minutes'], [300, '5 minutes'], [600, '10 minutes'],
    ], (value) => save({ maxRecordingSeconds: value })),
    // Saved recordings do not exist on Windows yet (UV-029): preview builds only.
    previewFeatures()
      ? selectRow('Keep recordings', settings.recordingsToKeep, [
          [0, 'None'], [5, 'Last 5'], [10, 'Last 10'], [25, 'Last 25'],
        ], (value) => save({ recordingsToKeep: value }))
      : null,
    deleteRow(page),
  );
}

function selectRow(
  label: string,
  value: number,
  options: Array<[number, string]>,
  onChange: (value: number) => Promise<boolean>,
): HTMLElement {
  // A stored value outside the list (an older build, a hand-edited file) must still
  // show, or the control would read as empty.
  const known = options.some(([optionValue]) => optionValue === value);
  const list = known ? options : [...options, [value, `${grouped(value)} seconds`] as [number, string]];
  const control = dropdown({
    value: String(value),
    options: list.map(([optionValue, optionLabel]) => ({ value: String(optionValue), label: optionLabel })),
    onChange: (next) => void onChange(Number(next)),
    label,
  });
  return row(label, control.element);
}

function deleteRow(page: HTMLElement): HTMLElement {
  const button = el(
    'button',
    { class: 'btn btn-danger s-danger', type: 'button' } as never,
    icon(ICONS.trash, 15),
    'Delete all dictations…',
  );
  button.addEventListener('click', () => void confirmDelete(page, button));
  return row('Delete all dictations', button);
}

async function confirmDelete(page: HTMLElement, opener: HTMLElement): Promise<void> {
  // The count in the dialog is read now, so it is exactly what Delete will remove.
  state.history = await api.getHistory();
  const count = state.history.length;
  if (count === 0) {
    toast('There are no dictations to delete.');
    return;
  }
  const noun = count === 1 ? 'dictation' : 'dictations';

  const cancel = el('button', { class: 'btn btn-secondary', type: 'button' } as never, 'Cancel');
  const confirm = el('button', { class: 'btn btn-tone', type: 'button' } as never, `Delete ${grouped(count)} ${noun}`);
  const panel = el(
    'div',
    { class: 'dialog-panel', role: 'dialog', 'aria-modal': 'true', 'aria-labelledby': 's-del-title', 'aria-describedby': 's-del-body' } as never,
    el('h3', { class: 'dialog-title', id: 's-del-title' }, 'Delete all dictations?'),
    el(
      'p',
      { class: 'dialog-body', id: 's-del-body' },
      `This removes ${grouped(count)} ${noun} from this PC. Notes and your vocabulary stay. You can't undo this.`,
    ),
    el('div', { class: 'dialog-actions' }, cancel, confirm),
  );
  const overlay = el('div', { class: 'dialog-overlay' }, panel);

  const close = (): void => {
    overlay.remove();
    opener.focus();
  };
  overlay.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') {
      event.stopPropagation();
      close();
    } else if (event.key === 'Tab') {
      // Two controls: keep focus between them.
      event.preventDefault();
      (document.activeElement === cancel ? confirm : cancel).focus();
    }
  });
  overlay.addEventListener('mousedown', (event) => {
    if (event.target === overlay) close();
  });
  cancel.addEventListener('click', close);
  confirm.addEventListener('click', () => {
    void (async () => {
      confirm.setAttribute('disabled', 'true');
      await api.clearHistory();
      state.history = [];
      close();
      toast(`Deleted ${grouped(count)} ${noun}`);
    })();
  });

  page.append(overlay);
  cancel.focus();
}

function importExportGroup(): HTMLElement {
  const run = (call: () => Promise<{ ok: boolean; message: string }>, refreshAfter = false) => async (): Promise<void> => {
    const result = await call();
    toast(result.message, result.ok ? 'ok' : 'bad');
    if (refreshAfter && result.ok) await refresh();
  };
  const button = (label: string, action: () => Promise<void>): HTMLElement =>
    el('button', { class: 'btn btn-secondary', type: 'button', onclick: () => void action() } as never, label);

  return surface(
    row(
      'Backup',
      el(
        'div',
        { class: 's-buttons' },
        button('Export everything', run(() => api.exportBackup())),
        button('Import everything', run(() => api.importBackup(), true)),
      ),
    ),
    row('Dictations', button('Export CSV', run(() => api.exportHistoryCsv()))),
    row(
      'Words and fixes',
      el(
        'div',
        { class: 's-buttons' },
        button('Export words (CSV)', run(() => api.exportCsv('terms'))),
        button('Export fixes (CSV)', run(() => api.exportCsv('fixes'))),
      ),
    ),
  );
}

function diagnosticsGroup(info: ReturnType<typeof api.getDiagnostics>): HTMLElement {
  const log = el('pre', { class: 's-log' }, 'Loading…');
  const copy = el('button', { class: 'btn btn-secondary', type: 'button', disabled: true } as never, 'Copy report');
  let report = '';
  copy.addEventListener('click', () => {
    void api.copyToClipboard(report).then(() => toast('Copied'));
  });
  void info.then((data) => {
    const hasProblems = data.recentErrors.length > 0;
    log.textContent = hasProblems ? data.recentErrors.join('\n') : 'Nothing recorded yet.';
    log.classList.toggle('s-log-empty', !hasProblems);
    report = [`Useful Voice ${data.version}`, `Platform: ${data.platform}`, '', ...data.recentErrors].join('\n');
    // Both buttons wait for something to copy (a-72): Open log stays, it opens a file.
    copy.toggleAttribute('disabled', !hasProblems);
  });
  return surface(
    el('div', { class: 's-log-wrap' }, log),
    row(
      'Event log',
      el(
        'div',
        { class: 's-buttons' },
        copy,
        el('button', { class: 'btn btn-secondary', type: 'button', onclick: () => void api.showDiagnosticsLog() } as never, 'Open log'),
      ),
    ),
  );
}

function aboutGroup(info: ReturnType<typeof api.getDiagnostics>): HTMLElement {
  const version = el('span', { class: 'tnum' }, '');
  void info.then((data) => {
    version.textContent = data.version;
  });
  return surface(row('Version', version));
}

// ---- Controls ----------------------------------------------------------------

/** A switch that flips at once and rolls back if the save fails. */
function switchControl(label: string, checked: boolean, onChange: (value: boolean) => Promise<boolean>): HTMLElement {
  const button = el('button', {
    class: 'switch',
    type: 'button',
    role: 'switch',
    'aria-checked': checked ? 'true' : 'false',
    'aria-label': label,
  } as never);
  button.addEventListener('click', () => {
    const next = button.getAttribute('aria-checked') !== 'true';
    button.setAttribute('aria-checked', next ? 'true' : 'false');
    void onChange(next).then((ok) => {
      if (!ok) button.setAttribute('aria-checked', next ? 'false' : 'true');
    });
  });
  return button;
}
