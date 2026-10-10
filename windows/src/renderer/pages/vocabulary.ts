import { api } from '../api.js';
import { el, icon, ICONS } from '../components/dom.js';
import { state, render, setNotice, refresh } from '../shell.js';
import type { MemorySnapshotDTO } from '../../preload/types.js';

// ---- Dictionary -------------------------------------------------------

export function renderDictionary(): Node {
  const page = el('div', { class: 'page page-wide' });
  const memory = state.memory;
  if (!memory) return el('div', { class: 'muted' }, 'Loading…');

  // Warn when the keyterm list had to be trimmed: the user should know their
  // dictionary is not fully active rather than silently getting worse results.
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
          `${report.dropped + report.rejected} of your entries are not being sent to the recogniser `
          + `(the limit is ${report.limit} per request). The highest-priority entries are used first.`,
        ),
      ),
    );
  }

  const segmented = el(
    'div',
    { class: 'segmented' },
    ...([
      ['words', `Words (${memory.terms.length})`],
      ['fixes', `Corrections (${memory.replacements.length})`],
      ['snippets', `Shortcuts (${memory.snippets.length})`],
    ] as const).map(([id, label]) =>
      el(
        'button',
        {
          type: 'button',
          'aria-selected': state.dictionarySection === id ? 'true' : 'false',
          onclick: () => {
            state.dictionarySection = id;
            render();
          },
        } as never,
        label,
      ),
    ),
  );
  page.append(segmented);

  if (state.dictionarySection === 'words') page.append(wordsSection(memory));
  else if (state.dictionarySection === 'fixes') page.append(fixesSection(memory));
  else page.append(snippetsSection(memory));

  if (memory.suggestions.length > 0) page.append(suggestionsSection(memory));

  return page;
}

function wordsSection(memory: MemorySnapshotDTO): Node {
  const card = el('div', { class: 'card card-pad' });
  card.append(el('p', { class: 'section-label' }, 'Words'));

  const wordInput = el('input', {
    class: 'field-input',
    placeholder: 'Kubernetes',
    'aria-label': 'Word or phrase',
  } as never);
  const soundsInput = el('input', {
    class: 'field-input',
    placeholder: 'kubernets',
    'aria-label': 'Sounds like',
  } as never);

  const addRow = el(
    'div',
    { class: 'grid-3', style: 'margin-top:12px' as never },
    el('div', { class: 'field' }, el('label', { class: 'field-label' }, 'Word or phrase'), wordInput),
    el(
      'div',
      { class: 'field' },
      el('label', { class: 'field-label' }, 'Also sounds like'),
      soundsInput,
      el('span', { class: 'field-hint' }, 'What the recogniser often writes instead.'),
    ),
    el(
      'div',
      { class: 'field', style: 'justify-content:flex-end' as never },
      el(
        'button',
        {
          class: 'btn btn-primary',
          type: 'button',
          onclick: () => void addWord(wordInput, soundsInput),
        } as never,
        icon(ICONS.plus, 14),
        'Add word',
      ),
    ),
  );
  card.append(addRow);

  if (memory.terms.length === 0) {
    card.append(
      el(
        'p',
        { class: 'muted', style: 'margin:14px 0 0;line-height:1.55' as never },
        'No words yet. Add the names, products and jargon you use. The recogniser is told about them before each dictation.',
      ),
    );
    return card;
  }

  card.append(
    el(
      'div',
      { class: 'list', style: 'margin-top:14px' as never },
      ...memory.terms.map((term) =>
        el(
          'div',
          { class: 'list-row' },
          el(
            'div',
            { class: 'list-row-main' },
            el('div', { class: 'list-row-title' }, term.phrase),
            term.pronunciations.length > 0 || term.usageCount > 0
              ? el(
                  'div',
                  { class: 'list-row-sub inline wrap' },
                  ...(term.pronunciations.length > 0
                    ? [el('span', {}, `sounds like “${term.pronunciations.join('”, “')}”`)]
                    : []),
                  ...(term.usageCount > 0
                    ? [el('span', { class: 'chip chip-mono tnum' }, `used ${term.usageCount}×`)]
                    : []),
                )
              : null,
          ),
          el(
            'div',
            { class: 'list-row-actions' },
            el(
              'button',
              {
                class: 'icon-btn',
                type: 'button',
                title: 'Remove',
                onclick: () => void removeWord(term.id, term.phrase),
              } as never,
              icon(ICONS.trash, 15),
            ),
          ),
        ),
      ),
    ),
  );
  return card;
}

function fixesSection(memory: MemorySnapshotDTO): Node {
  const card = el('div', { class: 'card card-pad' });
  card.append(el('p', { class: 'section-label' }, 'Corrections'));
  card.append(
    el(
      'p',
      { class: 'muted', style: 'margin:8px 0 0;line-height:1.55' as never },
      'Replace what the recogniser heard with what you meant. Matched on whole words only.',
    ),
  );

  const heard = el('input', { class: 'field-input', placeholder: 'cloud code', 'aria-label': 'Heard' } as never);
  const write = el('input', { class: 'field-input', placeholder: 'Claude Code', 'aria-label': 'Write' } as never);
  card.append(
    el(
      'div',
      { class: 'grid-3', style: 'margin-top:12px' as never },
      el('div', { class: 'field' }, el('label', { class: 'field-label' }, 'When it hears'), heard),
      el('div', { class: 'field' }, el('label', { class: 'field-label' }, 'Write instead'), write),
      el(
        'div',
        { class: 'field', style: 'justify-content:flex-end' as never },
        el(
          'button',
          {
            class: 'btn btn-primary',
            type: 'button',
            onclick: () => void addFix(heard, write),
          } as never,
          icon(ICONS.plus, 14),
          'Add correction',
        ),
      ),
    ),
  );

  if (memory.replacements.length > 0) {
    card.append(
      el(
        'div',
        { class: 'list', style: 'margin-top:14px' as never },
        ...memory.replacements.map((rule) =>
          el(
            'div',
            { class: 'list-row' },
            el(
              'div',
              { class: 'list-row-main' },
              el(
                'div',
                { class: 'list-row-title' },
                el('span', { class: 'mono' }, rule.match),
                el('span', { class: 'muted' }, '  →  '),
                el('span', {}, rule.replacement),
              ),
              rule.usageCount > 0
                ? el('div', { class: 'list-row-sub' }, `applied ${rule.usageCount}×`)
                : null,
            ),
            el(
              'div',
              { class: 'list-row-actions' },
              el(
                'button',
                {
                  class: 'switch',
                  type: 'button',
                  role: 'switch',
                  'aria-checked': rule.isEnabled ? 'true' : 'false',
                  title: rule.isEnabled ? 'Disable' : 'Enable',
                  onclick: () => void toggleFix(rule.id, !rule.isEnabled),
                } as never,
              ),
              el(
                'button',
                {
                  class: 'icon-btn',
                  type: 'button',
                  title: 'Remove',
                  onclick: () => void removeFix(rule.id),
                } as never,
                icon(ICONS.trash, 15),
              ),
            ),
          ),
        ),
      ),
    );
  }
  return card;
}

function snippetsSection(memory: MemorySnapshotDTO): Node {
  const card = el('div', { class: 'card card-pad' });
  card.append(el('p', { class: 'section-label' }, 'Shortcuts'));
  card.append(
    el(
      'p',
      { class: 'muted', style: 'margin:8px 0 0;line-height:1.55' as never },
      'Say a short trigger and the full text is written instead.',
    ),
  );

  const trigger = el('input', { class: 'field-input', placeholder: 'my signature', 'aria-label': 'Trigger' } as never);
  const expansion = el('input', {
    class: 'field-input',
    placeholder: 'Best regards,\nWasim',
    'aria-label': 'Expansion',
  } as never);
  card.append(
    el(
      'div',
      { class: 'grid-3', style: 'margin-top:12px' as never },
      el('div', { class: 'field' }, el('label', { class: 'field-label' }, 'When you say'), trigger),
      el('div', { class: 'field' }, el('label', { class: 'field-label' }, 'Write'), expansion),
      el(
        'div',
        { class: 'field', style: 'justify-content:flex-end' as never },
        el(
          'button',
          {
            class: 'btn btn-primary',
            type: 'button',
            onclick: () => void addSnippet(trigger, expansion),
          } as never,
          icon(ICONS.plus, 14),
          'Add shortcut',
        ),
      ),
    ),
  );

  if (memory.snippets.length > 0) {
    card.append(
      el(
        'div',
        { class: 'list', style: 'margin-top:14px' as never },
        ...memory.snippets.map((snippet) =>
          el(
            'div',
            { class: 'list-row' },
            el(
              'div',
              { class: 'list-row-main' },
              el('div', { class: 'list-row-title mono' }, snippet.trigger),
              el('div', { class: 'list-row-sub truncate' }, snippet.expansion),
            ),
            el(
              'div',
              { class: 'list-row-actions' },
              el(
                'button',
                {
                  class: 'icon-btn',
                  type: 'button',
                  title: 'Remove',
                  onclick: () => void removeSnippet(snippet.id),
                } as never,
                icon(ICONS.trash, 15),
              ),
            ),
          ),
        ),
      ),
    );
  }
  return card;
}

function suggestionsSection(memory: MemorySnapshotDTO): Node {
  const card = el('div', { class: 'card card-pad' });
  card.append(el('p', { class: 'section-label' }, 'Suggested corrections'));
  card.append(
    el(
      'p',
      { class: 'muted', style: 'margin:8px 0 0;line-height:1.55' as never },
      'These appeared repeatedly in your edits. Nothing is applied until you accept it.',
    ),
  );
  card.append(
    el(
      'div',
      { class: 'list', style: 'margin-top:12px' as never },
      ...memory.suggestions.map((suggestion) =>
        el(
          'div',
          { class: 'list-row' },
          el(
            'div',
            { class: 'list-row-main' },
            el(
              'div',
              { class: 'list-row-title' },
              el('span', { class: 'mono' }, suggestion.observed),
              el('span', { class: 'muted' }, '  →  '),
              suggestion.corrected,
            ),
            el('div', { class: 'list-row-sub' }, `seen ${suggestion.evidenceCount}×`),
          ),
          el(
            'div',
            { class: 'list-row-actions' },
            el(
              'button',
              {
                class: 'btn btn-secondary btn-sm',
                type: 'button',
                onclick: () => void acceptSuggestion(suggestion.id),
              } as never,
              'Accept',
            ),
            el(
              'button',
              {
                class: 'btn btn-ghost btn-sm',
                type: 'button',
                onclick: () => void dismissSuggestion(suggestion.id),
              } as never,
              'Dismiss',
            ),
          ),
        ),
      ),
    ),
  );
  return card;
}

// ---- Actions ----------------------------------------------------------

async function addWord(wordInput: HTMLInputElement, soundsInput: HTMLInputElement): Promise<void> {
  const phrase = wordInput.value.trim();
  if (phrase.length === 0) {
    setNotice('danger', 'Enter a word or phrase first.');
    return;
  }
  await api.addTerm({
    phrase,
    soundAlike: soundsInput.value.trim() || undefined,
    language: state.settings?.languagePin ?? 'auto',
  });
  await refresh();
  setNotice('success', `Added “${phrase}”.`);
}

async function removeWord(id: string, phrase: string): Promise<void> {
  await api.removeTerm(id);
  await refresh();
  setNotice('success', `Removed “${phrase}”.`);
}

async function addFix(heard: HTMLInputElement, write: HTMLInputElement): Promise<void> {
  const match = heard.value.trim();
  const replacement = write.value.trim();
  if (match.length === 0 || replacement.length === 0) {
    setNotice('danger', 'Fill in both boxes, so the app knows what to replace and with what.');
    return;
  }
  await api.addReplacement({ match, replacement, language: state.settings?.languagePin ?? 'auto' });
  await refresh();
  setNotice('success', `“${match}” will be written as “${replacement}”.`);
}

async function toggleFix(id: string, isEnabled: boolean): Promise<void> {
  await api.setReplacementEnabled(id, isEnabled);
  await refresh();
  render();
}

async function removeFix(id: string): Promise<void> {
  await api.removeReplacement(id);
  await refresh();
  setNotice('success', 'Correction removed.');
}

async function addSnippet(trigger: HTMLInputElement, expansion: HTMLInputElement): Promise<void> {
  const triggerText = trigger.value.trim();
  const expansionText = expansion.value.trim();
  if (triggerText.length === 0 || expansionText.length === 0) {
    setNotice('danger', 'Fill in both boxes: what you say, and what should be written.');
    return;
  }
  await api.addSnippet({ trigger: triggerText, expansion: expansionText, language: state.settings?.languagePin ?? 'auto' });
  await refresh();
  setNotice('success', `Say “${triggerText}” to write your text.`);
}

async function removeSnippet(id: string): Promise<void> {
  await api.removeSnippet(id);
  await refresh();
  setNotice('success', 'Shortcut removed.');
}

async function acceptSuggestion(id: string): Promise<void> {
  await api.acceptSuggestion(id);
  await refresh();
  setNotice('success', 'Correction added. It will apply from your next dictation.');
}

async function dismissSuggestion(id: string): Promise<void> {
  await api.dismissSuggestion(id);
  await refresh();
  render();
}

// TEMP until merge: the real Vocabulary page replaces this.
export const renderVocabularyPage = renderDictionary;
