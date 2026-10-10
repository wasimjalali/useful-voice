import { api } from '../api.js';
import { el, icon } from './dom.js';
import { micOff, MIC_SETTINGS_URL, type HealthInput } from './statusPopover.js';

/**
 * Window banners: one line under the stage header, one action. The most blocking
 * problem wins and banners never stack. The window stays usable under them.
 */

const WARN = 'M12 9v4M12 17h.01M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z';

interface Spec {
  tone: 'warn' | 'bad';
  lead: string;
  rest: string;
  action: { label: string; run: () => void };
}

export function pickBanner(input: HealthInput, goToEngine: () => void): Spec | null {
  const kind = input.lastError?.kind;
  if (micOff(input)) {
    return {
      tone: 'warn',
      lead: 'Microphone access is off.',
      rest: " Useful Voice can't hear you.",
      action: { label: 'Open settings', run: () => void api.openExternal(MIC_SETTINGS_URL) },
    };
  }
  if (!input.hasApiKey) {
    return { tone: 'warn', lead: 'No Deepgram key.', rest: ' Add one to start dictating.', action: { label: 'Add key', run: goToEngine } };
  }
  if (kind === 'keyRejected') {
    return {
      tone: 'bad',
      lead: 'Deepgram rejected your key.',
      rest: ' Check it and try again.',
      action: { label: 'Open Engine settings', run: goToEngine },
    };
  }
  if (kind === 'offline') {
    return {
      tone: 'warn',
      lead: "You're offline.",
      rest: ' Retry when you are back online.',
      action: { label: 'Retry last recording', run: () => void api.retryLast() },
    };
  }
  if (input.pasteBlocked) {
    return {
      tone: 'warn',
      lead: 'Windows blocked the paste.',
      rest: ' The app in front runs as administrator.',
      action: { label: 'Copy last transcript', run: () => void api.copyLastTranscript() },
    };
  }
  if (!input.saveStatus.ok) {
    return {
      tone: 'bad',
      lead: "Dictations aren't being saved.",
      rest: ` ${input.saveStatus.message ?? 'The data folder is full or read-only.'}`,
      action: { label: 'Show log', run: () => void api.showDiagnosticsLog() },
    };
  }
  return null;
}

export function createBanner(input: HealthInput, goToEngine: () => void): HTMLElement | null {
  const spec = pickBanner(input, goToEngine);
  if (!spec) return null;
  return el(
    'div',
    { class: `banner ${spec.tone}`, role: spec.tone === 'bad' ? 'alert' : 'status' } as never,
    icon(WARN, 16),
    el('span', { class: 'banner-text' }, el('b', {}, spec.lead), spec.rest),
    el('button', { class: 'btn btn-sm', type: 'button', onclick: spec.action.run } as never, spec.action.label),
  );
}
