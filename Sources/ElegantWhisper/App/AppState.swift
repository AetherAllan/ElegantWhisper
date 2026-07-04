import Foundation

enum AppMode {
    case idle
    case recording
    case transcribing
    case refining
    case injecting

    var title: String {
        switch self {
        case .idle: "Idle"
        case .recording: "Recording"
        case .transcribing: "Transcribing"
        case .refining: "Refining"
        case .injecting: "Inserting"
        }
    }
}

@MainActor
final class AppState {
    private(set) var mode: AppMode = .idle

    func transition(to next: AppMode) -> Bool {
        // Keep forward transitions explicit. Idle is the universal cancellation/reset exit.
        // Dictation has several async producers (hotkeys, Speech callbacks, LLM callbacks,
        // paste completion), and allowing arbitrary forward jumps is how duplicate recordings
        // or late paste operations happen.
        switch (mode, next) {
        case (.idle, .recording),
             (.recording, .transcribing),
             (.transcribing, .refining),
             (.transcribing, .injecting),
             (.refining, .injecting),
             (.injecting, .idle):
            mode = next
            return true
        case (_, .idle):
            mode = .idle
            return true
        default:
            return false
        }
    }
}
