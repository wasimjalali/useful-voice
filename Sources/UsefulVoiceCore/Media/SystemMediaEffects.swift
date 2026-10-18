import AppKit
import CoreAudio
import Foundation

public enum MediaEffectsError: Error, LocalizedError {
    case mediaRemoteUnavailable(String)
    case commandRefused(String)
    case coreAudio(String, OSStatus)
    case keyEventUnavailable

    public var errorDescription: String? {
        switch self {
        case .mediaRemoteUnavailable(let detail): return "MediaRemote is unavailable: \(detail)"
        case .commandRefused(let name): return "The system refused the \(name) command"
        case .coreAudio(let what, let status): return "Core Audio \(what) failed (\(status))"
        case .keyEventUnavailable: return "Could not build the media key event"
        }
    }
}

/// The real effects of `MediaPausePolicy`.
///
/// What works on macOS 26 and later, measured on this machine (see
/// `scripts/media-pause-e2e/run.sh`):
/// - MediaRemote's read functions (`...IsPlaying`, `...ApplicationPID`, `GetNowPlayingInfo`)
///   answer "nothing playing" to a third-party process, so they are not used to decide.
/// - Core Audio's process list (public API, macOS 14.2 and later) says which processes are
///   outputting audio, which is the detection and the check that a command had an effect.
/// - MediaRemote's *send* function still delivers Pause and Play to the Now Playing app.
/// - The Play/Pause media key is the fallback; it toggles, so the policy checks first.
public final class SystemMediaEffects: MediaEffects, @unchecked Sendable {
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private let mediaRemote = MediaRemoteLibrary()

    public init() {}

    // MARK: - Detection (Core Audio)

    public func outputtingPlayers() throws -> [MediaPlayerID] {
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        guard status == noErr else { throw MediaEffectsError.coreAudio("process list size", status) }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects)
        guard status == noErr else { throw MediaEffectsError.coreAudio("process list", status) }

        var players: [MediaPlayerID] = []
        for object in objects {
            guard Self.uint32(object, kAudioProcessPropertyIsRunningOutput) == 1,
                  let pid = Self.int32(object, kAudioProcessPropertyPID) else { continue }
            let bundleID = Self.string(object, kAudioProcessPropertyBundleID)
            guard MediaPlayerFilter.isMedia(pid: pid, bundleID: bundleID, ownPID: ownPID) else { continue }
            players.append(MediaPlayerID(pid: pid, bundleID: bundleID))
        }
        return players
    }

    public func isAlive(_ player: MediaPlayerID) -> Bool {
        // 0: alive. EPERM: alive but not ours to signal.
        kill(player.pid, 0) == 0 || errno == EPERM
    }

    // MARK: - Commands

    public func sendPause() throws { try mediaRemote.send(.pause) }
    public func sendPlay() throws { try mediaRemote.send(.play) }

    public func sendPlayPauseKey() throws {
        // NX_KEYTYPE_PLAY, as a system-defined event (subtype 8): key down, then key up.
        for isDown in [true, false] {
            let flags = isDown ? 0xA00 : 0xB00
            guard let event = NSEvent.otherEvent(
                with: .systemDefined, location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags)),
                timestamp: 0, windowNumber: 0, context: nil,
                subtype: 8, data1: (16 << 16) | flags, data2: -1),
                  let cgEvent = event.cgEvent else {
                throw MediaEffectsError.keyEventUnavailable
            }
            cgEvent.post(tap: .cghidEventTap)
        }
    }

    public func sleep(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    // MARK: - Core Audio helpers

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = address(selector)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func int32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Int32? {
        var value: Int32 = 0
        var size = UInt32(MemoryLayout<Int32>.size)
        var address = address(selector)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = address(selector)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        let text = value?.takeRetainedValue() as String?
        return (text?.isEmpty ?? true) ? nil : text
    }
}

/// MediaRemote, the private framework behind the system Now Playing controls, loaded at
/// run time so a missing symbol on a future macOS is an error to log, not a crash.
final class MediaRemoteLibrary: @unchecked Sendable {
    enum Command: UInt32 {
        case play = 0   // kMRPlay
        case pause = 1  // kMRPause

        var name: String { self == .play ? "play" : "pause" }
    }

    private typealias SendCommand = @convention(c) (UInt32, CFDictionary?) -> Bool

    private let lock = NSLock()
    private var loaded: Result<SendCommand, MediaEffectsError>?

    func send(_ command: Command) throws {
        let function = try resolve()
        // The return value only says the request was queued; whether it did anything is
        // checked by the policy through the audio output.
        guard function(command.rawValue, nil) else {
            throw MediaEffectsError.commandRefused(command.name)
        }
    }

    private func resolve() throws -> SendCommand {
        try lock.withLock {
            if let loaded { return try loaded.get() }
            let result = Self.load()
            loaded = result
            return try result.get()
        }
    }

    private static func load() -> Result<SendCommand, MediaEffectsError> {
        let path = "/System/Library/PrivateFrameworks/MediaRemote.framework"
        guard let bundle = CFBundleCreate(kCFAllocatorDefault, NSURL(fileURLWithPath: path)) else {
            return .failure(.mediaRemoteUnavailable("framework not found"))
        }
        guard CFBundleLoadExecutable(bundle) else {
            return .failure(.mediaRemoteUnavailable("framework did not load"))
        }
        guard let pointer = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteSendCommand" as CFString) else {
            return .failure(.mediaRemoteUnavailable("MRMediaRemoteSendCommand not found"))
        }
        return .success(unsafeBitCast(pointer, to: SendCommand.self))
    }
}
