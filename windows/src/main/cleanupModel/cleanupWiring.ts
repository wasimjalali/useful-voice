import type { AppSettings } from '../../core/models.js';
import type { CleanupPort } from '../dictationService.js';
import {
  cleanupPortFor,
  createCleanupRuntime,
  preloadLanguage,
  type CleanupRuntime,
  type CleanupRuntimeOptions,
} from './cleanupRuntime.js';

/**
 * The one place the hidden S1-mini cleanup is wired into the app. `index.ts` calls
 * `wireCleanup` and `dictationSettings`, and `tests/cleanupFlagOff.test.ts` calls the same
 * two, so a change that makes the flag-off app behave differently (a port where there
 * should be none, a preload language that disagrees with the run) fails that test.
 */
export interface CleanupWiring {
  runtime: CleanupRuntime;
  /** Spread into the `DictationService` deps. Empty with the flag off, so the old rules call runs untouched. */
  serviceDeps: { cleanup?: CleanupPort };
}

export function wireCleanup(options: CleanupRuntimeOptions): CleanupWiring {
  const runtime = createCleanupRuntime(options);
  const port = cleanupPortFor(runtime);
  return { runtime, serviceDeps: port ? { cleanup: port } : {} };
}

/**
 * The settings a dictation runs with: the saved ones, except that during the first-run
 * sandbox the language chosen there stands in for the pin. The service reads its settings
 * through this, and the model preload takes its language from the same value, so the
 * preload and the run agree.
 */
export function dictationSettings(
  saved: AppSettings,
  firstRun: { sandbox: boolean; language: string | null | undefined },
): AppSettings {
  return firstRun.sandbox && firstRun.language ? { ...saved, languagePin: firstRun.language } : saved;
}

/** The language to preload the model for at hotkey down: undefined when it is not known before the audio. */
export function preloadLanguageFor(settings: AppSettings): string | undefined {
  return preloadLanguage(settings.languagePin);
}
