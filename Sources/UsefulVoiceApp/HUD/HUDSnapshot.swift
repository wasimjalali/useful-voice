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
/// inserting, done, doneSaved, copied, cancelled, errorNetwork, errorMic,
/// language, picker.
@MainActor
enum HUDSnapshot {
    static let names = ["recording", "recordingLoud", "silence", "transcribing", "local", "localFa",
                        "inserting", "done", "doneSaved", "copied", "cancelled", "errorNetwork",
                        "errorMic", "language", "picker"]

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
        case "copied": return .copiedNotPasted
        case "cancelled": return .cancelled
        case "errorNetwork":
            return .error(HUDError(DictationError(kind: .offline, message: "", fix: .retry)))
        case "errorMic":
            return .error(HUDError(DictationError(kind: .micUnavailable, message: "",
                                                  fix: .openMicrophoneSettings)))
        case "language": return .language(.de)
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
            scene = AnyView(
                ZStack(alignment: .bottom) {
                    Theme.surface
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Slack #launch").font(.uv(.ui, .semibold))
                        Text("Looks good to me. Ship it once the checklist is green")
                            .font(.uv(.body))
                    }
                    .foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(20)
                    HUDView(display: display)
                })
        } else {
            fputs("UV_HUD_STATE must be one of: \(names.joined(separator: ", "))\n", stderr)
            exit(2)
        }
        SnapshotWriter.write(view: scene, size: size, appearance: appearance, to: url,
                             completion: completion)
    }
}
