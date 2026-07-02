@testable import ElegantWhisper
import XCTest

final class DictionaryAndCorrectionTests: XCTestCase {
    func testDictionaryPersistsEntries() throws {
        let file = try temporaryFile()
        let store = DictionaryStore(fileURL: file)

        XCTAssertTrue(store.add(term: "Python", aliases: ["配森", "派森"], language: .simplifiedChinese))

        let reloaded = DictionaryStore(fileURL: file)
        let entries = reloaded.entries(for: .simplifiedChinese)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].term, "Python")
        XCTAssertEqual(Set(entries[0].aliases), ["配森", "派森"])
    }

    func testCorrectionUsesAliasesConservatively() {
        let entry = DictionaryEntry(term: "Python", aliases: ["配森"], language: .simplifiedChinese)
        let result = CorrectionEngine().correct("我在写配森脚本", entries: [entry])

        XCTAssertEqual(result, "我在写Python脚本")
    }

    func testASCIIAliasDoesNotReplaceInsideAnotherWord() {
        let entry = DictionaryEntry(term: "JavaScript", aliases: ["js"], language: .englishUS)
        let result = CorrectionEngine().correct("json and js", entries: [entry])

        XCTAssertEqual(result, "json and JavaScript")
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

    func testTranscriptAccumulatorReplacesVolatileTextInsteadOfAppendingIt() {
        var accumulator = TranscriptAccumulator()

        XCTAssertEqual(accumulator.update(text: "hello wor", isFinal: false), "hello wor")
        XCTAssertEqual(accumulator.update(text: "hello world", isFinal: false), "hello world")
        XCTAssertEqual(accumulator.update(text: "hello world", isFinal: true), "hello world")
        XCTAssertEqual(accumulator.update(text: " again", isFinal: false), "hello world again")
    }

    private func temporaryFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ElegantWhisperTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("dictionary.json")
    }
}
