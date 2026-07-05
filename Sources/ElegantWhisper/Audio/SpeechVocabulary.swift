import Foundation

enum SpeechVocabulary {
    static let defaultLimit = 80

    static func terms(
        stylePack: StylePack,
        userDictionary: DictionaryStore,
        language: RecognitionLanguage,
        limit: Int = defaultLimit
    ) -> [String] {
        var seen = Set<String>()
        var values: [String] = []

        func append(_ raw: String) {
            guard values.count < limit else { return }
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { return }
            let key = term.lowercased()
            guard seen.insert(key).inserted else { return }
            values.append(term)
        }

        StylePackStore.seedTerms(for: stylePack.id).forEach(append)
        userDictionary.terms(for: language, limit: 500).forEach(append)
        return values
    }
}
