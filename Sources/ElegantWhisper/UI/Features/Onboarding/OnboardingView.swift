import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step = OnboardingStep.permissions
    @State private var configured = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.accentColor.opacity(0.12), Color.clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                stepIndicator
                    .padding(.top, 22)

                Group {
                    switch step {
                    case .permissions:
                        PermissionSetupView()
                    case .overview:
                        OnboardingOverviewView(
                            next: { move(to: .practice) },
                            skip: finish
                        )
                    case .practice:
                        OnboardingPracticeView(finish: finish, skip: finish)
                    }
                }
                .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
                .id(step)
            }
        }
        .task {
            guard !configured else { return }
            configured = true
            step = model.permissionStatus.missingTitles.isEmpty ? .overview : .permissions

            while !Task.isCancelled, step == .permissions {
                model.refreshPermissions()
                if model.permissionStatus.missingTitles.isEmpty {
                    move(to: .overview)
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var stepIndicator: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingStep.allCases) { value in
                Capsule()
                    .fill(value.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.2))
                    .frame(width: value == step ? 34 : 12, height: 6)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: step)
        .accessibilityLabel("Setup step \(step.rawValue + 1) of \(OnboardingStep.allCases.count)")
    }

    private func move(to newStep: OnboardingStep) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.28)) {
            step = newStep
        }
    }

    private func finish() {
        model.completeOnboarding()
        openWindow(id: "main")
        dismissWindow(id: "onboarding")
    }
}

private enum OnboardingStep: Int, CaseIterable, Identifiable {
    case permissions
    case overview
    case practice

    var id: Self { self }
}

private struct PermissionSetupView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Allow ElegantWhisper to work anywhere")
                    .font(.largeTitle.bold())
                Text("macOS keeps these permissions under your control. Grant each one, then return here.")
                    .foregroundStyle(.secondary)
            }

            GroupBox {
                VStack(spacing: 2) {
                    PermissionActionRow(title: "Microphone", detail: "Record your voice for dictation.", granted: model.permissionStatus.microphoneGranted, actionTitle: "Allow", action: model.requestMicrophonePermission)
                    Divider()
                    PermissionActionRow(title: "Speech Recognition", detail: "Transcribe with Apple Speech.", granted: model.permissionStatus.speechGranted, actionTitle: "Allow", action: model.requestSpeechPermission)
                    Divider()
                    PermissionActionRow(
                        title: "Accessibility",
                        detail: "Find the focused field and paste safely.",
                        granted: model.permissionStatus.accessibilityGranted,
                        actionTitle: "Request Access",
                        action: model.requestAccessibilityPermission,
                        secondaryActionTitle: "Open System Settings",
                        secondaryAction: model.openAccessibilitySettings
                    )
                    Divider()
                    PermissionActionRow(title: "Input Monitoring", detail: "Listen for Right Option in the background.", granted: model.permissionStatus.inputMonitoringGranted, actionTitle: "Allow", action: model.requestInputMonitoringPermission)
                }
                .padding(6)
            }

            if model.accessibilityRestartSuggested,
               !model.permissionStatus.accessibilityGranted
            {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .foregroundStyle(Color.accentColor)
                    Text("Already enabled Accessibility? Restart once so macOS can apply it to this process.")
                        .font(.callout)
                    Spacer()
                    Button("Restart & Continue", action: model.restartApplication)
                        .buttonStyle(.borderedProminent)
                }
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(38)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
