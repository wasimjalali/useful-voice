import { followTheme } from './components/theme.js';
import { mountHud } from './hud.js';
import { renderDictionary } from './pages/vocabulary.js';
import { notesHeaderActions, renderNotes, undoDeleteNote } from './pages/notes.js';
import { mountRecorder } from './recorder.js';
import { renderSettings } from './pages/settings.js';
import { historyHeaderActions, homeHeaderActions, renderHistory, renderHome } from './pages/stream.js';
import { mountMain } from './shell.js';

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

followTheme();

if (view === 'recorder') mountRecorder();
else if (view === 'hud') mountHud();
else {
  mountMain(
    {
      home: { render: renderHome, headerActions: homeHeaderActions },
      dictionary: { render: renderDictionary, headerActions: () => [] },
      history: { render: renderHistory, headerActions: historyHeaderActions },
      notes: { render: renderNotes, headerActions: notesHeaderActions },
      settings: { render: renderSettings, headerActions: () => [] },
    },
    undoDeleteNote,
  );
}
