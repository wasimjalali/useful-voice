import { api } from '../api.js';

/**
 * Keep `data-theme` on <html> in step with the theme the main process resolved.
 *
 * `theme-boot.js` has already set it from the URL before first paint. This covers
 * what that cannot: the user changing Appearance, and Windows flipping between light
 * and dark while Appearance is System. Both arrive as `app:theme` from the main
 * process, which follows `nativeTheme`.
 */
export function followTheme(): void {
  const apply = (theme: 'light' | 'dark'): void => {
    document.documentElement.dataset.theme = theme;
  };
  api.onThemeChanged(apply);
  // The theme may have changed between the page being loaded and this subscription.
  void api.getTheme().then(apply);
}
