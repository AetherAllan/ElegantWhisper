import SwiftUI

@main
struct ElegantWhisperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private var model: AppModel { appDelegate.model }

    var body: some Scene {
        Window(AppConstants.productName, id: "main") {
            AppShellView()
                .environment(model)
                .frame(minWidth: 760, minHeight: 520)
        }
        .defaultSize(width: 960, height: 680)
        .defaultLaunchBehavior(model.permissionStatus.missingTitles.isEmpty ? .presented : .suppressed)
        .commands {
            AppCommands(model: model)
        }

        Window("\(AppConstants.productName) Permissions", id: "onboarding") {
            OnboardingView()
                .environment(model)
                .frame(width: 620, height: 480)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(model.permissionStatus.missingTitles.isEmpty ? .suppressed : .presented)

        MenuBarExtra {
            MenuBarContentView()
                .environment(model)
        } label: {
            StatusBarLabel()
        }
        .menuBarExtraStyle(.window)
    }
}
