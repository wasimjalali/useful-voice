import type { MediaEffects } from '../core/media/mediaPausePolicy.js';

/**
 * A scripted media player for the Playwright suite, installed only under `--e2e`: nothing
 * real is ever paused. It keeps a status per session, does what the Windows scripts do
 * (pause what is Playing, play what is still Paused) and records every call in order.
 */
export type FakeStatus = 'Playing' | 'Paused';

export class FakeMedia implements MediaEffects {
  private readonly sessions = new Map<string, FakeStatus>();
  readonly calls: string[] = [];

  set(sessions: Record<string, FakeStatus>): void {
    this.sessions.clear();
    this.calls.length = 0;
    for (const [id, status] of Object.entries(sessions)) this.sessions.set(id, status);
  }

  async pausePlaying(): Promise<string[]> {
    this.calls.push('pause');
    const paused: string[] = [];
    for (const [id, status] of this.sessions) {
      if (status !== 'Playing') continue;
      this.sessions.set(id, 'Paused');
      paused.push(id);
    }
    return paused;
  }

  async resume(ids: string[]): Promise<void> {
    this.calls.push(`resume:${ids.join(',')}`);
    for (const id of ids) if (this.sessions.get(id) === 'Paused') this.sessions.set(id, 'Playing');
  }

  snapshot(): Record<string, FakeStatus> {
    return Object.fromEntries(this.sessions);
  }
}
