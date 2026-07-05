import ApplicationServices
import Foundation

struct SpeechFocusContext: Equatable, Sendable {
    let appName: String?
    let terms: [String]

    init(appName: String?, terms: [String]) {
        self.appName = Self.cleanAppName(appName)
        self.terms = Array(terms.prefix(12))
    }

    var isEmpty: Bool {
        appName == nil && terms.isEmpty
    }

    var promptSection: String? {
        guard !isEmpty else {
            return nil
        }
        var lines = [
            "Local context: use only to resolve ambiguous ASR spellings; do not add new facts."
        ]
        if let appName {
            lines.append("App: \(appName)")
        }
        if !terms.isEmpty {
            lines.append("Terms: \(terms.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }

    private static func cleanAppName(_ raw: String?) -> String? {
        guard let raw else {
            return nil
        }
        let value = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return nil
        }
        return String(value.prefix(40))
    }
}

struct AXFocusedTextSnapshot {
    let isSecure: Bool
    let selectedText: String?
    let visibleText: String?
}

enum AXFocusedTextContextReader {
    private static let selectedTextLimit = 2_000
    private static let visibleTextLimit = 4_000

    static func snippets(from target: FocusTarget?) -> [String] {
        guard let target, !isSecureField(target.element) else {
            return []
        }
        return snippets(from: AXFocusedTextSnapshot(
            isSecure: false,
            selectedText: stringAttribute(target.element, kAXSelectedTextAttribute),
            visibleText: visibleText(target.element)
        ))
    }

    static func snippets(from snapshot: AXFocusedTextSnapshot) -> [String] {
        guard !snapshot.isSecure else {
            return []
        }
        var snippets: [String] = []
        append(snapshot.selectedText, limit: selectedTextLimit, to: &snippets)
        append(snapshot.visibleText, limit: visibleTextLimit, to: &snippets)
        return snippets
    }

    private static func append(_ raw: String?, limit: Int, to snippets: inout [String]) {
        guard let raw else {
            return
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= limit, !snippets.contains(value) else {
            return
        }
        snippets.append(value)
    }

    private static func visibleText(_ element: AXUIElement) -> String? {
        guard let range = visibleCharacterRange(element) else {
            return nil
        }
        // Keep the privacy bound before asking AX for the actual text. Some apps can expose a
        // very large visible range, and fetching it first would defeat the "small local hint"
        // rule even if append() later discards the oversized string.
        guard range.length <= visibleTextLimit else {
            return nil
        }
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let axRange = AXValueCreate(.cfRange, &cfRange) else {
            return nil
        }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            axRange,
            &value
        ) == .success else {
            return nil
        }
        return value as? String
    }

    private static func visibleCharacterRange(_ element: AXUIElement) -> NSRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXVisibleCharacterRangeAttribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID()
        else {
            return nil
        }
        var range = CFRange()
        guard AXValueGetValue((value as! AXValue), .cfRange, &range),
              range.location >= 0,
              range.length > 0
        else {
            return nil
        }
        return NSRange(location: range.location, length: range.length)
    }

    private static func isSecureField(_ element: AXUIElement) -> Bool {
        stringAttribute(element, kAXRoleAttribute) == "AXSecureTextField" ||
            stringAttribute(element, kAXSubroleAttribute) == "AXSecureTextField"
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }
}

enum SpeechContextTermExtractor {
    private static let tokenRegex = try! NSRegularExpression(pattern: "[A-Za-z0-9]+(?:[._/-][A-Za-z0-9]+)*")
    private static let privateTextRegex = try! NSRegularExpression(pattern: "(https?://\\S+|www\\.\\S+|\\S+@\\S+)")
    private static let camelRegex = try! NSRegularExpression(pattern: "([a-z][A-Z]|[A-Z][a-z]+[A-Z])")
    private static let stopwords: Set<String> = [
        "the", "and", "click", "button", "window", "settings", "today", "message", "user"
    ]
    private static let knownTerms: Set<String> = [
        "python", "typescript", "javascript", "openrouter", "moonshot", "kimi",
        "json", "api", "sdk", "cli", "sql", "web3", "sui", "swiftui", "appkit",
        "axobserver", "sfspeechrecognitionrequest", "contextualstrings", "openai-compatible",
        "gpt-5.5", "glm-5.2", "claude", "cursor", "ide"
    ]

    static func terms(from snippets: [String], limit: Int = 30) -> [String] {
        var seen = Set<String>()
        var terms: [String] = []
        for snippet in snippets {
            for token in tokens(in: snippet) {
                guard terms.count < limit else {
                    return terms
                }
                let key = token.lowercased()
                guard seen.insert(key).inserted else {
                    continue
                }
                terms.append(token)
            }
        }
        return terms
    }

    private static func tokens(in text: String) -> [String] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let scrubbed = privateTextRegex.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
        let scrubbedRange = NSRange(scrubbed.startIndex..<scrubbed.endIndex, in: scrubbed)
        return tokenRegex.matches(in: scrubbed, range: scrubbedRange).compactMap { match in
            guard let range = Range(match.range, in: scrubbed) else {
                return nil
            }
            let token = String(scrubbed[range])
            return isHighValue(token) ? token : nil
        }
    }

    private static func isHighValue(_ token: String) -> Bool {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...64).contains(value.count),
              !stopwords.contains(value.lowercased()),
              !looksPrivate(value)
        else {
            return false
        }
        if knownTerms.contains(value.lowercased()) {
            return true
        }
        if isAllCaps(value) {
            return true
        }
        if containsLetter(value), containsDigit(value) {
            return true
        }
        if containsTechnicalSeparator(value), containsLetter(value) {
            return true
        }
        return camelRegex.firstMatch(in: value, range: NSRange(value.startIndex..<value.endIndex, in: value)) != nil
    }

    private static func isAllCaps(_ value: String) -> Bool {
        let letters = value.filter(\.isLetter)
        return (2...12).contains(letters.count) && letters.allSatisfy { $0.isUppercase }
    }

    private static func containsLetter(_ value: String) -> Bool {
        value.contains { $0.isLetter }
    }

    private static func containsDigit(_ value: String) -> Bool {
        value.contains { $0.isNumber }
    }

    private static func containsTechnicalSeparator(_ value: String) -> Bool {
        value.contains(".") || value.contains("_") || value.contains("-") || value.contains("/")
    }

    private static func looksPrivate(_ value: String) -> Bool {
        let lower = value.lowercased()
        if lower.hasPrefix("sk-") || lower.hasPrefix("ghp_") || lower.hasPrefix("xoxb-") {
            return true
        }
        if lower.contains("password") || lower.contains("secret") || lower.contains("api_key") || lower.contains("token") {
            return true
        }
        if value.count >= 24, value.allSatisfy(\.isHexDigit) {
            return true
        }
        return value.count >= 32 && value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "/" || $0 == "=" }
    }
}
