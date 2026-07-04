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
        let escapedAlias = NSRegularExpression.escapedPattern(for: alias)
        let pattern = "(?<![A-Za-z0-9_])\(escapedAlias)(?![A-Za-z0-9_])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        // ASCII aliases need ASCII-only boundaries. Foundation's `\b` treats Chinese neighbors
        // inconsistently for our use case, so "HryFine" next to Chinese text must still match,
        // while "js" inside "json" must stay untouched.
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
