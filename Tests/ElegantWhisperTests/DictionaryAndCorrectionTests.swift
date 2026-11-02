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

    func testSpeechVocabularyAddsFocusedTermsAfterStaticTerms() throws {
        let file = try temporaryFile()
        let store = DictionaryStore(fileURL: file)
        XCTAssertTrue(store.add(term: "SwiftUI", language: .simplifiedChinese))

        let terms = SpeechVocabulary.terms(
            stylePack: StylePackStore.builtinPacks[0],
            userDictionary: store,
            language: .simplifiedChinese,
            focusedTerms: ["AXObserver", "SwiftUI"]
        )

        XCTAssertTrue(terms.contains("AXObserver"))
        XCTAssertEqual(terms.filter { $0.lowercased() == "swiftui" }.count, 1)
        XCTAssertLessThan(
            terms.firstIndex(of: "SwiftUI") ?? Int.max,
            terms.firstIndex(of: "AXObserver") ?? Int.max
        )
    }

    func testFocusedTextSnapshotRespectsPrivacyLimits() {
        XCTAssertEqual(
            AXFocusedTextContextReader.snippets(from: AXFocusedTextSnapshot(
                isSecure: true,
                selectedText: "SwiftUI",
                visibleText: "AXObserver"
            )),
            []
        )

        let longSelected = String(repeating: "A", count: 2_001)
        let snippets = AXFocusedTextContextReader.snippets(from: AXFocusedTextSnapshot(
            isSecure: false,
            selectedText: longSelected,
            visibleText: "OpenRouter and AppKit"
        ))

        XCTAssertEqual(snippets, ["OpenRouter and AppKit"])

        let longVisible = String(repeating: "B", count: 4_001)
        XCTAssertEqual(
            AXFocusedTextContextReader.snippets(from: AXFocusedTextSnapshot(
                isSecure: false,
                selectedText: nil,
                visibleText: longVisible
            )),
            []
        )
    }

    func testVocabularyHintsMergeFocusedTermsBeforeSeedTerms() {
        let hints = SpeechFocusContext.vocabularyHints(
            focused: ["SwiftUI", "AXObserver"],
            seed: ["Python", "TypeScript", "SwiftUI"]
        )

        XCTAssertEqual(hints.prefix(2), ["SwiftUI", "AXObserver"])
        XCTAssertTrue(hints.contains("Python"))
        XCTAssertEqual(hints.filter { $0.caseInsensitiveCompare("SwiftUI") == .orderedSame }.count, 1)
        XCTAssertLessThanOrEqual(hints.count, SpeechFocusContext.vocabularyHintLimit)
    }

    func testFocusedTermExtractorKeepsTechnicalTermsOnly() {
        let terms = SpeechContextTermExtractor.terms(from: [
            "the button 然后 SwiftUI AppKit AXObserver OpenRouter GPT-5.5 dbf5d503 2026-07-05 3.14 1/2 https://example.com/path sk-test ghp_secret user"
        ])

        XCTAssertTrue(terms.contains("SwiftUI"))
        XCTAssertTrue(terms.contains("AppKit"))
        XCTAssertTrue(terms.contains("AXObserver"))
        XCTAssertTrue(terms.contains("OpenRouter"))
        XCTAssertTrue(terms.contains("GPT-5.5"))
        XCTAssertTrue(terms.contains("dbf5d503"))
        XCTAssertFalse(terms.contains("the"))
        XCTAssertFalse(terms.contains("button"))
        XCTAssertFalse(terms.contains("user"))
        XCTAssertFalse(terms.contains { $0.hasPrefix("sk-") })
        XCTAssertFalse(terms.contains { $0.hasPrefix("ghp_") })
        XCTAssertFalse(terms.contains("example.com/path"))
        XCTAssertFalse(terms.contains("2026-07-05"))
        XCTAssertFalse(terms.contains("3.14"))
        XCTAssertFalse(terms.contains("1/2"))
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

final class CursorTextContextTests: XCTestCase {
    func testCursorTextIsBoundedAndRedacted() throws {
        let before = String(repeating: "lorem ", count: 100) + " mail me at dev@example.com, key sk-abc123 see https://x.dev/p ok"
        let context = try XCTUnwrap(CursorTextContext(before: before, after: String(repeating: "word ", count: 60)))

        XCTAssertLessThanOrEqual(context.before.count, CursorTextContext.beforeLimit)
        XCTAssertEqual(context.after.count, CursorTextContext.afterLimit)
        XCTAssertFalse(context.before.contains("dev@example.com"))
        XCTAssertFalse(context.before.contains("sk-abc123"))
        XCTAssertFalse(context.before.contains("https://x.dev"))
        XCTAssertTrue(context.before.hasSuffix("[redacted] ok"))
    }

    func testEmptyCursorTextIsDropped() {
        XCTAssertNil(CursorTextContext(before: "  \n", after: ""))
    }

    func testPromptSectionFencesCursorText() throws {
        let cursor = try XCTUnwrap(CursorTextContext(before: "Deploy to Kubernetes via ", after: " tonight."))
        let context = SpeechFocusContext(appName: "Notes", terms: [], cursorText: cursor)
        let section = try XCTUnwrap(context.promptSection)

        XCTAssertTrue(section.hasPrefix("Local context:"))
        XCTAssertTrue(section.contains("<editor_text>Deploy to Kubernetes via [CURSOR] tonight.</editor_text>"))
        XCTAssertNil(SpeechFocusContext(appName: nil, terms: []).promptSection)
    }
}
