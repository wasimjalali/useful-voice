import { followTheme } from './components/theme.js';
import { loadFlags } from './components/flags.js';
import { mountHud } from './hud.js';
import * as notes from './pages/notes.js';
import * as vocabulary from './pages/vocabulary.js';
import * as insights from './pages/insights.js';
import * as settings from './pages/settings.js';
import * as stream from './pages/stream.js';
import { mountRecorder } from './recorder.js';
import { mountMain, type PageModule } from './shell.js';

/**
 * The renderer entry point.
 *
 * Three views share this bundle, selected by the `view` query parameter the main
 * process passes when it loads the page:
 *
 *   * `recorder` - hidden; exists solely to host microphone capture.
 *   * `hud`      - the small always-on-top recording pill.
 *   * `main`     - the application window.
 */

const view = new URLSearchParams(window.location.search).get('view') ?? 'main';

/** A page's optional `headerActionsFor<Page>` export. */
function actions(module: object, name: string): () => Node[] {
  const exported = (module as Record<string, unknown>)[name];
  return typeof exported === 'function' ? (exported as () => Node[]) : () => [];
}

followTheme();

if (view === 'recorder') mountRecorder();
else if (view === 'hud') mountHud();
else {
  const pages: Record<'stream' | 'notes' | 'vocabulary' | 'insights' | 'settings', PageModule> = {
    stream: { render: stream.renderStreamPage, headerActions: actions(stream, 'headerActionsForStream') },
    notes: { render: notes.renderNotesPage, headerActions: actions(notes, 'headerActionsForNotes') },
    vocabulary: { render: vocabulary.renderVocabularyPage, headerActions: actions(vocabulary, 'headerActionsForVocabulary') },
    insights: { render: insights.renderInsightsPage, headerActions: actions(insights, 'headerActionsForInsights') },
    settings: { render: settings.renderSettingsPage, headerActions: actions(settings, 'headerActionsForSettings') },
  };
  void loadFlags().then(() => mountMain(pages));
}
