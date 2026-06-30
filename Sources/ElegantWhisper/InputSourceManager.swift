import Carbon
import Foundation

final class InputSourceManager {
    typealias InputSource = TISInputSource

    func switchToASCIIIfNeeded() -> InputSource? {
        guard let current = currentInputSource(), isCJK(current), let ascii = asciiInputSource() else {
            return nil
        }
        TISSelectInputSource(ascii)
        return current
    }

    func restore(_ source: InputSource?) {
        guard let source else {
            return
        }
        TISSelectInputSource(source)
    }

    private func currentInputSource() -> InputSource? {
        guard let unmanaged = TISCopyCurrentKeyboardInputSource() else {
            return nil
        }
        return unmanaged.takeRetainedValue()
    }

    private func asciiInputSource() -> InputSource? {
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
}
