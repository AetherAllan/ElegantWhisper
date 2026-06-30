import AppKit
import AVFoundation
import ApplicationServices
import Speech

struct PermissionStatus {
    let microphoneGranted: Bool
    let speechGranted: Bool
    let accessibilityGranted: Bool

    var missingTitles: [String] {
        var values: [String] = []
        if !microphoneGranted { values.append("Microphone") }
        if !speechGranted { values.append("Speech Recognition") }
        if !accessibilityGranted { values.append("Accessibility") }
        return values
    }
}

final class PermissionManager {
    func status() -> PermissionStatus {
        PermissionStatus(
            microphoneGranted: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            speechGranted: SFSpeechRecognizer.authorizationStatus() == .authorized,
            accessibilityGranted: AXIsProcessTrusted()
        )
    }

    func requestMicrophone(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
    }

    func requestSpeech(_ completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            completion(status == .authorized)
        }
    }

    func requestAccessibilityPrompt() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
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
