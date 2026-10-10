import { api } from './api.js';
import { el, icon } from './components/dom.js';

// ---------------------------------------------------------------------------
// HUD view
// ---------------------------------------------------------------------------

export function mountHud(): void {
  document.body.classList.add('hud');
  const root = document.getElementById('root');
  if (!root) return;

  let startedAt = Date.now();
  let state: string = 'idle';

  const dot = el('span', { class: 'hud-dot' });
  const stateLabel = el('span', { class: 'hud-state' }, 'Listening');
  const meterFill = el('span', { class: 'hud-meter-fill' });
  const meter = el('span', { class: 'hud-meter' }, meterFill);
  const time = el('span', { class: 'hud-time' }, '0:00');

  const pill = el('div', { class: 'hud-pill' }, dot, stateLabel, meter, time);
  root.append(pill);

  const timer = window.setInterval(() => {
    if (state !== 'recording') return;
    const seconds = Math.floor((Date.now() - startedAt) / 1000);
    time.textContent = `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, '0')}`;
    // The cap is enforced in the main process; the HUD just stops counting.
  }, 250);

  window.addEventListener('beforeunload', () => window.clearInterval(timer));

  api.onLevel((level) => {
    meterFill.style.width = `${Math.round(Math.max(0, Math.min(1, level)) * 100)}%`;
  });

  api.onState((event) => {
    state = event.state;
    if (event.state === 'recording') {
      startedAt = Date.now();
      pill.classList.remove('hidden');
      stateLabel.textContent = 'Listening';
      dot.className = 'hud-dot busy';
      meter.classList.remove('hidden');
      time.classList.remove('hidden');
    } else if (event.state === 'transcribing') {
      stateLabel.textContent = 'Transcribing';
      dot.className = 'hud-dot working busy';
      meterFill.style.width = '100%';
      time.classList.add('hidden');
    } else if (event.state === 'delivering') {
      stateLabel.textContent = 'Pasting';
      dot.className = 'hud-dot working';
    } else if (event.state === 'error') {
      root.replaceChildren(
        el(
          'div',
          { class: 'hud-error' },
          icon('M12 9v4M12 17h.01M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z', 16),
          el('span', {}, event.message ?? 'Something went wrong.'),
        ),
      );
    }
  });
}
