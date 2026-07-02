import Foundation

enum AppMode: String {
    case idle
    case preparing
    case recording
    case transcribing
    case refining
    case injecting

    var title: String {
        switch self {
        case .idle: "Idle"
        case .preparing: "Preparing"
        case .recording: "Recording"
        case .transcribing: "Transcribing"
        case .refining: "Refining"
        case .injecting: "Inserting"
        }
    }
}

final class AppState {
    private(set) var mode: AppMode = .idle

    func transition(to next: AppMode) -> Bool {
        // Keep state transitions explicit. Dictation has several async producers
        // (hotkeys, Speech callbacks, LLM callbacks, paste completion), and allowing arbitrary
        // transitions is how duplicate recordings or late paste operations happen.
        switch (mode, next) {
        case (.idle, .preparing),
             (.preparing, .recording),
             (.recording, .transcribing),
             (.transcribing, .refining),
             (.transcribing, .injecting),
             (.refining, .injecting),
             (.injecting, .idle),
             (.preparing, .idle),
             (.recording, .idle),
             (.transcribing, .idle),
             (.refining, .idle):
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
