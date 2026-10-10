import { nativeTheme } from 'electron';
import type { Appearance } from '../core/models.js';
import type { ResolvedTheme } from '../preload/types.js';

/**
 * The few theme colours the main process needs, because the OS draws them: the
 * window background shown before the page paints and the caption-button overlay.
 * They are the `--canvas` and `--ink` values of the renderer's token blocks
 * (`renderer/styles/tokens.css`), so the strip at the top of the window and the
 * buttons on it match the page behind them.
 */
const THEME_COLORS: Record<ResolvedTheme, { canvas: string; ink: string }> = {
  light: { canvas: '#f8f8f8', ink: '#171717' },
  dark: { canvas: '#0f0f0f', ink: '#ededed' },
};

/** Height of the canvas strip that carries the caption buttons, in CSS pixels. */
export const TITLE_BAR_HEIGHT = 32;

/** The theme the window is drawn in right now, with `system` already resolved. */
export function resolvedTheme(): ResolvedTheme {
  return nativeTheme.shouldUseDarkColors ? 'dark' : 'light';
}

/** Make Chromium and the OS chrome follow the user's choice. */
export function applyAppearance(appearance: Appearance): void {
  nativeTheme.themeSource = appearance;
}

export function canvasColor(theme: ResolvedTheme): string {
  return THEME_COLORS[theme].canvas;
}

export function titleBarOverlayFor(theme: ResolvedTheme): { color: string; symbolColor: string; height: number } {
  return { color: THEME_COLORS[theme].canvas, symbolColor: THEME_COLORS[theme].ink, height: TITLE_BAR_HEIGHT };
}
