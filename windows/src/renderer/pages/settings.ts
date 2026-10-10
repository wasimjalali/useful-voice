import { api } from '../api.js';
import { el } from '../components/dom.js';
import { dropdown } from '../components/dropdown.js';
import { languagePicker } from '../components/languagePicker.js';
import { state, render, setNotice, refresh, activeLanguagePicker } from '../shell.js';
import type { SettingsDTO } from '../../preload/types.js';

// ---- Settings ---------------------------------------------------------

export function renderSettings(): Node {
  const page = el('div', { class: 'page' });
  const settings = state.settings;
  if (!settings) return el('div', { class: 'muted' }, 'Loading…');

  // --- API key ---
  const keyCard = el('div', { class: 'card card-pad' });
  keyCard.append(el('p', { class: 'section-label' }, 'Deepgram API key'));
  keyCard.append(
    el(
      'p',
      { class: 'muted', style: 'margin:8px 0 0;line-height:1.55' as never },
      'Stored encrypted with your Windows account. It is never shown again after saving, and never sent anywhere except Deepgram.',
    ),
  );

  const keyInput = el('input', {
    class: 'field-input',
    type: 'password',
    placeholder: settings.hasApiKey ? '•••••••••••••••• (a key is saved)' : 'Paste your key',
    'aria-label': 'Deepgram API key',
  } as never);

  const keyStatus = el('span', { class: 'tiny faint' });
  keyCard.append(
    el(
      'div',
      { class: 'stack', style: 'margin-top:12px' as never },
      keyInput,
      el(
        'div',
        { class: 'inline wrap' },
        el(
          'button',
          {
            class: 'btn btn-primary',
            type: 'button',
            disabled: !settings.hasApiKey,
            onclick: () => void testKey(keyStatus),
          } as never,
          'Test key',
        ),
        el(
          'button',
          {
            class: 'btn btn-secondary',
            type: 'button',
            onclick: () => void saveKey(keyInput, keyStatus),
          } as never,
          'Save key',
        ),
        settings.hasApiKey
          ? el(
              'button',
              {
                class: 'btn btn-ghost',
                type: 'button',
                onclick: () => void clearKey(keyStatus),
              } as never,
              'Remove key',
            )
          : null,
        // Was Help > Deepgram API keys in the menu bar the frameless window no longer has.
        el(
          'button',
          {
            class: 'btn btn-ghost',
            type: 'button',
            onclick: () => void api.openExternal('https://console.deepgram.com/'),
          } as never,
          'Get a key',
        ),
        keyStatus,
      ),
    ),
  );
  page.append(keyCard);

  // --- Dictation ---
  const dictationCard = el('div', { class: 'card card-pad' });
  dictationCard.append(el('p', { class: 'section-label' }, 'Dictation'));
  const rows = el('div', { class: 'rows', style: 'margin-top:12px' as never });

  // Registered below, once the row is in the page: the language hotkey is global,
  // so it has to be able to open the picker from outside the widget.
  const languagePickerControl = languagePicker({
    value: settings.languagePin,
    onChange: (value) => void saveSettings({ languagePin: value }),
  });
  activeLanguagePicker.current = languagePickerControl;

  rows.append(
    // Replaces a native <select> that (a) could not be searched and (b) offered
    // `multi` - code-switching - labelled "Detect automatically". A user choosing
    // what they were told was detection was silently sent the wrong mode.
    settingRow('Spoken language', 'Detects the language as you speak, or pin one.',
      languagePickerControl.element),
  );

  rows.append(
    switchRow('Format and punctuate', settings.formattingEnabled, 'Adds punctuation, capitalisation and paragraphs.', (value) => void saveSettings({ formattingEnabled: value })),
  );

  rows.append(
    switchRow('Speak punctuation', settings.spokenPunctuationEnabled, 'Say \u201cperiod\u201d, \u201ccomma\u201d or \u201cnew line\u201d to insert it. English only.', (value) => void saveSettings({ spokenPunctuationEnabled: value })),
  );

  // Disclosed because it is charged and was previously invisible: the app sends
  // `keyterm` for every dictionary term on every request, and Deepgram bills
  // Keyterm Prompting separately. https://deepgram.com/pricing
  rows.append(
    el('p', { class: 'note' },
      'Deepgram bills Keyterm Prompting separately from transcription: $0.0013 per minute '
      + 'on pay-as-you-go, on top of $0.0043 per minute for Nova-3. That is about 30% more per '
      + 'minute while your dictionary is in use. Smart formatting and language detection are included.'),
  );

  rows.append(
    switchRow('Sound cues', settings.soundEffectsEnabled, 'A short tone when recording starts and stops.', (value) => void saveSettings({ soundEffectsEnabled: value })),
  );

  rows.append(
    switchRow('Start with Windows', settings.launchAtLogin, 'Keeps the hotkey available without opening the app first.', (value) => void saveSettings({ launchAtLogin: value })),
  );

  rows.append(
    selectRow('Stop after silence', String(settings.silenceTimeoutSeconds), [
      ['15', '15 seconds'], ['30', '30 seconds'], ['45', '45 seconds'],
      ['60', '1 minute'], ['90', '1 minute 30'], ['120', '2 minutes'],
    ], (value) => void saveSettings({ silenceTimeoutSeconds: Number(value) })),
  );

  rows.append(
    selectRow('Maximum recording', String(settings.maxRecordingSeconds), [
      ['60', '1 minute'], ['180', '3 minutes'], ['300', '5 minutes'],
      ['600', '10 minutes'],
    ], (value) => void saveSettings({ maxRecordingSeconds: Number(value) })),
  );

  rows.append(
    textRow('Hotkey', settings.hotkey.accelerator, (value) => void saveSettings({
      hotkey: { ...settings.hotkey, accelerator: value },
    })),
  );

  // macOS has had this from the start; Windows did not, so changing language meant
  // leaving the app you were typing into. An empty value disables it.
  rows.append(
    textRow(
      'Language hotkey',
      settings.languageSwitchHotkey?.accelerator ?? '',
      (value) => void saveSettings({
        languageSwitchHotkey: { accelerator: value.trim(), pushToTalk: false },
      }),
      'Opens the language picker while you dictate. Leave empty to disable.',
    ),
  );

  dictationCard.append(rows);
  page.append(dictationCard);

  // --- Appearance ---
  const appearanceCard = el('div', { class: 'card card-pad' });
  appearanceCard.append(el('p', { class: 'section-label' }, 'Appearance'));
  appearanceCard.append(
    el(
      'div',
      { style: 'margin-top:12px' as never },
      el(
        'div',
        { class: 'segmented', role: 'group', 'aria-label': 'Appearance' } as never,
        ...([
          ['system', 'System'],
          ['light', 'Light'],
          ['dark', 'Dark'],
        ] as const).map(([value, label]) =>
          el(
            'button',
            {
              type: 'button',
              'aria-pressed': settings.appearance === value ? 'true' : 'false',
              onclick: () => void saveSettings({ appearance: value }),
            } as never,
            label,
          ),
        ),
      ),
    ),
  );
  page.append(appearanceCard);

  // --- Diagnostics ---
  const diagCard = el('div', { class: 'card card-pad' });
  diagCard.append(el('p', { class: 'section-label' }, 'Diagnostics'));
  diagCard.append(
    el(
      'p',
      { class: 'muted', style: 'margin:8px 0 0;line-height:1.55' as never },
      'Recent problems are recorded here. No transcript text and no API key is ever written to the log.',
    ),
  );
  const log = el('pre', {
    class: 'sunken mono tiny',
    style: 'margin:12px 0 0;padding:12px;max-height:200px;overflow:auto;white-space:pre-wrap' as never,
  }, 'Loading…');
  diagCard.append(
    log,
    el(
      'div',
      { class: 'inline', style: 'margin-top:12px' as never },
      el(
        'button',
        {
          class: 'btn btn-secondary',
          type: 'button',
          onclick: () => void loadDiagnostics(log),
        } as never,
        'Refresh log',
      ),
      // Was Help > Open diagnostics log in the menu bar the frameless window no longer has.
      el(
        'button',
        {
          class: 'btn btn-secondary',
          type: 'button',
          onclick: () => void api.showDiagnosticsLog(),
        } as never,
        'Open log',
      ),
    ),
  );
  void loadDiagnostics(log);
  page.append(diagCard);

  // --- Backup ---
  const backupCard = el('div', { class: 'card card-pad' });
  backupCard.append(el('p', { class: 'section-label' }, 'Backup and transfer'));
  backupCard.append(
    el(
      'p',
      { class: 'muted', style: 'margin:8px 0 0;line-height:1.55' as never },
      'Files are written to your Documents folder. Importing never overwrites newer work with older.',
    ),
  );
  backupCard.append(
    el(
      'div',
      { class: 'inline wrap', style: 'margin-top:12px' as never },
      el('button', {
        class: 'btn btn-secondary',
        type: 'button',
        onclick: () => void runBackup('export'),
      } as never, 'Export everything'),
      el('button', {
        class: 'btn btn-secondary',
        type: 'button',
        onclick: () => void runBackup('import'),
      } as never, 'Import everything'),
      el('button', {
        class: 'btn btn-secondary',
        type: 'button',
        onclick: () => void runBackup('terms'),
      } as never, 'Export words (CSV)'),
      el('button', {
        class: 'btn btn-secondary',
        type: 'button',
        onclick: () => void runBackup('fixes'),
      } as never, 'Export corrections (CSV)'),
    ),
  );
  page.append(backupCard);

  return page;
}

function switchRow(label: string, checked: boolean, hint: string, onChange: (value: boolean) => void): Node {
  const button = el('button', {
    class: 'switch',
    type: 'button',
    role: 'switch',
    'aria-checked': checked ? 'true' : 'false',
    'aria-label': label,
    onclick: () => onChange(!checked),
  } as never);
  return el(
    'div',
    { class: 'row' },
    el(
      'div',
      {},
      el('div', { class: 'row-label' }, label),
      el('div', { class: 'tiny faint', style: 'margin-top:3px;line-height:1.5' as never }, hint),
    ),
    el('div', { class: 'row-value' }, button),
  );
}

/**
 * A settings row whose control is a custom element rather than a native input.
 *
 * Mirrors `switchRow`'s label-and-hint markup so the language picker lines up with
 * the switches above and below it.
 */
function settingRow(label: string, hint: string, control: Node): Node {
  return el(
    'div',
    { class: 'row' },
    el(
      'div',
      {},
      el('div', { class: 'row-label' }, label),
      el('div', { class: 'tiny faint', style: 'margin-top:3px;line-height:1.5' as never }, hint),
    ),
    el('div', { class: 'row-value' }, control),
  );
}

function selectRow(
  label: string,
  value: string,
  options: Array<[string, string]>,
  onChange: (value: string) => void,
): Node {
  // A native <select> is drawn by the OS and ignores the design system - the
  // same reason the language row uses a custom picker.
  const control = dropdown({
    value,
    options: options.map(([optionValue, optionLabel]) => ({ value: optionValue, label: optionLabel })),
    onChange,
    label,
  });
  return el(
    'div',
    { class: 'row' },
    el('div', { class: 'row-label' }, label),
    el('div', { class: 'row-value' }, control.element),
  );
}

function textRow(
  label: string,
  value: string,
  onChange: (value: string) => void,
  hint?: string,
): Node {
  const input = el('input', { class: 'field-input', value, 'aria-label': label } as never);
  input.addEventListener('change', () => onChange(input.value));
  return el(
    'div',
    { class: 'row' },
    el(
      'div',
      {},
      el('div', { class: 'row-label' }, label),
      hint ? el('div', { class: 'tiny faint', style: 'margin-top:3px;line-height:1.5' as never }, hint) : null,
    ),
    el('div', { class: 'row-value' }, input),
  );
}

// ---- Actions ----------------------------------------------------------

async function saveSettings(patch: Partial<SettingsDTO>): Promise<void> {
  state.settings = await api.saveSettings(patch);
  render();
}

async function saveKey(input: HTMLInputElement, status: HTMLElement): Promise<void> {
  const value = input.value.trim();
  if (value.length === 0) {
    status.textContent = 'Paste a key first.';
    status.className = 'tiny danger';
    return;
  }
  const result = await api.setApiKey(value);
  if (!result.ok) {
    status.textContent = result.error ?? 'The key could not be saved.';
    status.className = 'tiny danger';
    return;
  }
  input.value = '';
  await refresh();
  setNotice('success', 'API key saved.');
}

async function clearKey(status: HTMLElement): Promise<void> {
  await api.clearApiKey();
  await refresh();
  status.textContent = 'Key removed.';
  status.className = 'tiny faint';
  render();
}

async function testKey(status: HTMLElement): Promise<void> {
  status.textContent = 'Checking…';
  status.className = 'tiny faint';
  const result = await api.testApiKey();
  status.textContent = result.message;
  status.className = result.ok ? 'tiny success' : 'tiny danger';
}

async function loadDiagnostics(target: HTMLElement): Promise<void> {
  const info = await api.getDiagnostics();
  const lines = [
    `Useful Voice ${info.version}`,
    `Platform: ${info.platform}`,
    `Log: ${info.logPath}`,
    '',
    ...(info.recentErrors.length > 0 ? info.recentErrors : ['No problems recorded.']),
  ];
  target.textContent = lines.join('\n');
}

async function runBackup(kind: 'export' | 'import' | 'terms' | 'fixes'): Promise<void> {
  let result: { ok: boolean; message: string };
  if (kind === 'export') result = await api.exportBackup();
  else if (kind === 'import') result = await api.importBackup();
  else result = await api.exportCsv(kind);
  setNotice(result.ok ? 'success' : 'danger', result.message);
  if (kind === 'import') await refresh();
  render();
}
