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

    func testContextualStringsUseCorrectTermsOnly() throws {
        let file = try temporaryFile()
        let store = DictionaryStore(fileURL: file)
        XCTAssertTrue(store.add(term: "JSON", aliases: ["杰森"], language: .simplifiedChinese))

        XCTAssertEqual(store.contextualStrings(for: .simplifiedChinese), ["JSON"])
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

    func testASCIIAliasWorksNextToChineseText() {
        let entries = [
            DictionaryEntry(term: "refine", aliases: ["HryFine"], language: .simplifiedChinese),
            DictionaryEntry(term: "TypeScript", aliases: ["Tapes script"], language: .simplifiedChinese)
        ]
        let result = CorrectionEngine().correct(
            "让我看现在这个HryFine工作了吗，我喜欢Tapes script。",
            entries: entries
        )

        XCTAssertEqual(
            result,
            "让我看现在这个refine工作了吗，我喜欢TypeScript。"
        )
    }

    func testNoBuiltInCorrectionRewritesUSBDriveMention() {
        let result = CorrectionEngine().correct("这个U盘需要格式化", entries: [])

        XCTAssertEqual(result, "这个U盘需要格式化")
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
