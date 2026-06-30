import AppKit
import AVFoundation
import ApplicationServices
import IOKit.hidsystem
import Speech

struct PermissionStatus {
    let microphoneGranted: Bool
    let speechGranted: Bool
    let accessibilityGranted: Bool
    let inputMonitoringGranted: Bool
    let microphoneDetail: String
    let speechDetail: String
    let accessibilityDetail: String
    let inputMonitoringDetail: String
    let inputMonitoringDiagnostics: String
    let runningAsAppBundle: Bool
    let bundlePath: String

    var missingTitles: [String] {
        var values: [String] = []
        if !microphoneGranted { values.append("Microphone") }
        if !speechGranted { values.append("Speech Recognition") }
        if !accessibilityGranted { values.append("Accessibility") }
        if !inputMonitoringGranted { values.append("Input Monitoring") }
        return values
    }

    var rebuildHint: String? {
        guard !missingTitles.isEmpty else { return nil }
        if !runningAsAppBundle {
            return "Run via `make run` (not swift build). Permissions only apply to the .app bundle."
        }
        // TCC permissions are tied to the signed app identity. Rebuilding with a different
        // signature or path can leave System Settings showing an old entry while this binary
        // still reads as denied.
        return "After `make install`, macOS treats each rebuild as a new app. Remove ElegantWhisper from System Settings privacy lists, then re-enable."
    }
}

final class PermissionManager {
    func status() -> PermissionStatus {
        let microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        let speech = SFSpeechRecognizer.authorizationStatus()
        let accessibility = AXIsProcessTrusted()
        let inputMonitoring = inputMonitoringStatus()
        let bundlePath = Bundle.main.bundlePath
        let runningAsAppBundle = bundlePath.hasSuffix(".app")

        return PermissionStatus(
            microphoneGranted: microphone == .authorized,
            speechGranted: speech == .authorized,
            accessibilityGranted: accessibility,
            inputMonitoringGranted: inputMonitoring.granted,
            microphoneDetail: detail(for: microphone),
            speechDetail: detail(for: speech),
            accessibilityDetail: accessibility ? "OK" : "Missing",
            inputMonitoringDetail: inputMonitoring.granted ? "OK" : "Missing",
            inputMonitoringDiagnostics: inputMonitoring.detail,
            runningAsAppBundle: runningAsAppBundle,
            bundlePath: bundlePath
        )
    }

    func requestMicrophone(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                completion(granted)
            }
        }
    }

    func requestSpeech(_ completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                completion(status == .authorized)
            }
        }
    }

    func requestAccessibilityPrompt() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func requestInputMonitoring() {
        // Ask through both APIs. On different macOS releases one API may only open Settings while
        // the other updates the ListenEvent TCC row, and calling both is harmless.
        _ = CGRequestListenEventAccess()
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    private func inputMonitoringStatus() -> (granted: Bool, detail: String) {
        let preflight = CGPreflightListenEventAccess()
        let hidAccess = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        let tapGranted = OptionKeyMonitor.canCreateListenOnlyKeyboardTap()

        let hidDetail: String
        switch hidAccess {
        case kIOHIDAccessTypeGranted:
            hidDetail = "hid=granted"
        case kIOHIDAccessTypeDenied:
            hidDetail = "hid=denied"
        case kIOHIDAccessTypeUnknown:
            hidDetail = "hid=unknown"
        default:
            hidDetail = "hid=\(hidAccess.rawValue)"
        }

        // The event tap probe is the operational truth: if this tap cannot be created, background
        // hotkeys cannot work. Preflight/HID are kept as diagnostics because macOS versions differ
        // on which API updates first after the user changes System Settings.
        let granted = tapGranted
        let detail = "tap=\(tapGranted ? "ok" : "blocked"), cg=\(preflight ? "granted" : "blocked"), \(hidDetail)"
        return (granted, detail)
    }

    private func detail(for status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: "OK"
        case .denied: "Denied"
        case .restricted: "Restricted"
        case .notDetermined: "Not requested"
        @unknown default: "Unknown"
        }
    }

    private func detail(for status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .authorized: "OK"
        case .denied: "Denied"
        case .restricted: "Restricted"
        case .notDetermined: "Not requested"
        @unknown default: "Unknown"
        }
    }

    func openMicrophoneSettings() {
        openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    func openSpeechSettings() {
        openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
    }

    func openAccessibilitySettings() {
        openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    func openInputMonitoringSettings() {
        openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    private func openSettings(_ value: String) {
        if let url = URL(string: value) {
            NSWorkspace.shared.open(url)
        }
    }
}
