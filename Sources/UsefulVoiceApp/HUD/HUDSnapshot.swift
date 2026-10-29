import AppKit
import SwiftUI
import UsefulVoiceCore

/// Renders a SwiftUI view offscreen to a PNG: no window on screen, no focus
/// change, safe beside a running copy of the app.
@MainActor
enum SnapshotWriter {
    static func write(view: AnyView, size: CGSize, appearance: NSAppearance?, to url: URL,
                      completion: @escaping (Bool) -> Void) {
        let hosting = NSHostingView(rootView: view)
        let offscreen = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
        // The window is never shown, so give it the appearance explicitly: the dynamic
        // colors resolve against it when the content is drawn.
        offscreen.appearance = appearance
        offscreen.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            hosting.layoutSubtreeIfNeeded()
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
                completion(false)
                return
            }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]),
                  (try? png.write(to: url, options: .atomic)) != nil,
                  (try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                          ofItemAtPath: url.path)) != nil else {
                completion(false)
                return
            }
            completion(true)
        }
    }
}

/// `UV_HUD_STATE=<name>` with `UV_SNAPSHOT`: the HUD (or the language picker) with
/// sample data, on a plain canvas standing in for the app in front.
///
/// Names: recording, recordingLoud, silence, transcribing, local, localFa,
/// inserting, done, doneSaved, copied, copiedAppChanged, cancelled, errorNetwork, errorMic, errorTimedOut, errorSecure,
/// language, picker.
@MainActor
enum HUDSnapshot {
    static let names = ["recording", "recordingLoud", "silence", "transcribing", "local", "localFa",
                        "inserting", "done", "doneSaved", "copied", "copiedAppChanged", "cancelled", "errorNetwork",
                        "errorMic", "errorTimedOut", "errorSecure", "language", "picker"]

    private static let englishPartial =
        "the computer quiet so you can run the performance check here, and remove the Devin dependency from the repo before we ship it to everyone on the team on Friday"
    private static let persianPartial =
        "بنده همان شخصی هستم که چند هفته پیش برای شما یک برنامه ساختم که سوالات تکراری را در کامنت‌ها پاسخ می‌دهد و بعد از آن همه چیز را برای تیم ارسال کردم تا بتوانند آن را بررسی کنند"

    static func display(named name: String) -> HUDDisplay? {
        switch name {
        case "recording": return .recording(seconds: 3, level: 0.004, stopsIn: nil)
        case "recordingLoud": return .recording(seconds: 7, level: 0.12, stopsIn: nil)
        case "silence": return .recording(seconds: 55, level: 0.004, stopsIn: 5)
        case "transcribing": return .transcribing(partial: nil, local: false)
        case "local": return .transcribing(partial: englishPartial, local: true)
        case "localFa": return .transcribing(partial: persianPartial, local: true)
        case "inserting": return .delivering
        case "done": return .done(.inserted(words: 24))
        case "doneSaved": return .done(.savedAndCopied(words: 24))
        case "copied": return .copiedNotPasted(fix: .openAccessibilitySettings)
        case "copiedAppChanged": return .copiedNotPasted(fix: nil)
        case "cancelled": return .cancelled
        case "errorNetwork":
            return .error(HUDError(DictationError(kind: .offline, message: "", fix: .retry)))
        case "errorMic":
            return .error(HUDError(DictationError(kind: .micUnavailable, message: "",
                                                  fix: .openMicrophoneSettings)))
        case "errorTimedOut":
            return .error(HUDError(DictationError(kind: .timedOut, message: "", fix: .retry)))
        case "errorSecure":
            return .error(HUDError(DictationError(kind: .secureField, message: "")))
        case "language": return .language(.de)
        default: return nil
        }
    }

    /// A speech-like waveform history (mapped 0...1, oldest first) for the recording states.
    private static func waveformFixture(named name: String) -> [Double]? {
        let speech: [Double] = [0, 0, 0.04, 0.12, 0.3, 0.5, 0.62, 0.45, 0.2, 0.08, 0, 0.1, 0.38, 0.66, 0.78,
                                0.58, 0.72, 0.4, 0.15, 0.05, 0, 0.18, 0.44, 0.6, 0.52, 0.7, 0.55, 0.34, 0.5, 0.42]
        switch name {
        case "recording": return speech
        case "recordingLoud": return speech.map { min($0 * 1.35 + ($0 > 0 ? 0.12 : 0), 1) }
        default: return nil
        }
    }

    static func render(_ name: String, size: CGSize, appearance: NSAppearance?, to url: URL,
                       completion: @escaping (Bool) -> Void) {
        let scene: AnyView
        if name == "picker" {
            scene = AnyView(
                ZStack {
                    Theme.canvas
                    // The list scrolls to the selection only in a live window, so the sample picks
                    // a language near the top: the check and the tint both show.
                    LanguagePicker(selection: .constant(LanguagePin(rawValue: "af")),
                                   initialHighlight: "lang:bn")
                })
        } else if let display = display(named: name) {
            let placement = Self.placement
            scene = AnyView(
                Self.stage(placement: placement, size: size) {
                    HUDView(display: display, placement: placement, palette: Self.palette,
                            waveformFixture: waveformFixture(named: name))
                })
        } else {
            fputs("UV_HUD_STATE must be one of: \(names.joined(separator: ", "))\n", stderr)
            exit(2)
        }
        SnapshotWriter.write(view: scene, size: size, appearance: appearance, to: url,
                             completion: completion)
    }
}

// MARK: - Placement, colorway and frames

/// `UV_HUD_PLACEMENT=bottom|caret|caretFlipped`, `UV_HUD_COLORWAY=ink|paper|signal|accent`,
/// `UV_HUD_ACCENT=#RRGGBB` and `UV_HUD_SYSTEM_DARK=1` shape the snapshot; nothing is saved.
/// `UV_HUD_FRAMES=<from>:<to>:<step>` renders a scripted dictation (record, transcribe,
/// insert, done, exit) as one PNG per moment, next to the `UV_SNAPSHOT` path with the
/// frame number appended.
extension HUDSnapshot {
    private static var environment: [String: String] { ProcessInfo.processInfo.environment }

    static var placement: HUDPlacement {
        switch environment["UV_HUD_PLACEMENT"] {
        case "caret": return .caret(flipped: false)
        case "caretFlipped": return .caret(flipped: true)
        default: return .bottom
        }
    }

    static var palette: HUDPalette {
        let colorway = HUDColorway(rawValue: environment["UV_HUD_COLORWAY"] ?? "") ?? .ink
        return HUDPalette.resolve(colorway, accentHex: environment["UV_HUD_ACCENT"] ?? AppSettings.defaultHUDAccentHex,
                                  systemDark: environment["UV_HUD_SYSTEM_DARK"] == "1")
    }

    /// A page of an app with its text cursor, and the HUD's window placed the way
    /// the panel would place it: beside the cursor, or at the bottom centre.
    @ViewBuilder
    static func stage<HUD: View>(placement: HUDPlacement, size: CGSize, @ViewBuilder hud: () -> HUD) -> some View {
        let window = HUDView.windowSize
        let caretX: CGFloat = placement.isFlipped ? size.width - 44 : 40
        let caretMid = size.height / 2 + 6
        ZStack(alignment: .topLeading) {
            Theme.surface
            VStack(alignment: .leading, spacing: 6) {
                Text("Launch review").font(.uv(.ui, .semibold))
                Text("Hi Jordan,").font(.uv(.body))
            }
            .foregroundStyle(Theme.ink)
            .padding(.leading, 40)
            .padding(.top, 22)
            if placement.isCaret {
                if placement.isFlipped {
                    Text("Sounds good, I'll send the updated deck")
                        .font(.uv(.body)).foregroundStyle(Theme.ink)
                        .frame(width: caretX - 40, alignment: .trailing)
                        .offset(x: 38, y: caretMid - 9)
                }
                RoundedRectangle(cornerRadius: 1).fill(Theme.ink)
                    .frame(width: 2, height: 18)
                    .offset(x: caretX, y: caretMid - 9)
                let x = placement.isFlipped
                    ? caretX - HUDView.caretGap - (window.width - HUDView.shadowPad)
                    : caretX + 2 + HUDView.caretGap - HUDView.shadowPad
                hud().offset(x: x, y: caretMid - window.height / 2)
            } else {
                hud().offset(x: (size.width - window.width) / 2, y: size.height - window.height - 12)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    /// The scripted dictation, as the panel would show it.
    private struct Event {
        let at: Double
        let display: HUDDisplay
    }

    private static let script: [Event] = [
        Event(at: 0, display: .recording(seconds: 0, level: 0, stopsIn: nil)),
        Event(at: 3.0, display: .transcribing(partial: nil, local: false)),
        Event(at: 4.2, display: .delivering),
        Event(at: 4.36, display: .done(.inserted(words: 23))),
    ]
    private static let chipAt = 4.42
    private static let exitAt = 5.56

    /// A voice-like level, 0...1: syllable bursts with a breath in the middle.
    private static func voice(_ t: Double) -> Double {
        guard t > 0.2, t < 2.9, !(1.35...1.6).contains(t) else { return 0.02 }
        let bursts = max(0, sin(t * 17.3)) * (0.55 + 0.45 * sin(t * 4.1 + 1))
        return min(1, 0.06 + 0.9 * bursts)
    }

    private static func frame(at t: Double, base: Date, placement: HUDPlacement) -> (HUDDisplay, HUDTimeline, Double, [Double]) {
        var display = script[0].display
        var timeline = HUDTimeline.entering(display, at: base)
        for event in script.dropFirst() where event.at <= t {
            // The recording that ends here shows its last second, as the live one would.
            let old: HUDDisplay = display.isRecording
                ? .recording(seconds: Int(event.at), level: 0, stopsIn: nil) : display
            timeline.advance(from: old, to: event.display, placement: placement,
                             at: base.addingTimeInterval(event.at))
            display = event.display
        }
        if case .recording = display {
            display = .recording(seconds: Int(t), level: Float(voice(t) * 0.05), stopsIn: nil)
        }
        if placement.isCaret, t >= chipAt { timeline.chipAt = base.addingTimeInterval(chipAt) }
        if t >= exitAt { timeline.exitAt = base.addingTimeInterval(exitAt) }
        let history = (0..<HUDWaveform.barCount).map { i in voice(t - Double(HUDWaveform.barCount - 1 - i) * 0.05) }
        let level = (voice(t) + voice(t - 0.04) + voice(t - 0.08)) / 3
        return (display, timeline, level, history)
    }

    static func renderFrames(_ spec: String, size: CGSize, appearance: NSAppearance?, to url: URL) -> Bool {
        let parts = spec.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 3, parts[2] > 0 else {
            fputs("UV_HUD_FRAMES must look like 0:6:0.0333\n", stderr)
            return false
        }
        NSApp.appearance = appearance
        let placement = Self.placement
        let palette = Self.palette
        let base = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let stem = url.deletingPathExtension().path
        var index = 0
        var t = parts[0]
        while t <= parts[1] + 1e-9 {
            let (display, timeline, level, history) = frame(at: t, base: base, placement: placement)
            let scene = stage(placement: placement, size: size) {
                HUDView(display: display, placement: placement, palette: palette, timeline: timeline, level: level,
                        clock: base.addingTimeInterval(t), waveformFixture: history)
            }
            let renderer = ImageRenderer(content: scene.environment(\.colorScheme,
                appearance?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light))
            renderer.scale = 2
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]),
                  (try? png.write(to: URL(fileURLWithPath: String(format: "%@-%04d.png", stem, index)))) != nil
            else { return false }
            index += 1
            t += parts[2]
        }
        return true
    }

    /// The scripted dictation on the real clock, through the real panel: placement,
    /// the cursor lookup, the window and its shadow, as a person would see them.
    static func playDemo(on hud: HUDPanel, after delay: Double) {
        if let pid = environment["UV_HUD_DEMO_PID"].flatMap({ pid_t($0) }) { CaretLocator.targetPID = pid }
        for moment in [0.6, 2.0, 3.6, 4.7] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + moment) {
                print(String(format: "t=%.1f ", moment) + hud.geometry())
                fflush(stdout)
            }
        }
        let start = Date().addingTimeInterval(delay)
        for event in script.dropFirst() {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + event.at) { hud.show(event.display) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            hud.show(script[0].display)
            let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { timer in
                MainActor.assumeIsolated {
                    let t = Date().timeIntervalSince(start)
                    guard t < script[1].at else { timer.invalidate(); return }
                    // Back from the 0...1 meter level to the raw RMS the panel expects.
                    let rms = Float(pow(10, (voice(t) * 36 - 52) / 20))
                    hud.show(.recording(seconds: Int(t), level: rms, stopsIn: nil))
                }
            }
            RunLoop.main.add(timer, forMode: .common)
        }
        // `UV_HUD_DEMO_HOLD=1` follows the run with an error that stays up, to check the
        // frame clock pauses once nothing moves.
        let hold = environment["UV_HUD_DEMO_HOLD"] != nil
        if hold {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + 6) {
                hud.show(.error(HUDError(DictationError(kind: .offline, message: "", fix: .retry))))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + (hold ? 13 : 7)) { exit(0) }
    }
}
