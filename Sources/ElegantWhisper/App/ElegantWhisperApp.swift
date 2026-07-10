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
        .defaultLaunchBehavior(model.onboardingCompleted ? .presented : .suppressed)
        .commands {
            AppCommands(model: model)
        }

        Window("Welcome to \(AppConstants.productName)", id: "onboarding") {
            OnboardingView()
                .id(model.tutorialReplayID)
                .environment(model)
                .frame(width: 720, height: 540)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(model.onboardingCompleted ? .suppressed : .presented)

        MenuBarExtra {
            MenuBarContentView()
                .environment(model)
        } label: {
            StatusBarLabel()
        }
        .menuBarExtraStyle(.menu)
    }
}
