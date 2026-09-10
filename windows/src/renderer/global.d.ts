import type { UsefulVoiceApi } from '../preload/index.js';

declare global {
  interface Window {
    usefulVoice: UsefulVoiceApi;
  }
}

export {};
