import { touchedSince, type HeldSession, type MediaEffects, type MediaSession } from '../core/media/mediaPausePolicy.js';

/**
 * A scripted media player for the Playwright suite, installed only under `--e2e`: nothing
 * real is ever paused. It keeps a status and a timeline per session, does what the Windows
 * scripts do (list what is Playing, pause it, play what is still Paused and untouched) and
 * records every call in order.
 */
export type FakeStatus = 'Playing' | 'Paused';

interface FakeSession {
  status: FakeStatus;
  position: number;
  updated: number;
}

export class FakeMedia implements MediaEffects {
  private readonly sessions = new Map<string, FakeSession>();
  readonly calls: string[] = [];

  set(sessions: Record<string, FakeStatus>): void {
    this.sessions.clear();
    this.calls.length = 0;
    for (const [id, status] of Object.entries(sessions)) this.sessions.set(id, { status, position: 30_000, updated: 1_000_000 });
  }

  /** The person scrubs a session: its position moves. */
  scrub(id: string, byMs: number): void {
    const session = this.sessions.get(id);
    if (session) session.position += byMs;
  }

  async listPlaying(): Promise<MediaSession[]> {
    this.calls.push('list');
    return [...this.sessions]
      .filter(([, session]) => session.status === 'Playing')
      .map(([id, session]) => ({ id, position: session.position, updated: session.updated }));
  }

  async pause(ids: string[]): Promise<MediaSession[]> {
    this.calls.push(`pause:${ids.join(',')}`);
    const paused: MediaSession[] = [];
    for (const id of ids) {
      const session = this.sessions.get(id);
      if (!session || session.status !== 'Playing') continue;
      session.status = 'Paused';
      paused.push({ id, position: session.position, updated: session.updated });
    }
    return paused;
  }

  async resume(held: HeldSession[]): Promise<void> {
    this.calls.push(`resume:${held.map((session) => session.id).join(',')}`);
    for (const { id, settled } of held) {
      const session = this.sessions.get(id);
      if (session && session.status === 'Paused' && !touchedSince(settled, session)) session.status = 'Playing';
    }
  }

  snapshot(): Record<string, FakeStatus> {
    return Object.fromEntries([...this.sessions].map(([id, session]) => [id, session.status]));
  }
}
