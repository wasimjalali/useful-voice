import { api } from '../api.js';
import { el } from './dom.js';
import { renderChrome, state } from '../shell.js';
import {
  KEY_PROVIDERS,
  KEY_PROVIDER_INFO,
  LANGUAGE_MODELS,
  VOICE_MODELS,
  keyProviderOf,
  type CatalogModel,
  type KeyProvider,
} from '../../core/models/catalog.js';
import { parakeetVersionFromCatalogId } from '../../core/models/parakeet.js';
import { pickAction, type KeyPresence, type ParakeetStates } from '../../core/models/selection.js';
import type { SettingsDTO } from '../../preload/types.js';

// ---- Models -------------------------------------------------------------------
//
// Settings > Models: the voice model list, the AI formatting list and, as their own group
// below, the four API keys. Both lists are radio groups: the whole row selects, the right
// column holds what the model needs (Add key, Download, progress, Delete).

/** What the page gives these groups: its save, its toast and its error text. */
export interface ModelsHost {
  save(patch: Partial<SettingsDTO>): Promise<boolean>;
  toast(message: string, kind?: 'ok' | 'bad'): void;
  messageOf(error: unknown, fallback: string): string;
}

/** About how big the local models are, shown before there is a real size to read. */
const PARAKEET_APPROX = '480 MB';

const MONOGRAMS: Record<CatalogModel['provider'], string> = {
  deepgram: 'D',
  elevenlabs: '11',
  nvidia: 'N',
  gemini: 'G',
  anthropic: 'A',
};

let parakeetStates: ParakeetStates | null = null;
/** A local model picked while it downloads: it becomes the voice model when it's ready. */
let pendingVoiceModel: string | null = null;
let redrawModels: (() => void) | null = null;
let detachParakeet: (() => void) | null = null;
const keyRows = new Map<KeyProvider, { edit: () => void }>();

/** A formatter whose key is missing or unreadable can't run, so the list shows Off rather than pretend. */
function shownFormatterId(id: string | null): string | null {
  const model = LANGUAGE_MODELS.find((candidate) => candidate.id === id);
  const provider = model ? keyProviderOf(model) : null;
  return model && provider && keys()[provider] ? model.id : null;
}

const keys = (): KeyPresence =>
  state.settings?.keys ?? { deepgram: false, elevenlabs: false, gemini: false, anthropic: false };

function formatSize(bytes: number | null): string {
  if (bytes === null) return 'Ready';
  const mb = bytes / 1_000_000;
  return mb >= 1000 ? `${(mb / 1000).toFixed(1)} GB` : `${Math.round(mb)} MB`;
}

function meter(label: string, value: number): HTMLElement {
  const segments = Array.from({ length: 5 }, (_, index) => el('i', { class: index < value ? 'on' : '' }));
  return el('span', { class: 'm-meter', role: 'img', 'aria-label': `${label} ${value} of 5`, title: `${label} ${value} of 5`, 'data-label': label } as never, ...segments);
}

/** The Models group: both lists. */
export function modelsGroup(host: ModelsHost): HTMLElement {
  detachParakeet?.();
  const container = el('div', { class: 'm-lists' });

  const select = async (kind: 'voice' | 'language', model: CatalogModel | null): Promise<void> => {
    const patch = kind === 'voice' ? { voiceModelId: (model as CatalogModel).id } : { formatterId: model?.id ?? null };
    if (kind === 'voice') pendingVoiceModel = null;
    await host.save(patch);
    redraw();
    renderChrome();
  };

  const startDownload = (model: CatalogModel): void => {
    const version = parakeetVersionFromCatalogId(model.id);
    if (!version) return;
    pendingVoiceModel = model.id;
    redraw();
    api.parakeetDownload(version).catch((error: unknown) => {
      pendingVoiceModel = null;
      host.toast(host.messageOf(error, "The download couldn't start."), 'bad');
      redraw();
    });
  };

  const pick = (kind: 'voice' | 'language', model: CatalogModel): void => {
    const action = pickAction(model, keys(), parakeetStates);
    if (action === 'select') void select(kind, model);
    else if (action === 'addKey') {
      const provider = keyProviderOf(model);
      if (provider) keyRows.get(provider)?.edit();
    } else if (action === 'download') startDownload(model);
    else pendingVoiceModel = model.id;
  };

  const side = (model: CatalogModel): HTMLElement => {
    const cell = el('div', { class: 'm-side' });
    const provider = keyProviderOf(model);
    if (provider) {
      cell.append(el('span', { class: 'm-where m-where-cloud' }, 'Cloud'));
      if (!keys()[provider]) {
        cell.append(
          el('button', { class: 'btn btn-secondary btn-sm', type: 'button', onclick: () => keyRows.get(provider)?.edit() } as never, 'Add key'),
        );
      }
      return cell;
    }
    const version = parakeetVersionFromCatalogId(model.id);
    const info = version && parakeetStates ? parakeetStates[version] : { status: 'notDownloaded' as const };
    if (!version) return cell;
    if (info.status === 'ready') {
      cell.append(
        el('span', { class: 'm-where' }, formatSize(info.sizeBytes)),
        el(
          'button',
          {
            class: 'btn btn-ghost btn-sm',
            type: 'button',
            'aria-label': `Delete ${model.name}`,
            onclick: () => void api.parakeetRemove(version).catch((error: unknown) => host.toast(host.messageOf(error, "Couldn't delete it."), 'bad')),
          } as never,
          'Delete',
        ),
      );
    } else if (info.status === 'downloading') {
      const percent = info.progress === null ? null : Math.round(info.progress * 100);
      const bar = el('span', { class: `m-progress${percent === null ? ' is-unknown' : ''}`, role: 'progressbar', 'aria-label': `Downloading ${model.name}` } as never, el('i', {}));
      if (percent !== null) {
        bar.setAttribute('aria-valuenow', String(percent));
        bar.setAttribute('aria-valuemin', '0');
        bar.setAttribute('aria-valuemax', '100');
        (bar.firstElementChild as HTMLElement).style.width = `${percent}%`;
      }
      cell.append(
        bar,
        el('span', { class: 'm-where tnum' }, percent === null ? 'Downloading' : `${percent}%`),
        el('button', { class: 'btn btn-ghost btn-sm', type: 'button', onclick: () => void api.parakeetCancel(version) } as never, 'Cancel'),
      );
    } else {
      const failed = info.status === 'failed';
      cell.append(
        el('span', failed ? { class: 'm-where m-bad', title: info.message } : { class: 'm-where' }, failed ? 'Download failed' : PARAKEET_APPROX),
        el(
          'button',
          { class: 'btn btn-secondary btn-sm', type: 'button', 'aria-label': `${failed ? 'Retry' : 'Download'} ${model.name}`, onclick: () => startDownload(model) } as never,
          failed ? 'Retry' : 'Download',
        ),
      );
    }
    return cell;
  };

  const modelRow = (kind: 'voice' | 'language', model: CatalogModel | null, selectedId: string | null, tabbable: boolean): HTMLElement => {
    const selected = (model?.id ?? null) === selectedId;
    const row = el('div', { class: `m-row${selected ? ' is-selected' : ''}` });
    const action = model ? pickAction(model, keys(), parakeetStates) : 'select';
    const name = model ? model.name : 'Off';
    const label = model ? `${name}, speed ${model.speed} of 5, accuracy ${model.accuracy} of 5` : name;
    const radio = el('div', {
      class: 'm-pick',
      role: 'radio',
      tabindex: tabbable ? 0 : -1,
      'aria-checked': selected ? 'true' : 'false',
      'aria-label': label,
      ...(action === 'addKey' ? { 'aria-disabled': 'true' } : {}),
    } as never);
    radio.append(
      el('span', { class: 'm-dot', 'aria-hidden': 'true' }),
      el('span', { class: 'm-tile', 'aria-hidden': 'true' }, model ? MONOGRAMS[model.provider] : '–'),
      el(
        'span',
        { class: 'm-name' },
        el('span', { class: 'm-name-text' }, name),
        model?.badge ? el('span', { class: 'm-badge' }, model.badge) : null,
      ),
    );
    if (model) radio.append(el('span', { class: 'm-meters' }, meter('Speed', model.speed), meter('Accuracy', model.accuracy)));
    row.append(radio);
    if (model) row.append(side(model));

    const choose = (): void => (model ? pick(kind, model) : void select(kind, null));
    row.addEventListener('click', (event) => {
      if ((event.target as HTMLElement).closest('button')) return;
      choose();
    });
    radio.addEventListener('keydown', (event) => {
      if (event.key === ' ' || event.key === 'Enter') {
        event.preventDefault();
        choose();
      } else if (['ArrowDown', 'ArrowRight', 'ArrowUp', 'ArrowLeft'].includes(event.key)) {
        event.preventDefault();
        const radios = [...(row.parentElement?.querySelectorAll<HTMLElement>('[role="radio"]') ?? [])];
        const step = event.key === 'ArrowDown' || event.key === 'ArrowRight' ? 1 : -1;
        const next = radios[(radios.indexOf(radio) + step + radios.length) % radios.length];
        for (const item of radios) item.tabIndex = item === next ? 0 : -1;
        next?.focus();
      }
    });
    return row;
  };

  const list = (kind: 'voice' | 'language', title: string, models: readonly CatalogModel[], selectedId: string | null, withOff: boolean): HTMLElement => {
    // One header row for both lists: the first list carries it, and the columns line up below.
    const header =
      kind === 'voice'
        ? el('div', { class: 'm-columns', 'aria-hidden': 'true' }, el('span', {}), el('span', {}, 'Speed'), el('span', {}, 'Accuracy'), el('span', {}))
        : null;
    const titleId = `models-${kind}-title`;
    const group = el('div', { class: 'm-list', role: 'radiogroup', 'aria-labelledby': titleId } as never);
    const entries: Array<CatalogModel | null> = withOff ? [null, ...models] : [...models];
    const known = entries.some((entry) => (entry?.id ?? null) === selectedId);
    entries.forEach((entry, index) => {
      const isSelected = (entry?.id ?? null) === selectedId;
      group.append(modelRow(kind, entry, selectedId, known ? isSelected : index === 0));
    });
    return el(
      'div',
      {},
      el('h3', { class: 'm-title', id: titleId }, title),
      el('div', { class: 's-surface' }, header, group),
      kind === 'language' ? el('p', { class: 's-note m-privacy' }, "AI formatting sends each transcript to the model's provider.") : null,
    );
  };

  const redraw = (): void => {
    const settings = state.settings;
    if (!settings) return;
    const focused = document.activeElement?.closest('.m-row');
    const index = focused ? [...container.querySelectorAll('.m-row')].indexOf(focused) : -1;
    container.replaceChildren(
      list('voice', 'Voice model', VOICE_MODELS, settings.voiceModelId, false),
      list('language', 'AI formatting', LANGUAGE_MODELS, shownFormatterId(settings.formatterId), true),
    );
    // A repaint must not cost a keyboard user their place.
    if (index >= 0) container.querySelectorAll<HTMLElement>('.m-row .m-pick')[index]?.focus();
  };
  redrawModels = redraw;
  redraw();

  api.parakeetStates().then(
    (states) => {
      parakeetStates = states;
      redraw();
    },
    () => undefined,
  );
  detachParakeet = api.onParakeetChanged((states) => {
    parakeetStates = states;
    const pending = pendingVoiceModel;
    const version = pending ? parakeetVersionFromCatalogId(pending) : null;
    if (pending && version) {
      const info = states[version];
      if (info.status === 'ready') void select('voice', VOICE_MODELS.find((model) => model.id === pending) ?? null);
      else if (info.status === 'failed') {
        pendingVoiceModel = null;
        host.toast('The download failed. Try again.', 'bad');
      } else if (info.status === 'notDownloaded') pendingVoiceModel = null;
    }
    if (container.isConnected) redraw();
  });
  return container;
}

// ---- API keys ----------------------------------------------------------------------

/** The API keys group: one row per provider. */
export function keysGroup(host: ModelsHost): HTMLElement {
  keyRows.clear();
  const surface = el('div', { class: 's-surface' });
  for (const provider of KEY_PROVIDERS) surface.append(keyRow(provider, host));
  return surface;
}

/**
 * One key row. It owns its own states and repaints only itself:
 *  - no key: two verbs, "Add key" and "Get a key"
 *  - key saved: Test connection, Change key, Remove key
 *  - editing: a field, Save key (the only primary), and a status line. A rejected
 *    key puts the field in the danger edge and shows the message.
 */
function keyRow(provider: KeyProvider, host: ModelsHost): HTMLElement {
  const name = KEY_PROVIDER_INFO[provider].name;
  const keyUrl = KEY_PROVIDER_INFO[provider].keyUrl;
  const container = el('div', { class: 's-row s-row-key', dataset: { provider } });
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

  const getKey = (variant: 'btn-ghost' | 'btn-secondary'): HTMLElement =>
    el('button', { class: `btn ${variant}`, type: 'button', 'aria-label': `Get a ${name} key`, onclick: () => void api.openExternal(keyUrl) } as never, 'Get a key');

  const draw = (): void => {
    const hasKey = keys()[provider];
    const label = el('div', { class: 's-label' }, el('span', {}, `${name} key`));
    const control = el('div', { class: 's-control s-key-control' });

    if (!hasKey && !editing) {
      control.append(
        el('span', { class: 'muted' }, 'No key added'),
        el('button', { class: 'btn btn-primary', type: 'button', 'aria-label': `Add ${name} key`, onclick: () => { editing = true; draw(); } } as never, 'Add key'),
        getKey('btn-secondary'),
      );
    } else if (editing) {
      label.append(el('span', { class: 's-hint' }, 'Stored encrypted with your Windows account.'));
      const input = el('input', {
        class: `field-input ${status?.kind === 'bad' ? 'err' : ''}`,
        type: 'password',
        placeholder: hasKey ? 'Paste a new key' : 'Paste your key',
        'aria-label': `${name} API key`,
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
          hasKey ? el('button', { class: 'btn btn-secondary', type: 'button', onclick: () => { editing = false; status = null; draw(); } } as never, 'Cancel') : null,
          getKey('btn-ghost'),
        ),
        ...(status ? [pill() as HTMLElement] : []),
      );
      queueMicrotask(() => input.focus());
    } else {
      control.append(
        ...(status ? [pill() as HTMLElement] : []),
        el('button', { class: 'btn btn-secondary', type: 'button', 'aria-label': `Test ${name} connection`, onclick: () => void testKey() } as never, 'Test connection'),
        el('button', { class: 'btn btn-secondary', type: 'button', 'aria-label': `Change ${name} key`, onclick: () => { editing = true; status = null; draw(); } } as never, 'Change key'),
        el('button', { class: 'btn btn-ghost', type: 'button', 'aria-label': `Remove ${name} key`, onclick: () => void removeKey() } as never, 'Remove key'),
      );
    }
    container.replaceChildren(label, control);
  };

  /** The key changed: the model lists, the banner and the status button read the presence. */
  const keysChanged = async (saved: boolean): Promise<boolean> => {
    let reloaded = true;
    try {
      state.settings = await api.getSettings();
    } catch (error) {
      reloaded = false;
      if (state.settings) state.settings = { ...state.settings, keys: { ...keys(), [provider]: saved } };
      host.toast(`${saved ? 'Key saved' : 'Key removed'}, but the settings could not be reloaded. ${host.messageOf(error, '')}`.trim(), 'bad');
    }
    editing = false;
    status = null;
    draw();
    redrawModels?.();
    renderChrome();
    return reloaded;
  };

  const saveKey = async (raw: string): Promise<void> => {
    const value = raw.trim();
    if (value.length === 0) {
      status = { kind: 'bad', text: 'Paste a key first.' };
      draw();
      return;
    }
    try {
      const result = await api.setProviderKey(provider, value);
      if (!result.ok) {
        status = { kind: 'bad', text: result.error ?? 'The key could not be saved.' };
        draw();
        return;
      }
    } catch (error) {
      status = { kind: 'bad', text: host.messageOf(error, 'The key could not be saved.') };
      draw();
      return;
    }
    if (await keysChanged(true)) host.toast('Saved');
  };

  const testKey = async (): Promise<void> => {
    status = { kind: 'busy', text: 'Checking…' };
    draw();
    try {
      const result = await api.testProviderKey(provider);
      if (result.ok) {
        status = { kind: 'ok', text: result.message };
      } else {
        // A rejected key is replaced, not retried: open the field with the danger edge.
        status = { kind: 'bad', text: result.message };
        editing = true;
      }
    } catch (error) {
      status = { kind: 'bad', text: host.messageOf(error, 'The key could not be checked.') };
    }
    draw();
  };

  const removeKey = async (): Promise<void> => {
    try {
      const result = await api.clearProviderKey(provider);
      if (!result.ok) {
        host.toast(result.error ?? 'The key could not be removed.', 'bad');
        return;
      }
    } catch (error) {
      host.toast(host.messageOf(error, 'The key could not be removed.'), 'bad');
      return;
    }
    if (await keysChanged(false)) host.toast('Key removed');
  };

  keyRows.set(provider, {
    edit: () => {
      editing = true;
      status = null;
      draw();
      container.scrollIntoView({ block: 'center', behavior: window.matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth' });
    },
  });
  draw();
  return container;
}
