import CoreAudio
import Foundation

struct AudioInputDevice: Equatable, Sendable {
    let uid: String
    let name: String
}

enum AudioInputDevices {
    /// macOS 15+ HAL: list devices that can be the system default input.
    /// AVAudioEngine's inputNode always follows that default.
    static func list() -> [AudioInputDevice] {
        let system = AudioHardwareSystem.shared
        guard let devices = try? system.devices else {
            return []
        }
        return devices.compactMap { device in
            guard (try? device.canBeDefaultInputDevice) == true,
                  (try? device.isHidden) != true,
                  let uid = try? device.uid,
                  let name = try? device.name,
                  !name.isEmpty
            else {
                return nil
            }
            return AudioInputDevice(uid: uid, name: name)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func currentUID() -> String? {
        try? AudioHardwareSystem.shared.defaultInputDevice?.uid
    }

    /// Sets the system default input and waits until HAL reports the new UID.
    /// Core Audio applies default-device changes asynchronously.
    static func select(uid: String) async -> Bool {
        let system = AudioHardwareSystem.shared
        guard let device = try? system.device(forUID: uid),
              (try? device.canBeDefaultInputDevice) == true
        else {
            return false
        }
        do {
            try system.setDefaultInputDevice(device)
        } catch {
            DebugLog.event("setDefaultInputFailed")
            return false
        }

        if currentUID() == uid {
            return true
        }

        // ponytail: short poll; HAL has no sync setDefault. Ceiling ~1.5s, then fail closed.
        let deadline = ContinuousClock.now + .milliseconds(1500)
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
            if currentUID() == uid {
                return true
            }
        }
        DebugLog.event("setDefaultInputTimeout")
        return false
    }
}
