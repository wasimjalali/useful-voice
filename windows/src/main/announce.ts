import { app } from 'electron';
import { hudLabel, type HudView } from '../core/hudModel.js';

/**
 * Tells a screen reader what the HUD is doing.
 *
 * The HUD is a non-activating window: it is never focused, so nothing in it is read on
 * its own. Windows has UI Automation notifications (`UiaRaiseNotificationEvent`) for
 * exactly this, but Electron exposes no API for them and a native addon is out of scope
 * here (the app ships none). The documented route Electron does offer is the web
 * content's own accessibility tree: an `aria-live` region, which Chromium maps to UIA
 * live-region events once an assistive technology has attached.
 *
 * So the main process decides what to say and when (this file), and a live region in a
 * window (`renderer/components/announcer.ts`) says it. The text goes to the main window
 * when that has focus, because that is where a screen reader user is reading, and to
 * the HUD window otherwise. What is not possible is announcing to a screen reader that
 * ignores live regions in an unfocused window; there is no way around that without UIA.
 */

export type AnnounceSink = (text: string, urgency: 'polite' | 'assertive') => void;

export class Announcer {
  private lastKey = '';

  constructor(private readonly sink: AnnounceSink) {}

  /** Chromium turns accessibility support on only once an assistive technology is detected. */
  get assistiveTechnologyDetected(): boolean {
    return app.isAccessibilitySupportEnabled();
  }

  /**
   * Announce a HUD view change. Called for every new view and for updates of the same
   * view; only a change of what would be said is spoken, so the ticking timer is silent.
   */
  hud(view: HudView | null): void {
    if (!view) {
      this.lastKey = '';
      return;
    }
    const text = spoken(view);
    // The recording timer ticks every second and is not announced: the label on the HUD
    // carries "Recording, 0:12" for anyone who explores it, and speaking it would talk
    // over the person dictating.
    const key = view.kind === 'recording' ? `recording|${view.stopsIn !== undefined}` : `${view.kind}|${text}`;
    if (key === this.lastKey) return;
    this.lastKey = key;
    this.sink(text, view.kind === 'error' ? 'assertive' : 'polite');
  }
}

function spoken(view: HudView): string {
  switch (view.kind) {
    case 'recording':
      return view.stopsIn !== undefined ? `Stops in ${view.stopsIn} seconds` : 'Recording';
    case 'error':
      // The full sentence, not the capsule's short title, plus the fix as it is offered.
      return view.error.message;
    default:
      return hudLabel(view);
  }
}
