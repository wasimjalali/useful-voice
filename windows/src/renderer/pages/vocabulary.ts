import { api } from '../api.js';
import { el, icon, ICONS } from '../components/dom.js';
import { state, render, setNotice, refresh } from '../shell.js';
import type { MemorySnapshotDTO } from '../../preload/types.js';

const SEARCH_ICON = 'M11 19a8 8 0 1 0 0-16 8 8 0 0 0 0 16zM21 21l-4.3-4.3';
const MORE_ICON = 'M5 12h.01M12 12h.01M19 12h.01';

type Filter = 'all' | 'words' | 'fixes' | 'snippets' | 'suggestions';
type Rule =
  | { kind: 'word'; id: string; phrase: string; soundsLike: string[]; uses: number }
  | { kind: 'fix'; id: string; match: string; replacement: string; enabled: boolean; uses: number }
  | { kind: 'snippet'; id: string; trigger: string; expansion: string; uses: number };

// Module state: the page is rebuilt on every shell repaint, so the filter, the search
// and the half-typed Add row survive in these.
let filter: Filter = 'all';
let query = '';
const addRow = { say: '', write: '' };

const KIND_LABEL = { word: 'Word', fix: 'Fix', snippet: 'Snippet' } as const;
const FILTER_LABEL: Record<Filter, string> = {
  all: 'All',
  words: 'Words',
  fixes: 'Fixes',
  snippets: 'Snippets',
  suggestions: 'Suggestions',
};

function fmt(value: number): string {
  return value.toLocaleString('de-DE');
}

function rulesOf(memory: MemorySnapshotDTO): Rule[] {
  return [
    ...memory.terms.map((t): Rule => ({ kind: 'word', id: t.id, phrase: t.phrase, soundsLike: t.pronunciations, uses: t.usageCount })),
    ...memory.replacements.map((r): Rule => ({ kind: 'fix', id: r.id, match: r.match, replacement: r.replacement, enabled: r.isEnabled, uses: r.usageCount })),
    ...memory.snippets.map((s): Rule => ({ kind: 'snippet', id: s.id, trigger: s.trigger, expansion: s.expansion, uses: s.usageCount })),
  ];
}

function ruleText(rule: Rule): string {
  if (rule.kind === 'word') return [rule.phrase, ...rule.soundsLike].join(' ');
  if (rule.kind === 'fix') return `${rule.match} ${rule.replacement}`;
  return `${rule.trigger} ${rule.expansion}`;
}

// ---- Page -------------------------------------------------------------

export function renderVocabularyPage(): HTMLElement {
  const page = el('div', { class: 'page page-wide vocab' });
  const memory = state.memory;
  if (!memory) return el('div', { class: 'muted' }, 'Loading');

  const report = memory.keytermReport;
  if (report.dropped > 0 || report.rejected > 0) {
    page.append(
      el(
        'div',
        { class: 'notice notice-warning' },
        icon('M12 9v4M12 17h.01M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z', 15),
        el(
          'span',
          {},
          `${fmt(report.dropped + report.rejected)} of your entries are not being sent to the recogniser `
          + `(the limit is ${fmt(report.limit)} per request). The highest-priority entries are used first.`,
        ),
      ),
    );
  }

  const rules = rulesOf(memory);
  const counts: Record<Filter, number> = {
    all: rules.length,
    words: memory.terms.length,
    fixes: memory.replacements.length,
    snippets: memory.snippets.length,
    suggestions: memory.suggestions.length,
  };

  const segmented = el(
    'div',
    { class: 'segmented', role: 'group', 'aria-label': 'Filter' } as never,
    ...(Object.keys(FILTER_LABEL) as Filter[]).map((id) =>
      el(
        'button',
        {
          type: 'button',
          'aria-selected': filter === id ? 'true' : 'false',
          onclick: () => {
            filter = id;
            addRow.say = '';
            addRow.write = '';
            render();
          },
        } as never,
        FILTER_LABEL[id],
        el('span', { class: 'tnum vocab-count' }, fmt(counts[id])),
      ),
    ),
  );

  const search = el('input', {
    class: 'field-input vocab-search',
    type: 'search',
    value: query,
    placeholder: 'Search rules',
    'aria-label': 'Search rules',
  } as never);
  const body = el('div', { class: 'vocab-body' });
  const fillBody = (): void => {
    body.replaceChildren(...(filter === 'suggestions' ? suggestionCards(memory) : [ruleTable(rules)]));
  };
  search.addEventListener('input', () => {
    query = search.value;
    fillBody();
  });
  fillBody();

  page.append(
    el('div', { class: 'vocab-bar' }, segmented, el('div', { class: 'vocab-searchwrap' }, icon(SEARCH_ICON, 15), search)),
  );
  if (filter !== 'suggestions') page.append(addRowFor(filter));
  page.append(body);
  return page;
}

// ---- Add row ----------------------------------------------------------

function addRowFor(current: Filter): HTMLElement {
  const snippets = current === 'snippets';
  const say = el('input', {
    class: 'field-input',
    value: addRow.say,
    placeholder: snippets ? 'Trigger' : 'What it hears',
    'aria-label': snippets ? 'Trigger' : 'What it hears',
  } as never);
  const write = el('input', {
    class: 'field-input',
    value: addRow.write,
    placeholder: snippets ? 'Text' : 'What you want',
    'aria-label': snippets ? 'Text to write' : 'What you want',
  } as never);
  say.addEventListener('input', () => (addRow.say = say.value));
  write.addEventListener('input', () => (addRow.write = write.value));
  const submit = (): void => void addRule(current, say.value.trim(), write.value.trim());
  for (const input of [say, write]) {
    input.addEventListener('keydown', (event) => {
      if (event.key === 'Enter') submit();
    });
  }
  return el(
    'div',
    { class: 'vocab-add' },
    el('span', { class: 'vocab-add-word' }, 'When I say'),
    say,
    el('span', { class: 'vocab-add-word' }, snippets ? 'expand to' : 'write'),
    write,
    el('button', { class: 'btn btn-primary', type: 'button', onclick: submit } as never, 'Add'),
  );
}

async function addRule(current: Filter, say: string, write: string): Promise<void> {
  const language = state.settings?.languagePin ?? 'auto';
  if (current === 'snippets') {
    if (!say || !write) {
      setNotice('danger', 'Fill in the trigger and the text to write.');
      return;
    }
    await api.addSnippet({ trigger: say, expansion: write, language });
    setNotice('success', `Say “${say}” to write your text.`);
  } else if (!write) {
    setNotice('danger', say ? 'Add what to write.' : 'Add a word to write.');
    return;
  } else if (!say) {
    await api.addTerm({ phrase: write, language });
    setNotice('success', `Added “${write}”.`);
  } else {
    await api.addReplacement({ match: say, replacement: write, language });
    setNotice('success', `“${say}” will be written as “${write}”.`);
  }
  addRow.say = '';
  addRow.write = '';
  await refresh();
  render();
}

// ---- Rules ------------------------------------------------------------

function chip(text: string): HTMLElement {
  return el('span', { class: 'vocab-chip', dir: 'auto' }, text);
}

function ruleSentence(rule: Rule): HTMLElement {
  if (rule.kind === 'word') {
    return el(
      'div',
      { class: 'vocab-rule' },
      el('span', {}, 'Always write '),
      chip(rule.phrase),
      rule.soundsLike.length > 0 ? el('span', { class: 'vocab-quiet' }, ` sounds like ${rule.soundsLike.join(', ')}`) : null,
    );
  }
  if (rule.kind === 'fix') {
    return el('div', { class: 'vocab-rule' }, el('span', {}, 'When I say '), chip(rule.match), el('span', {}, ' write '), chip(rule.replacement));
  }
  return el(
    'div',
    { class: 'vocab-rule' },
    el('span', {}, 'When I say '),
    chip(rule.trigger),
    el('span', {}, ' expand to'),
    el('div', { class: 'vocab-expansion truncate' }, rule.expansion.replace(/\s+/g, ' ')),
  );
}

function ruleTable(all: Rule[]): HTMLElement {
  const kind = { words: 'word', fixes: 'fix', snippets: 'snippet' }[filter as 'words'] as Rule['kind'] | undefined;
  const needle = query.trim().toLowerCase();
  const rows = all
    .filter((rule) => filter === 'all' || rule.kind === kind)
    .filter((rule) => needle.length === 0 || ruleText(rule).toLowerCase().includes(needle))
    .sort((a, b) => b.uses - a.uses);

  if (all.filter((rule) => filter === 'all' || rule.kind === kind).length === 0) return emptyState();
  if (rows.length === 0) return el('p', { class: 'muted vocab-none' }, 'No rules match.');

  const showType = filter === 'all';
  const table = el(
    'div',
    { class: `vocab-table${showType ? ' with-type' : ''}`, role: 'list' } as never,
    el(
      'div',
      { class: 'vocab-head', 'aria-hidden': 'true' as never },
      showType ? el('span', {}, 'Type') : null,
      el('span', {}, 'Rule'),
      el('span', { class: 'vocab-uses' }, 'Uses'),
      el('span', {}),
    ),
    ...rows.map((rule) => ruleRow(rule, showType)),
  );
  table.addEventListener('keydown', (event) => {
    if (event.key !== 'ArrowDown' && event.key !== 'ArrowUp') return;
    const items = [...table.querySelectorAll<HTMLElement>('.vocab-row')];
    const at = items.findIndex((row) => row === document.activeElement || row.contains(document.activeElement));
    if (at < 0) return;
    const next = items[at + (event.key === 'ArrowDown' ? 1 : -1)];
    if (!next) return;
    event.preventDefault();
    items.forEach((row) => (row.tabIndex = -1));
    next.tabIndex = 0;
    next.focus();
  });
  (table.querySelector('.vocab-row') as HTMLElement | null)?.setAttribute('tabindex', '0');
  return table;
}

function ruleRow(rule: Rule, showType: boolean): HTMLElement {
  const paused = rule.kind === 'fix' && !rule.enabled;
  const actions = el('div', { class: 'vocab-actions' });
  if (rule.kind === 'fix') {
    if (paused) actions.append(el('span', { class: 'vocab-paused' }, 'Paused'));
    actions.append(
      el(
        'button',
        { class: 'btn btn-secondary btn-sm vocab-hover', type: 'button', onclick: () => void setPaused(rule.id, rule.enabled) } as never,
        paused ? 'Resume' : 'Pause',
      ),
    );
  }
  actions.append(
    el(
      'button',
      {
        class: 'icon-btn vocab-hover',
        type: 'button',
        'aria-label': 'Remove',
        title: 'Remove',
        onclick: () => void removeRule(rule),
      } as never,
      icon(ICONS.close, 15),
    ),
  );
  return el(
    'div',
    { class: `vocab-row${paused ? ' is-paused' : ''}`, role: 'listitem', tabIndex: -1 } as never,
    showType ? el('span', { class: 'vocab-type' }, KIND_LABEL[rule.kind]) : null,
    ruleSentence(rule),
    el('span', { class: 'vocab-uses tnum' }, fmt(rule.uses)),
    actions,
  );
}

function emptyState(): HTMLElement {
  const copy = {
    all: ['No rules yet', 'Add words, fixes and snippets so Useful Voice writes things your way.', 'Add a word'],
    words: ['No words yet', 'Add names and terms Useful Voice should spell your way.', 'Add word'],
    fixes: ['No fixes yet', 'A fix rewrites what it hears into what you meant.', 'Add fix'],
    snippets: ['No snippets yet', 'A snippet types a longer text when you say its trigger.', 'Add snippet'],
    suggestions: ['', '', ''],
  }[filter];
  return el(
    'div',
    { class: 'empty-state' },
    el('h3', {}, copy[0]),
    el('p', {}, copy[1]),
    el(
      'div',
      { class: 'vocab-empty-action' },
      el(
        'button',
        {
          class: 'btn btn-primary',
          type: 'button',
          onclick: () => {
            const inputs = document.querySelectorAll<HTMLInputElement>('.vocab-add .field-input');
            // A word has only "write"; a fix or snippet starts at "say".
            (filter === 'words' ? inputs[1] : inputs[0])?.focus();
          },
        } as never,
        copy[2],
      ),
    ),
  );
}

// ---- Suggestions ------------------------------------------------------

function suggestionCards(memory: MemorySnapshotDTO): HTMLElement[] {
  if (memory.suggestions.length === 0) {
    return [
      el(
        'div',
        { class: 'empty-state' },
        el('h3', {}, 'No suggestions yet'),
        el('p', {}, 'When you correct the same words in your dictations, Useful Voice offers to remember the fix.'),
      ),
    ];
  }
  return memory.suggestions.map((suggestion) =>
    el(
      'div',
      { class: 'vocab-card' },
      el(
        'p',
        { class: 'vocab-card-title' },
        'You corrected ',
        chipQuote(suggestion.observed),
        ' to ',
        chipQuote(suggestion.corrected),
        ` ${fmt(suggestion.evidenceCount)} ${suggestion.evidenceCount === 1 ? 'time' : 'times'}`,
      ),
      el(
        'div',
        { class: 'inline' },
        el('button', { class: 'btn btn-primary', type: 'button', onclick: () => void acceptSuggestion(suggestion.id) } as never, 'Add fix'),
        el('button', { class: 'btn btn-ghost', type: 'button', onclick: () => void dismissSuggestion(suggestion.id) } as never, 'Dismiss'),
      ),
    ),
  );
}

function chipQuote(text: string): HTMLElement {
  return el('span', { class: 'vocab-quote', dir: 'auto' }, `“${text}”`);
}

// ---- Actions ----------------------------------------------------------

async function setPaused(id: string, currentlyEnabled: boolean): Promise<void> {
  await api.setReplacementEnabled(id, !currentlyEnabled);
  await refresh();
  render();
}

async function removeRule(rule: Rule): Promise<void> {
  if (rule.kind === 'word') await api.removeTerm(rule.id);
  else if (rule.kind === 'fix') await api.removeReplacement(rule.id);
  else await api.removeSnippet(rule.id);
  await refresh();
  render();
}

async function acceptSuggestion(id: string): Promise<void> {
  await api.acceptSuggestion(id);
  await refresh();
  setNotice('success', 'Fix added. It applies from your next dictation.');
}

async function dismissSuggestion(id: string): Promise<void> {
  await api.dismissSuggestion(id);
  await refresh();
  render();
}

// ---- Header: More menu (backup and CSV) -------------------------------

export function headerActionsForVocabulary(): HTMLElement[] {
  const wrap = el('div', { class: 'vocab-more' });
  const button = el('button', {
    class: 'btn btn-ghost',
    type: 'button',
    'aria-haspopup': 'menu',
    'aria-expanded': 'false',
    'aria-label': 'More',
  } as never, icon(MORE_ICON, 18));
  const menu = el('div', { class: 'vocab-menu', role: 'menu', hidden: true } as never);

  const items: Array<[string, () => Promise<{ ok: boolean; message: string }>]> = [
    ['Export backup', () => api.exportBackup()],
    ['Import backup', () => api.importBackup()],
    ['Export words as CSV', () => api.exportCsv('terms')],
    ['Export fixes as CSV', () => api.exportCsv('fixes')],
  ];
  const close = (): void => {
    menu.hidden = true;
    button.setAttribute('aria-expanded', 'false');
    document.removeEventListener('pointerdown', onOutside, true);
  };
  const onOutside = (event: Event): void => {
    if (!wrap.contains(event.target as Node)) close();
  };
  for (const [label, run] of items) {
    menu.append(
      el(
        'button',
        {
          class: 'vocab-menu-item',
          type: 'button',
          role: 'menuitem',
          onclick: () => {
            close();
            void run().then(async (result) => {
              if (label === 'Import backup' && result.ok) await refresh();
              setNotice(result.ok ? 'success' : 'danger', result.message);
            });
          },
        } as never,
        label,
      ),
    );
  }
  button.addEventListener('click', () => {
    if (!menu.hidden) return close();
    menu.hidden = false;
    button.setAttribute('aria-expanded', 'true');
    document.addEventListener('pointerdown', onOutside, true);
    (menu.querySelector('.vocab-menu-item') as HTMLElement).focus();
  });
  menu.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') {
      close();
      button.focus();
    }
    if (event.key !== 'ArrowDown' && event.key !== 'ArrowUp') return;
    const entries = [...menu.querySelectorAll<HTMLElement>('.vocab-menu-item')];
    const at = entries.indexOf(document.activeElement as HTMLElement);
    event.preventDefault();
    entries[(at + (event.key === 'ArrowDown' ? 1 : -1) + entries.length) % entries.length]!.focus();
  });
  wrap.append(button, menu);
  return [wrap];
}
