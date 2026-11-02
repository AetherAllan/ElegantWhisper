import AppKit
import Foundation

/// Fixes near-miss spellings of known terms after recognition, on device.
///
/// The newer SpeechTranscriber model ignores contextual strings, so without this pass Dictionary
/// terms, Style Pack terms, and words read from the focused field would only matter when LLM
/// polishing is on. It is deliberately conservative: it only touches Latin-script words, and only
/// rewrites a word that is a close match for a term (same first letter, small edit distance) and
/// is not a correctly spelled English word on its own, so "radios" never becomes "Redis".
/// Dictionary terms are the exception for casing: the user added them on purpose, so "slack"
/// becomes "Slack" when "Slack" is in the Dictionary, but not when it was only seen on screen.
enum VocabularyCorrector {
    struct Result: Equatable {
        let text: String
        let corrections: Int
    }

    private struct Term {
        let canonical: String
        let key: String
        let isUserTerm: Bool
    }

    private struct Replacement {
        let range: NSRange
        let text: String
    }

    private static let wordRegex = try! NSRegularExpression(pattern: "[A-Za-z][A-Za-z0-9+#]*")
    private static let minimumFuzzyLength = 4
    /// A joined two-piece match must hit a long term: short terms would match random fragments.
    private static let minimumJoinedTermLength = 8
    /// Between two pieces of one split name: a space, or a single Han character the recognizer
    /// heard in the middle ("Elegan的 Visper" for "ElegantWhisper"), optionally with spaces.
    private static let splitGapRegex = try! NSRegularExpression(pattern: "^ ?[\\u4E00-\\u9FFF]? ?$")

    static func correct(
        _ text: String,
        userTerms: [String] = [],
        terms contextTerms: [String],
        isKnownWord: (String) -> Bool
    ) -> Result {
        let terms = prepare(userTerms: userTerms, contextTerms: contextTerms)
        guard !terms.isEmpty else {
            return Result(text: text, corrections: 0)
        }
        var exact: [String: Term] = [:]
        for term in terms where exact[term.key] == nil {
            exact[term.key] = term
        }

        let source = text as NSString
        let words = wordRegex.matches(in: text, range: NSRange(location: 0, length: source.length)).map(\.range)
        var replacements: [Replacement] = []
        var index = 0
        while index < words.count {
            let range = words[index]
            let word = source.substring(with: range)

            // Speech often splits compound names: "type script" -> "TypeScript".
            if index + 1 < words.count {
                let next = words[index + 1]
                let gap = source.substring(with: NSRange(location: NSMaxRange(range), length: next.location - NSMaxRange(range)))
                let nextWord = source.substring(with: next)
                if let term = joinedMatch(word, nextWord, gap: gap, exact: exact, terms: terms, isKnownWord: isKnownWord) {
                    replacements.append(Replacement(range: NSUnionRange(range, next), text: term.canonical))
                    index += 2
                    continue
                }
            }

            if let replacement = replacementText(for: word, exact: exact, terms: terms, isKnownWord: isKnownWord),
               replacement != word
            {
                replacements.append(Replacement(range: range, text: replacement))
            }
            index += 1
        }

        guard !replacements.isEmpty else {
            return Result(text: text, corrections: 0)
        }
        let output = NSMutableString(string: text)
        for replacement in replacements.reversed() {
            output.replaceCharacters(in: replacement.range, with: replacement.text)
        }
        return Result(text: output as String, corrections: replacements.count)
    }

    private static func replacementText(
        for word: String,
        exact: [String: Term],
        terms: [Term],
        isKnownWord: (String) -> Bool
    ) -> String? {
        let wordKey = key(word)
        let known = isKnownWord(word.lowercased())

        if let term = exact[wordKey] {
            // Casing fixes on ordinary English words ("python", "cursor") are left alone unless the
            // term's casing is distinctive, as in "TypeScript", "GitHub", or "SQL", or the user put
            // the term in their Dictionary.
            return !known || term.isUserTerm || hasDistinctiveCasing(term.canonical) ? term.canonical : nil
        }
        if wordKey.hasSuffix("s"), let term = exact[String(wordKey.dropLast())], !known {
            return term.canonical + "s"
        }

        guard wordKey.count >= minimumFuzzyLength, !known else {
            return nil
        }
        var best: (term: Term, distance: Int)?
        var tied = false
        for term in terms where term.key.count >= minimumFuzzyLength && term.key.first == wordKey.first {
            let longest = max(term.key.count, wordKey.count)
            guard abs(term.key.count - wordKey.count) <= 2 else { continue }
            let allowed = longest <= 5 ? 1 : 2
            let distance = editDistance(term.key, wordKey)
            guard distance <= allowed, Double(distance) / Double(longest) <= 0.34 else { continue }
            if let current = best {
                if distance < current.distance {
                    best = (term, distance)
                    tied = false
                } else if distance == current.distance, current.term.key != term.key {
                    tied = true
                }
            } else {
                best = (term, distance)
            }
        }
        // Two equally close terms means we cannot tell which one was said.
        return tied ? nil : best?.term.canonical
    }

    private static func joinedMatch(
        _ first: String,
        _ second: String,
        gap: String,
        exact: [String: Term],
        terms: [Term],
        isKnownWord: (String) -> Bool
    ) -> Term? {
        let joinedKey = key(first) + key(second)
        if gap == " ", let term = exact[joinedKey] {
            return term
        }
        // Fuzzy joins only when neither piece is a real word on its own and the gap is tiny.
        let gapRange = NSRange(gap.startIndex..<gap.endIndex, in: gap)
        guard !gap.isEmpty,
              splitGapRegex.firstMatch(in: gap, range: gapRange) != nil,
              !isKnownWord(first.lowercased()),
              !isKnownWord(second.lowercased())
        else {
            return nil
        }
        var best: (term: Term, distance: Int)?
        var tied = false
        for term in terms where term.key.count >= minimumJoinedTermLength && term.key.first == joinedKey.first {
            let longest = max(term.key.count, joinedKey.count)
            guard abs(term.key.count - joinedKey.count) <= 2 else { continue }
            let distance = editDistance(term.key, joinedKey)
            guard distance <= 3, Double(distance) / Double(longest) <= 0.25 else { continue }
            if let current = best {
                if distance < current.distance {
                    best = (term, distance)
                    tied = false
                } else if distance == current.distance {
                    tied = true
                }
            } else {
                best = (term, distance)
            }
        }
        return tied ? nil : best?.term
    }

    private static func prepare(userTerms: [String], contextTerms: [String]) -> [Term] {
        var seen = Set<String>()
        var terms: [Term] = []
        // User terms first so their spelling wins when the screen shows another casing.
        for (raw, isUserTerm) in userTerms.map({ ($0, true) }) + contextTerms.map({ ($0, false) }) {
            let canonical = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let termKey = key(canonical)
            // Only Latin-script terms; CJK homophones would need pinyin matching.
            guard canonical.unicodeScalars.allSatisfy(\.isASCII),
                  termKey.count >= 2,
                  seen.insert(termKey).inserted
            else {
                continue
            }
            terms.append(Term(canonical: canonical, key: termKey, isUserTerm: isUserTerm))
        }
        return terms
    }

    private static func key(_ value: String) -> String {
        String(value.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "+" || $0 == "#" })
    }

    private static func hasDistinctiveCasing(_ value: String) -> Bool {
        let letters = value.filter(\.isLetter)
        let uppercase = letters.filter(\.isUppercase).count
        return uppercase >= 2 || (uppercase == 1 && letters.first?.isUppercase == false)
    }

    private static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs)
        let b = Array(rhs)
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            current[0] = i
            for j in 1...max(b.count, 1) where !b.isEmpty {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return a.isEmpty ? b.count : previous[b.count]
    }
}

@MainActor
enum SystemSpelling {
    /// True when macOS spelling considers `word` a correctly spelled English word.
    static func isKnownWord(_ word: String) -> Bool {
        let misspelled = NSSpellChecker.shared.checkSpelling(
            of: word,
            startingAt: 0,
            language: "en",
            wrap: false,
            inSpellDocumentWithTag: 0,
            wordCount: nil
        )
        return misspelled.location == NSNotFound
    }
}
