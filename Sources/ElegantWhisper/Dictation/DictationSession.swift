import AppKit
import Foundation

struct DictationSession: Identifiable {
    let id = UUID()
    let originalTarget: FocusTarget?
    let originalApplication: NSRunningApplication?
    /// Terms for the post-recognition spelling pass. Dictionary terms are kept apart because they
    /// may also fix the casing of ordinary English words.
    var dictionaryTerms: [String] = []
    /// On-screen words and Style Pack terms.
    var correctionTerms: [String] = []
    /// Background read of technical words in the front window, started when recording starts.
    var windowTerms: Task<[String], Never>?
}
