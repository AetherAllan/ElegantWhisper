import AppKit
import SwiftUI

struct AppCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About \(AppConstants.productName)") {
                model.openAbout()
                openMainWindow()
            }
        }

        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                model.openSettings()
                openMainWindow()
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }

    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "main")
    }
}
