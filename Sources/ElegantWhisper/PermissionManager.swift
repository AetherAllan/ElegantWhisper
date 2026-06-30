import AppKit
import AVFoundation
import ApplicationServices
import Speech

struct PermissionStatus {
    let microphoneGranted: Bool
    let speechGranted: Bool
    let accessibilityGranted: Bool
    let microphoneDetail: String
    let speechDetail: String
    let accessibilityDetail: String
    let runningAsAppBundle: Bool
    let bundlePath: String

    var missingTitles: [String] {
        var values: [String] = []
        if !microphoneGranted { values.append("Microphone") }
        if !speechGranted { values.append("Speech Recognition") }
        if !accessibilityGranted { values.append("Accessibility") }
        return values
    }

    var rebuildHint: String? {
        guard !missingTitles.isEmpty else { return nil }
        if !runningAsAppBundle {
            return "Run via `make run` (not swift build). Permissions only apply to the .app bundle."
        }
        return "After `make install`, macOS treats each rebuild as a new app. Remove ElegantWhisper from System Settings privacy lists, then re-enable."
    }
}

final class PermissionManager {
    func status() -> PermissionStatus {
        let microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        let speech = SFSpeechRecognizer.authorizationStatus()
        let accessibility = AXIsProcessTrusted()
        let bundlePath = Bundle.main.bundlePath
        let runningAsAppBundle = bundlePath.hasSuffix(".app")

        return PermissionStatus(
            microphoneGranted: microphone == .authorized,
            speechGranted: speech == .authorized,
            accessibilityGranted: accessibility,
            microphoneDetail: detail(for: microphone),
            speechDetail: detail(for: speech),
            accessibilityDetail: accessibility ? "OK" : "Missing",
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

    private func openSettings(_ value: String) {
        if let url = URL(string: value) {
            NSWorkspace.shared.open(url)
        }
    }
}
