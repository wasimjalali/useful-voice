import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';

/**
 * The renderer end of the data-change contract, checked statically.
 *
 * `src/renderer/renderer.ts` needs a DOM and a live preload bridge, so it cannot be
 * imported here — nothing in this file executes it. What it does check is the wiring
 * shape that the fix depends on, because that shape is what a later refactor is most
 * likely to break without noticing:
 *
 *   - the three change subscriptions are registered inside `mountMain()`, so the hidden
 *     recorder and HUD windows, which run the same bundle, do not subscribe and refetch
 *     collections they never display;
 *   - the background refetch repaints only when the page is one that shows the data,
 *     and only after checking that no half-typed form would be clobbered;
 *   - Home is included where the collections it displays change.
 *
 * Honest limits: this proves the shape of the code, not its behaviour. It cannot show
 * that a handler fires, that a repaint preserves a caret, or that the guard's selector
 * matches the inputs the dictionary page actually renders. Only a running Windows build
 * can show that.
 */

const here = path.dirname(fileURLToPath(import.meta.url));
const rendererSource = readFileSync(path.resolve(here, '../src/renderer/renderer.ts'), 'utf8');

/**
 * The text of a top-level declaration, up to the first closing brace in column 0.
 *
 * Throws rather than returning an empty string: a silent miss here would make every
 * assertion below vacuously true, which is the failure mode this whole file exists to
 * avoid.
 */
function declarationText(declaration: string): string {
  const start = rendererSource.indexOf(declaration);
  if (start === -1) throw new Error(`renderer.ts no longer declares: ${declaration}`);
  const end = rendererSource.indexOf('\n}\n', start);
  if (end === -1) throw new Error(`could not find the end of: ${declaration}`);
  return rendererSource.slice(start, end);
}

describe('change subscriptions live in the main view', () => {
  const mountMain = declarationText('function mountMain(');

  it('registers all three change subscriptions', () => {
    for (const method of ['api.onHistoryChanged(', 'api.onMemoryChanged(', 'api.onNotesChanged(']) {
      expect(mountMain, `${method} must be called by the main view`).toContain(method);
    }
  });

  it('does not register them at module scope for the recorder and HUD windows', () => {
    // The recorder and HUD views load the same bundle. A subscription registered
    // outside `mountMain` would have those windows refetching history, memory and notes
    // on every broadcast, for a UI that shows none of it.
    for (const method of ['api.onHistoryChanged(', 'api.onMemoryChanged(', 'api.onNotesChanged(']) {
      const inMain = mountMain.includes(method);
      const total = rendererSource.split(method).length - 1;
      expect(total, `${method} must be called exactly once, inside mountMain`).toBe(1);
      expect(inMain, `${method} must be inside mountMain`).toBe(true);
    }
  });
});

describe('the background refetch', () => {
  const loadIfActive = declarationText('async function loadIfActive(');

  it('refetches only for a page that shows the data', () => {
    expect(loadIfActive).toContain('if (!visible.includes(state.page)) return;');
  });

  it('repaints only after checking that nothing typed would be lost', () => {
    const guard = loadIfActive.indexOf('if (hasUnsubmittedInput()) return;');
    const repaint = loadIfActive.indexOf('render();');
    expect(guard, 'the guard must be present').toBeGreaterThanOrEqual(0);
    expect(repaint, 'the refetch must repaint something').toBeGreaterThanOrEqual(0);
    expect(guard, 'the guard must come before the repaint').toBeLessThan(repaint);
  });

  it('keeps the refetch failure from replacing the page', () => {
    // A background fetch that throws must not paint an error over a working page.
    expect(loadIfActive).toContain('catch (error)');
    expect(loadIfActive).toContain('console.warn');
  });

  it('covers Home, which shows the same counters and recent dictations', () => {
    // Home is the screen in front of the user while they dictate, so leaving it out
    // would leave the most visible half of the stale-list bug in place.
    const mountMain = declarationText('function mountMain(');
    expect(mountMain).toContain("loadIfActive(['home', 'history']");
    expect(mountMain).toContain("loadIfActive(['home', 'dictionary']");
    expect(mountMain).toContain("loadIfActive('notes'");
  });
});

describe('the mid-edit guard', () => {
  const guard = declarationText('function hasUnsubmittedInput(');

  it('applies to the dictionary page, whose forms keep their text in the DOM', () => {
    // The words, corrections and shortcuts forms read their inputs when the button is
    // pressed and never mirror them into `state`, so a repaint drops a half-typed entry.
    expect(guard).toContain("if (state.page !== 'dictionary') return false;");
    expect(guard).toContain('.stage-body .field-input');
  });

  it('counts only non-empty input, so an untouched page still repaints', () => {
    expect(guard).toContain('input.value.trim().length > 0');
  });
});
