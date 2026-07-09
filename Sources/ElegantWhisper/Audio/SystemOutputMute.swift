import CoreAudio
import Foundation

/// Tracks which output device we muted (Typeless-style ownership).
struct OutputMuteTracker: Equatable, Sendable {
    private(set) var mutedDeviceID: AudioDeviceID?

    var didMuteByUs: Bool { mutedDeviceID != nil }

    mutating func registerMuteResult(deviceID: AudioDeviceID, wasAlreadyMuted: Bool, applied: Bool) {
        if !wasAlreadyMuted, applied {
            mutedDeviceID = deviceID
        }
    }

    mutating func clearOwnership() {
        mutedDeviceID = nil
    }
}

// ponytail: system mute like Typeless, not MediaRemote pause
final class SystemOutputMute: @unchecked Sendable {
    static let shared = SystemOutputMute()

    private let queue = DispatchQueue(label: "com.elegantwhisper.output-mute")
    private var tracker = OutputMuteTracker()

    /// Fire-and-forget; ordered with unmute on a private serial queue.
    func muteIfNeededAsync() {
        queue.async { self.muteIfNeeded() }
    }

    /// Fire-and-forget; safe no-op unless we muted.
    func unmuteIfNeededAsync() {
        queue.async { self.unmuteIfNeeded() }
    }

    /// Blocks until unmute finishes — use on terminate so the mute bit is restored before exit.
    func unmuteIfNeededSync() {
        queue.sync { self.unmuteIfNeeded() }
    }

    private func muteIfNeeded() {
        guard let deviceID = Self.defaultOutputDeviceID() else {
            return
        }
        guard let currentlyMuted = Self.isMuted(deviceID) else {
            return
        }
        if currentlyMuted {
            tracker.registerMuteResult(deviceID: deviceID, wasAlreadyMuted: true, applied: false)
            return
        }
        let applied = Self.setMuted(deviceID, true)
        tracker.registerMuteResult(deviceID: deviceID, wasAlreadyMuted: false, applied: applied)
    }

    private func unmuteIfNeeded() {
        guard let deviceID = tracker.mutedDeviceID else {
            return
        }
        if Self.setMuted(deviceID, false) {
            tracker.clearOwnership()
            return
        }
        // Device gone / already unmuted: drop ownership so we do not stick forever.
        if Self.isMuted(deviceID) != true {
            tracker.clearOwnership()
        }
    }

    private static func defaultOutputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            return nil
        }
        return deviceID
    }

    private static func isMuted(_ deviceID: AudioDeviceID) -> Bool? {
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &muted)
        guard status == noErr else {
            return nil
        }
        return muted != 0
    }

    private static func setMuted(_ deviceID: AudioDeviceID, _ muted: Bool) -> Bool {
        var value: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &value)
        return status == noErr
    }
}
