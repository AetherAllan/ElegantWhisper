import AppKit
import AVFoundation
import ApplicationServices
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
        // Accessibility lets us inspect the focused element. Input Monitoring is a separate
        // TCC gate for listening to global keyboard input while another app is focused.
        let inputMonitoring = CGPreflightListenEventAccess()
        let bundlePath = Bundle.main.bundlePath
        let runningAsAppBundle = bundlePath.hasSuffix(".app")

        return PermissionStatus(
            microphoneGranted: microphone == .authorized,
            speechGranted: speech == .authorized,
            accessibilityGranted: accessibility,
            inputMonitoringGranted: inputMonitoring,
            microphoneDetail: detail(for: microphone),
            speechDetail: detail(for: speech),
            accessibilityDetail: accessibility ? "OK" : "Missing",
            inputMonitoringDetail: inputMonitoring ? "OK" : "Missing",
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
        _ = CGRequestListenEventAccess()
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
