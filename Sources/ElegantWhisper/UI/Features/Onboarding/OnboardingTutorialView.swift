import SwiftUI

struct OnboardingOverviewView: View {
    let next: () -> Void
    let skip: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            Group {
                if reduceMotion {
                    hero
                } else {
                    hero.phaseAnimator([false, true]) { content, active in
                        content
                            .scaleEffect(active ? 1.04 : 0.96)
                            .shadow(color: Color.accentColor.opacity(active ? 0.32 : 0.12), radius: active ? 28 : 12)
                    } animation: { _ in
                        .easeInOut(duration: 1.2)
                    }
                }
            }

            VStack(spacing: 8) {
                Text("Your voice, wherever you type")
                    .font(.largeTitle.bold())
                Text("Tap Right Option, speak naturally, and ElegantWhisper inserts the result into the focused field.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 560)
            }

            HStack(spacing: 14) {
                FeatureCard(symbol: "option", title: "One key", detail: "Tap to start and stop")
                FeatureCard(symbol: "waveform", title: "Live speech", detail: "See words as you speak")
                FeatureCard(symbol: "text.cursor", title: "Insert anywhere", detail: "Falls back to clipboard safely")
            }

            Spacer()

            HStack {
                Button("Skip Tutorial", action: skip).buttonStyle(.plain)
                Spacer()
                Button("Try It", action: next).buttonStyle(.borderedProminent)
            }
        }
        .padding(38)
    }

    private var hero: some View {
        ZStack {
            Circle().fill(Color.accentColor.gradient).frame(width: 116, height: 116)
            Image(systemName: "waveform")
                .font(.system(size: 46, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}

struct OnboardingPracticeView: View {
    let finish: () -> Void
    let skip: () -> Void
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var recorded = false
    @State private var succeeded = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: succeeded ? "checkmark.circle.fill" : modeSymbol)
                .font(.system(size: 56))
                .foregroundStyle(succeeded ? Color.green : Color.accentColor)
                .contentTransition(.symbolEffect(.replace))

            VStack(spacing: 7) {
                Text(succeeded ? "You're ready" : practiceTitle)
                    .font(.largeTitle.bold())
                Text(succeeded ? "ElegantWhisper inserted your first dictation." : "Keep this field focused. Tap Right Option, speak, then tap it again.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Try saying: Today I am writing with ElegantWhisper.")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 17)
                        .padding(.vertical, 15)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .font(.title3)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .focused($focused)
            }
            .frame(maxWidth: 560, minHeight: 120)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(focused ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: focused ? 2 : 1))

            HStack {
                Button("Do This Later", action: skip).buttonStyle(.plain)
                Spacer()
                Button(succeeded ? "Start Using ElegantWhisper" : "Waiting for Dictation", action: finish)
                    .buttonStyle(.borderedProminent)
                    .disabled(!succeeded)
            }
            .frame(maxWidth: 560)
            Spacer()
        }
        .padding(38)
        .task {
            try? await Task.sleep(for: .milliseconds(250))
            focused = true
        }
        .onChange(of: model.mode) { _, mode in
            if mode == .recording {
                recorded = true
            } else if recorded, mode == .idle, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                succeeded = true
            }
        }
        .onChange(of: text) { _, value in
            if recorded, model.mode == .idle, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                succeeded = true
            }
        }
    }

    private var practiceTitle: String {
        switch model.mode {
        case .recording: "Listening…"
        case .preparing: "Getting ready…"
        case .transcribing, .refining: "Turning speech into text…"
        case .injecting: "Inserting…"
        case .idle: recorded ? "Finish speaking with Right Option" : "Try your first dictation"
        }
    }

    private var modeSymbol: String {
        model.mode == .recording ? "waveform.circle.fill" : "option"
    }
}

private struct FeatureCard: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: symbol).font(.title2).foregroundStyle(Color.accentColor)
            Text(title).fontWeight(.semibold)
            Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 92)
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
