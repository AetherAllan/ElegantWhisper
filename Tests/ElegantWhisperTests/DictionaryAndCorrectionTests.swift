@testable import ElegantWhisper
import XCTest

final class DictionaryAndCorrectionTests: XCTestCase {
    func testDictionaryPersistsEntries() throws {
        let file = try temporaryFile()
        let store = DictionaryStore(fileURL: file)

        XCTAssertTrue(store.add(term: "Python", language: .simplifiedChinese))

        let reloaded = DictionaryStore(fileURL: file)
        let entries = reloaded.entries(for: .simplifiedChinese)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].term, "Python")
    }

    func testDictionaryTermsUseTerms() throws {
        let file = try temporaryFile()
        let store = DictionaryStore(fileURL: file)
        XCTAssertTrue(store.add(term: "JSON", language: .simplifiedChinese))

        XCTAssertEqual(store.terms(for: .simplifiedChinese), ["JSON"])
    }

    func testSpeechVocabularyMergesStyleSeedsAndUserTerms() throws {
        let file = try temporaryFile()
        let store = DictionaryStore(fileURL: file)
        XCTAssertTrue(store.add(term: "python", language: .simplifiedChinese))
        XCTAssertTrue(store.add(term: "ElegantWhisper", language: .simplifiedChinese))

        let terms = SpeechVocabulary.terms(
            stylePack: StylePackStore.builtinPacks[0],
            userDictionary: store,
            language: .simplifiedChinese
        )

        XCTAssertTrue(terms.contains("Python"))
        XCTAssertTrue(terms.contains("IDE"))
        XCTAssertTrue(terms.contains("ElegantWhisper"))
        XCTAssertEqual(terms.filter { $0.lowercased() == "python" }.count, 1)
        XCTAssertLessThanOrEqual(terms.count, SpeechVocabulary.defaultLimit)
    }

    func testSpeechVocabularyLimitKeepsSeedTermsFirst() throws {
        let file = try temporaryFile()
        let store = DictionaryStore(fileURL: file)
        XCTAssertTrue(store.add(term: "UserOnly", language: .simplifiedChinese))

        let terms = SpeechVocabulary.terms(
            stylePack: StylePackStore.builtinPacks[0],
            userDictionary: store,
            language: .simplifiedChinese,
            limit: 2
        )

        XCTAssertEqual(terms, Array(StylePackStore.seedTerms(for: StylePackStore.programmerPackID).prefix(2)))
    }

    func testSpeechVocabularyChangesWithStylePack() throws {
        let file = try temporaryFile()
        let store = DictionaryStore(fileURL: file)

        let programmer = SpeechVocabulary.terms(
            stylePack: StylePackStore.builtinPacks[0],
            userDictionary: store,
            language: .simplifiedChinese
        )
        let technical = SpeechVocabulary.terms(
            stylePack: StylePackStore.builtinPacks[3],
            userDictionary: store,
            language: .simplifiedChinese
        )

        XCTAssertNotEqual(programmer, technical)
    }

    func testLegacyDictionaryMigratesAliasesAway() throws {
        let file = try temporaryFile()
        let legacy = """
        [{"id":"\(UUID().uuidString)","term":"Python","aliases":["配森","派森"],"language":"zh-CN"}]
        """
        try legacy.write(to: file, atomically: true, encoding: .utf8)

        let store = DictionaryStore(fileURL: file)
        let entries = store.entries(for: .simplifiedChinese)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].term, "Python")

        let saved = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(saved.contains("aliases"))
    }

    func testDuplicateTermUpdatesInPlace() throws {
        let file = try temporaryFile()
        let store = DictionaryStore(fileURL: file)

        XCTAssertTrue(store.add(term: "python", language: .englishUS))
        XCTAssertTrue(store.add(term: "Python", language: .englishUS))

        XCTAssertEqual(store.entries(for: .englishUS).count, 1)
        XCTAssertEqual(store.entries(for: .englishUS)[0].term, "Python")
    }

    func testHistoryDefaultsToEnabled() {
        let suiteName = "com.aetherallan.ElegantWhisper.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsStore(defaults: defaults, keychain: KeychainStore(service: suiteName))

        XCTAssertTrue(settings.saveHistory)

        settings.saveHistory = false
        XCTAssertFalse(settings.saveHistory)
    }

    private func temporaryFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ElegantWhisperTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("dictionary.json")
    }
}
