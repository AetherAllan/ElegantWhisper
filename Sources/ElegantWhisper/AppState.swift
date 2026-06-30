import Foundation

enum AppMode: String {
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

final class AppState {
    private(set) var mode: AppMode = .idle

    func transition(to next: AppMode) -> Bool {
        switch (mode, next) {
        case (.idle, .recording),
             (.recording, .transcribing),
             (.transcribing, .refining),
             (.transcribing, .injecting),
             (.refining, .injecting),
             (.injecting, .idle),
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
