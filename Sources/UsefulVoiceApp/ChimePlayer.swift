import AppKit
import UsefulVoiceCore

/// Plays the start/stop dictation cues. The sounds are synthesized once at
/// launch and cached; playback respects the sound-effects setting via the
/// injected isEnabled closure.
@MainActor
final class ChimePlayer {
    private let start = NSSound(data: ChimeSynth.startChime())
    private let stop = NSSound(data: ChimeSynth.stopChime())
    var isEnabled: () -> Bool = { true }

    func playStart() { play(start) }
    func playStop() { play(stop) }

    private func play(_ sound: NSSound?) {
        guard isEnabled() else { return }
        sound?.stop()   // rewind if the previous cue is still ringing
        sound?.play()
    }
}
