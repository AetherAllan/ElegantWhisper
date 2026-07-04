import Carbon
import Foundation

// TISInputSource is a Carbon reference type. The snapshot is only used on the
// main thread around one paste operation, but Dispatch/Task delay APIs still
// require captured values to be Sendable under Swift 6.
struct InputSourceSnapshot: @unchecked Sendable {
    let source: TISInputSource
    let temporaryASCIIInputSourceID: String
}

@MainActor
final class InputSourceManager {
    typealias InputSource = TISInputSource

    func switchToASCIIIfNeeded() -> InputSourceSnapshot? {
        // CJK input methods can treat simulated Cmd+V differently while a composition buffer is
        // active. Temporarily switching to ABC/US keeps paste as a plain command, then we restore
        // the user's original input source after the target app has consumed the clipboard.
        guard let current = currentInputSource(), isCJK(current), let ascii = asciiInputSource() else {
            return nil
        }
        TISSelectInputSource(ascii)
        return InputSourceSnapshot(source: current, temporaryASCIIInputSourceID: sourceID(ascii))
    }

    func restore(_ snapshot: InputSourceSnapshot?) {
        guard let snapshot else {
            return
        }
        guard currentInputSource().map(sourceID) == snapshot.temporaryASCIIInputSourceID else {
            return
        }
        TISSelectInputSource(snapshot.source)
    }

    private func currentInputSource() -> InputSource? {
        guard let unmanaged = TISCopyCurrentKeyboardInputSource() else {
            return nil
        }
        return unmanaged.takeRetainedValue()
    }

    private func asciiInputSource() -> InputSource? {
        // ABC is the modern macOS default; US is kept as a fallback for older or customized setups.
        for id in ["com.apple.keylayout.ABC", "com.apple.keylayout.US"] {
            let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
            guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [InputSource],
                  let source = list.first
            else {
                continue
            }
            return source
        }
        return nil
    }

    private func isCJK(_ source: InputSource) -> Bool {
        // TIS does not expose one stable "is CJK input method" flag. Check both source ids and
        // language metadata so common Apple and third-party Chinese/Japanese/Korean IMEs match.
        let id = property(source, kTISPropertyInputSourceID)
        let languages = property(source, kTISPropertyInputSourceLanguages)
        let haystack = "\(id) \(languages)".lowercased()
        return haystack.contains("zh")
            || haystack.contains("ja")
            || haystack.contains("ko")
            || haystack.contains("pinyin")
            || haystack.contains("kotoeri")
            || haystack.contains("hangul")
            || haystack.contains("hiragana")
    }

    private func property(_ source: InputSource, _ key: CFString) -> String {
        guard let value = TISGetInputSourceProperty(source, key) else {
            return ""
        }
        return String(describing: Unmanaged<CFTypeRef>.fromOpaque(value).takeUnretainedValue())
    }

    private func sourceID(_ source: InputSource) -> String {
        property(source, kTISPropertyInputSourceID)
    }
}
