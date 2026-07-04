import AppKit
import Foundation

struct DictationSession: Identifiable {
    let id = UUID()
    let originalTarget: FocusTarget?
    let originalApplication: NSRunningApplication?
}
