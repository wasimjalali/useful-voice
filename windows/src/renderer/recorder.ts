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

  api.onStartRecording((token) => {
    void (async () => {
      try {
        const started = await startCapture(token, (message) => {
          void api.sendAudioError(message, token);
        });
        // A discarded start has nothing to report: the main process already moved on.
        if (started) await api.sendAudioStarted(token);
      } catch (error) {
        // Report the failure so the main process can show actionable advice
        // instead of waiting for a capture that will never arrive.
        await api.sendAudioError((error as Error).message, token);
      }
    })();
  });

  api.onStopRecording(({ token, discard }) => {
    void (async () => {
      if (discard) {
        // A cancelled recording: nobody wants the audio, so it is never encoded or sent.
        await cancelCapture(token);
        return;
      }
      if (!isCapturing(token)) {
        await api.sendAudioError('Recording is not running.', token);
        return;
      }
      try {
        const result = await stopCapture(token);
        await api.sendAudio(token, result.wav, {
          durationSeconds: result.durationSeconds,
          peak: result.peak,
          hadSpeech: result.hadSpeech,
        });
      } catch (error) {
        await api.sendAudioError((error as Error).message, token);
        await cancelCapture(token);
      }
    })();
  });
}
