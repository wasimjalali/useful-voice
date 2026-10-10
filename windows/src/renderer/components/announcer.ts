import { api } from '../api.js';
import { el } from './dom.js';

/**
 * Two visually hidden live regions that speak what the main process announces.
 *
 * The HUD is never focused, and Electron has no UI Automation notification API (see
 * `main/announce.ts`), so the documented route to a screen reader is an `aria-live`
 * region in the web content. The main process sends `app:announce` to the window the
 * user is in. Every window that can be that window calls this once.
 */
export function mountAnnouncer(): void {
  const polite = el('div', { class: 'sr-only', role: 'status', 'aria-live': 'polite', 'aria-atomic': 'true' });
  const assertive = el('div', { class: 'sr-only', role: 'alert', 'aria-live': 'assertive', 'aria-atomic': 'true' });
  document.body.append(polite, assertive);

  api.onAnnounce((text, urgency) => {
    const region = urgency === 'assertive' ? assertive : polite;
    // Cleared first so the same sentence twice in a row is spoken twice.
    region.textContent = '';
    window.setTimeout(() => {
      region.textContent = text;
    }, 50);
  });
}
