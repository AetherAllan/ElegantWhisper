import Foundation
import NaturalLanguage

struct LearningTextSnapshot {
    let beforeValue: String
    let selectedRangeBeforeInsertion: NSRange
    let insertedText: String
    let expectedRangeAfterInsertion: NSRange
    let prefixAnchor: String
    let suffixAnchor: String
}

struct LearningCandidateDraft: Equatable {
    let original: String
    let replacement: String
}

enum LearningDiffEngine {
    static func candidate(snapshot: LearningTextSnapshot, currentValue: String) -> LearningCandidateDraft? {
        guard let expectedValue = expectedValue(from: snapshot),
              expectedValue != currentValue,
              anchorsStillExist(snapshot: snapshot, in: currentValue)
        else {
            return nil
        }

        let expected = expectedValue as NSString
        let current = currentValue as NSString
        var prefixLength = 0
        while prefixLength < expected.length,
              prefixLength < current.length,
              expected.character(at: prefixLength) == current.character(at: prefixLength)
        {
            prefixLength += 1
        }

        var suffixLength = 0
        while suffixLength < expected.length - prefixLength,
              suffixLength < current.length - prefixLength,
              expected.character(at: expected.length - suffixLength - 1) == current.character(at: current.length - suffixLength - 1)
        {
            suffixLength += 1
        }

        let rawOriginalRange = NSRange(location: prefixLength, length: expected.length - prefixLength - suffixLength)
        let rawReplacementRange = NSRange(location: prefixLength, length: current.length - prefixLength - suffixLength)
        guard rawOriginalRange.length > 0, rawReplacementRange.length > 0 else { return nil }

        let originalRange = expandedWordRange(rawOriginalRange, in: expectedValue)
        let replacementRange = expandedWordRange(rawReplacementRange, in: currentValue)
        guard contains(snapshot.expectedRangeAfterInsertion, originalRange) else { return nil }

        let original = expected.substring(with: originalRange).trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = current.substring(with: replacementRange).trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSafeDictionaryPair(
            original: original,
            replacement: replacement,
            originalRange: originalRange,
            insertedText: snapshot.insertedText
        ) else {
            return nil
        }
        return LearningCandidateDraft(original: original, replacement: replacement)
    }

    private static func expectedValue(from snapshot: LearningTextSnapshot) -> String? {
        let before = snapshot.beforeValue as NSString
        guard NSMaxRange(snapshot.selectedRangeBeforeInsertion) <= before.length else { return nil }
        return before.replacingCharacters(in: snapshot.selectedRangeBeforeInsertion, with: snapshot.insertedText)
    }

    private static func anchorsStillExist(snapshot: LearningTextSnapshot, in currentValue: String) -> Bool {
        let current = currentValue as NSString
        return (snapshot.prefixAnchor.isEmpty || current.range(of: snapshot.prefixAnchor).location != NSNotFound)
            && (snapshot.suffixAnchor.isEmpty || current.range(of: snapshot.suffixAnchor).location != NSNotFound)
    }

    private static func contains(_ outer: NSRange, _ inner: NSRange) -> Bool {
        inner.location >= outer.location && NSMaxRange(inner) <= NSMaxRange(outer)
    }

    private static func isSafeDictionaryPair(
        original: String,
        replacement: String,
        originalRange: NSRange,
        insertedText: String
    ) -> Bool {
        guard !original.isEmpty, !replacement.isEmpty,
              original.count <= 64, replacement.count <= 64,
              hasLetterOrNumber(original), hasLetterOrNumber(replacement),
              !isSingleHanCharacter(replacement), wordCount(replacement) <= 2
        else {
            return false
        }

        // Learn corrected terms inside a transcript, not whole-sentence rewrites.
        let insertedLength = (insertedText as NSString).length
        guard insertedLength > 0, originalRange.length * 2 <= insertedLength else { return false }

        let smaller = max(1, min(original.count, replacement.count))
        let larger = max(original.count, replacement.count)
        return Double(larger) / Double(smaller) <= 3
    }

    private static func expandedWordRange(_ range: NSRange, in value: String) -> NSRange {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = value
        var result = range
        tokenizer.enumerateTokens(in: value.startIndex..<value.endIndex) { tokenRange, _ in
            let token = NSRange(tokenRange, in: value)
            if NSIntersectionRange(token, range).length > 0 {
                result = NSUnionRange(result, token)
            }
            return true
        }
        return result
    }

    private static func wordCount(_ value: String) -> Int {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = value
        var count = 0
        tokenizer.enumerateTokens(in: value.startIndex..<value.endIndex) { _, _ in
            count += 1
            return count <= 2
        }
        return count
    }

    private static func isSingleHanCharacter(_ value: String) -> Bool {
        guard value.count == 1, let scalar = value.unicodeScalars.first else { return false }
        return switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F: true
        default: false
        }
    }

    private static func hasLetterOrNumber(_ value: String) -> Bool {
        value.unicodeScalars.contains {
            CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
        }
    }
}
