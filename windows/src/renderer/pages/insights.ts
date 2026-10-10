// TEMP until merge: the real Insights page replaces this file.
import { el } from '../components/dom.js';

export function renderInsightsPage(): HTMLElement {
  return el('div', { class: 'page' }, el('p', {}, 'Insights arrive on Windows in a later update.'));
}
