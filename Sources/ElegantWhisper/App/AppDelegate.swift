import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        model.start()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model.refreshAfterActivation()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Closing the SwiftUI window must not stop the global hotkey or active dictation service.
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }
}
