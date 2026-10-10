import { api } from './api.js';
import { startCapture, stopCapture, cancelCapture, isCapturing } from './components/capture.js';
import { el } from './components/dom.js';

// ---------------------------------------------------------------------------
// Recorder view (hidden): hosts audio capture only
// ---------------------------------------------------------------------------

export function mountRecorder(): void {
  document.body.classList.add('recorder');
  const root = document.getElementById('root');
  if (root) {
    root.append(el('div', { class: 'recorder-note' }, 'Audio capture host. This window is never shown.'));
  }

  api.onStartRecording(() => {
    void (async () => {
      try {
        await startCapture();
      } catch (error) {
        // Report the failure so the main process can show actionable advice
        // instead of waiting for a capture that will never arrive.
        await api.sendAudioError((error as Error).message);
      }
    })();
  });

  api.onStopRecording(() => {
    void (async () => {
      if (!isCapturing()) return;
      try {
        const result = await stopCapture();
        await api.sendAudio(result.wav, {
          durationSeconds: result.durationSeconds,
          peak: result.peak,
          hadSpeech: result.hadSpeech,
        });
      } catch (error) {
        await api.sendAudioError((error as Error).message);
        await cancelCapture();
      }
    })();
  });
}
