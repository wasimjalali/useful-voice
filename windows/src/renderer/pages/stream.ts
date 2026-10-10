import { api } from '../api.js';
import { el, icon, ICONS } from '../components/dom.js';
import { relativeTime } from '../components/format.js';
import { state, render, setNotice, refresh, navigate } from '../shell.js';
import type { HistoryEntryDTO } from '../../preload/types.js';

// ---- Home -------------------------------------------------------------

export function renderHome(): Node {
  const page = el('div', { class: 'page' });
  const memory = state.memory;

  const stats = el(
    'div',
    { class: 'grid-3' },
    statCard('Words in your dictionary', String(memory?.terms.length ?? 0)),
    statCard('Corrections', String(memory?.replacements.length ?? 0)),
    statCard('Dictations', String(state.history.length)),
  );
  page.append(stats);

  const status = el('div', { class: 'card card-pad' });
  status.append(el('p', { class: 'section-label' }, 'Status'));

  if (!state.settings?.hasApiKey) {
    status.append(
      el(
        'div',
        { class: 'notice notice-danger', style: 'margin-top:10px' as never },
        icon('M12 9v4M12 17h.01M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z', 15),
        el('span', {}, 'No Deepgram API key is set. Add one in Settings to start dictating.'),
      ),
    );
    status.append(
      el(
        'div',
        { class: 'inline', style: 'margin-top:12px' as never },
        el('button', {
          class: 'btn btn-primary',
          type: 'button',
          onclick: () => navigate('settings'),
        } as never, 'Open Settings'),
      ),
    );
  } else if (state.dictation.state === 'error') {
    status.append(
      el(
        'div',
        { class: 'notice notice-danger', style: 'margin-top:10px' as never },
        el('span', {}, state.dictation.message ?? 'The last dictation failed.'),
      ),
    );
    status.append(
      el(
        'div',
        { class: 'inline', style: 'margin-top:12px' as never },
        el('button', {
          class: 'btn btn-secondary',
          type: 'button',
          onclick: () => void api.retryLast(),
        } as never, 'Retry last dictation'),
      ),
    );
  } else {
    status.append(
      el(
        'div',
        { class: 'notice notice-success', style: 'margin-top:10px' as never },
        el('span', {}, 'Ready. Press your hotkey and speak.'),
      ),
    );
  }
  page.append(status);

  const recent = state.history.slice(0, 4);
  const recentCard = el('div', { class: 'card card-pad' });
  recentCard.append(el('p', { class: 'section-label' }, 'Recent dictations'));
  if (recent.length === 0) {
    recentCard.append(
      el('p', { class: 'muted', style: 'margin:10px 0 0' as never }, 'Nothing yet. Your dictations will appear here.'),
    );
  } else {
    recentCard.append(
      el(
        'div',
        { class: 'list', style: 'margin-top:10px' as never },
        ...recent.map((record) =>
          el(
            'div',
            { class: 'list-row' },
            el(
              'div',
              { class: 'list-row-main' },
              el('div', { class: 'list-row-title truncate' }, record.text),
              el(
                'div',
                { class: 'list-row-sub' },
                `${record.appName} · ${relativeTime(record.createdAt)}`,
              ),
            ),
            el(
              'div',
              { class: 'list-row-actions' },
              el(
                'button',
                {
                  class: 'icon-btn',
                  type: 'button',
                  title: 'Copy to clipboard',
                  onclick: () => void copyText(record.text),
                } as never,
                icon(ICONS.copy, 15),
              ),
            ),
          ),
        ),
      ),
    );
  }
  page.append(recentCard);

  return page;
}

function statCard(label: string, value: string): Node {
  return el(
    'div',
    { class: 'card card-pad' },
    el('div', { class: 'stat-value' }, value),
    el('div', { class: 'stat-label' }, label),
  );
}

// ---- History ----------------------------------------------------------

export function renderHistory(): Node {
  const page = el('div', { class: 'page page-wide' });
  const query = state.historyQuery.trim().toLowerCase();
  const records = query.length === 0
    ? state.history
    : state.history.filter((record) => record.text.toLowerCase().includes(query));

  const search = el('input', {
    class: 'field-input',
    placeholder: 'Search your dictations',
    value: state.historyQuery,
  } as never);
  search.addEventListener('input', () => {
    state.historyQuery = search.value;
    // Re-render only the list, so typing does not lose input focus.
    list.replaceChildren(...historyRows(records));
    count.textContent = `${records.length} of ${state.history.length}`;
  });

  const count = el('span', { class: 'tiny faint tnum' }, `${records.length} of ${state.history.length}`);
  page.append(el('div', { class: 'inline' }, el('div', { style: 'flex:1' as never }, search), count));

  const list = el('div', { class: 'list' }, ...historyRows(records));
  page.append(list);

  if (state.history.length > 0) {
    page.append(
      el(
        'div',
        { class: 'inline' },
        el(
          'button',
          { class: 'btn btn-danger', type: 'button', onclick: () => void clearHistory() } as never,
          'Clear all history',
        ),
      ),
    );
  }
  return page;
}

function historyRows(records: HistoryEntryDTO[]): Node[] {
  if (records.length === 0) {
    return [
      el(
        'div',
        { class: 'empty-state' },
        el('h3', {}, state.history.length === 0 ? 'No dictations yet' : 'No matches'),
        el(
          'p',
          {},
          state.history.length === 0
            ? 'Once you dictate, every transcript is kept here so you can copy it again.'
            : 'Try a different word.',
        ),
      ),
    ];
  }
  return records.map((record) =>
    el(
      'div',
      { class: 'list-row', style: 'align-items:flex-start' as never },
      el(
        'div',
        { class: 'list-row-main' },
        el('div', { style: 'font-size:13px;line-height:1.55' as never }, record.text),
        el(
          'div',
          { class: 'list-row-sub inline wrap' },
          el('span', {}, record.appName),
          el('span', {}, '·'),
          el('span', {}, relativeTime(record.createdAt)),
          el('span', {}, '·'),
          el('span', { class: 'tnum' }, `${record.durationSeconds.toFixed(1)}s`),
          record.memoryHitCount > 0
            ? el('span', { class: 'chip chip-mono' }, `${record.memoryHitCount} word${record.memoryHitCount === 1 ? '' : 's'}`)
            : null,
        ),
      ),
      el(
        'div',
        { class: 'list-row-actions' },
        el(
          'button',
          {
            class: 'icon-btn',
            type: 'button',
            title: 'Copy',
            onclick: () => void copyText(record.text),
          } as never,
          icon(ICONS.copy, 15),
        ),
        el(
          'button',
          {
            class: 'icon-btn',
            type: 'button',
            title: 'Delete',
            onclick: () => void removeHistory(record.id),
          } as never,
          icon(ICONS.trash, 15),
        ),
      ),
    ),
  );
}

// ---- Actions ----------------------------------------------------------

async function exportHistoryCsv(): Promise<void> {
  const result = await api.exportHistoryCsv();
  setNotice(result.ok ? 'success' : 'danger', result.message);
}

async function copyText(text: string): Promise<void> {
  await api.copyToClipboard(text);
  setNotice('success', 'Copied to clipboard.');
}

async function removeHistory(id: string): Promise<void> {
  await api.removeHistory(id);
  await refresh();
  render();
}

async function clearHistory(): Promise<void> {
  await api.clearHistory();
  await refresh();
  setNotice('success', 'History cleared.');
}

/** The header buttons for the Home page. */
export function homeHeaderActions(): Node[] {
  return [
    el(
      'button',
      {
        class: 'btn btn-primary',
        type: 'button',
        onclick: () => void api.toggleDictation(),
        disabled: state.dictation.state === 'transcribing' || state.dictation.state === 'delivering',
      } as never,
      state.dictation.state === 'recording' ? 'Stop and transcribe' : 'Start dictating',
    ),
  ];
}

/** The header buttons for the History page. */
export function historyHeaderActions(): Node[] {
  return [
    el(
      'button',
      {
        class: 'btn btn-secondary',
        type: 'button',
        onclick: () => void exportHistoryCsv(),
      } as never,
      icon(ICONS.copy, 14),
      'Export CSV',
    ),
  ];
}

// TEMP until merge: the real Stream page replaces these.
export const renderStreamPage = renderHome;
export const headerActionsForStream = homeHeaderActions;
