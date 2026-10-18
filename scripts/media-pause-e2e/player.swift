// A test media player for the "Pause media while dictating" E2E. Plays SILENCE (a zero
// buffer through AVAudioEngine, so Core Audio reports the process as outputting), registers
// as the system's Now Playing app with play and pause handlers, and logs every command with a
// wall-clock timestamp. It never produces audible sound.
//
// Controlled over stdin, one word per line: `play`, `pause` (what a user would do), `quit`.
// Build and run through `scripts/media-pause-e2e/run.sh`.
import AVFoundation
import AppKit
import MediaPlayer

let arguments = CommandLine.arguments
guard let logIndex = arguments.firstIndex(of: "--log"), arguments.count > logIndex + 1 else {
    FileHandle.standardError.write(Data("usage: player --log <file> [--paused]\n".utf8))
    exit(2)
}
let logURL = URL(fileURLWithPath: arguments[logIndex + 1])
FileManager.default.createFile(atPath: logURL.path, contents: nil)
let logHandle = try FileHandle(forWritingTo: logURL)

func log(_ text: String) {
    let line = String(format: "%.3f %@\n", Date().timeIntervalSince1970, text)
    try? logHandle.write(contentsOf: Data(line.utf8))
}

let engine = AVAudioEngine()
// Zero samples: Core Audio sees a running output stream, the speakers get silence.
let silence = AVAudioSourceNode { _, _, _, bufferList -> OSStatus in
    for buffer in UnsafeMutableAudioBufferListPointer(bufferList) {
        if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
    }
    return noErr
}
let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
engine.attach(silence)
engine.connect(silence, to: engine.mainMixerNode, format: format)

var playing = false

func publishNowPlaying() {
    MPNowPlayingInfoCenter.default().nowPlayingInfo = [
        MPMediaItemPropertyTitle: "Silent test track",
        MPMediaItemPropertyArtist: "media-pause-e2e",
        MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
        MPMediaItemPropertyPlaybackDuration: 3600.0,
    ]
    MPNowPlayingInfoCenter.default().playbackState = playing ? .playing : .paused
}

func setPlaying(_ on: Bool, why: String) {
    if on {
        do {
            if !engine.isRunning { try engine.start() }
            playing = true
        } catch {
            log("ERROR engine start failed \(error)")
            return
        }
    } else {
        engine.pause()
        playing = false
    }
    publishNowPlaying()
    log("STATE \(playing ? "playing" : "paused") (\(why))")
}

let center = MPRemoteCommandCenter.shared()
center.playCommand.isEnabled = true
center.pauseCommand.isEnabled = true
center.togglePlayPauseCommand.isEnabled = true
center.playCommand.addTarget { _ in
    log("COMMAND play")
    setPlaying(true, why: "remote play")
    return .success
}
center.pauseCommand.addTarget { _ in
    log("COMMAND pause")
    setPlaying(false, why: "remote pause")
    return .success
}
center.togglePlayPauseCommand.addTarget { _ in
    log("COMMAND togglePlayPause")
    setPlaying(!playing, why: "remote toggle")
    return .success
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

log("READY pid \(getpid())")
if !arguments.contains("--paused") { setPlaying(true, why: "launch") } else { publishNowPlaying() }

// The user acting on the player itself, from the harness.
DispatchQueue.global().async {
    while let line = readLine() {
        DispatchQueue.main.async {
            switch line.trimmingCharacters(in: .whitespaces) {
            case "play": log("USER play"); setPlaying(true, why: "user")
            case "pause": log("USER pause"); setPlaying(false, why: "user")
            case "quit": log("QUIT"); exit(0)
            default: break
            }
        }
    }
    DispatchQueue.main.async { log("QUIT stdin closed"); exit(0) }
}

app.run()
