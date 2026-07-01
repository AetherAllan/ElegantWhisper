import Foundation

final class CorrectionEngine {
    func correct(_ text: String, entries: [DictionaryEntry]) -> String {
        var corrected = text

        for entry in entries {
            for alias in entry.aliases where !alias.isEmpty {
                corrected = replace(alias: alias, with: entry.term, in: corrected)
            }
        }

        return corrected
    }

    private func replace(alias: String, with term: String, in text: String) -> String {
        guard aliasContainsASCIIWord(alias) else {
            return text.replacingOccurrences(of: alias, with: term)
        }
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: alias))\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        // ASCII aliases need word boundaries. "js" should become "JavaScript", but "json"
        // must stay untouched. Chinese aliases intentionally use direct replacement because
        // they do not have whitespace word boundaries.
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: NSRegularExpression.escapedTemplate(for: term)
        )
    }

    private func aliasContainsASCIIWord(_ alias: String) -> Bool {
        alias.unicodeScalars.contains { scalar in
            CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII
        }
    }
}
