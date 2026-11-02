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

final class VocabularyCorrectorTests: XCTestCase {
    private let terms = ["Redis", "TypeScript", "GitHub", "Docker", "Python", "Cursor", "SQL"]
    private let englishWords: Set<String> = ["radios", "python", "cursor", "ready", "red", "get", "up", "type", "script", "typescript"]

    private func correct(_ text: String) -> VocabularyCorrector.Result {
        VocabularyCorrector.correct(text, terms: terms) { self.englishWords.contains($0) }
    }

    func testFixesRealNewerModelMistakes() {
        // Output from Apple's SpeechTranscriber for "...restart the Redis container, and then push the TypeScript changes".
        XCTAssertEqual(
            correct("restart the redisk container, and then push the typescript changes to GitHub").text,
            "restart the Redis container, and then push the TypeScript changes to GitHub"
        )
        XCTAssertEqual(
            correct("我想用ison解析这个 JSON文件，然后把结果写入 readios缓存最后提交到 Githop。").text,
            "我想用ison解析这个 JSON文件，然后把结果写入 Redis缓存最后提交到 GitHub。"
        )
    }

    func testJoinsSplitCompoundAndFixesCasing() {
        let result = correct("push the type script changes from docker and run sql")
        XCTAssertEqual(result.text, "push the TypeScript changes from Docker and run SQL")
        XCTAssertEqual(result.corrections, 3)
    }

    func testLeavesRealWordsAndWeakMatchesAlone() {
        let text = "I listened to the radios while the python slept, then moved the cursor to the red ready box"
        XCTAssertEqual(correct(text), VocabularyCorrector.Result(text: text, corrections: 0))
        // "ison" was a garbled "Python"; a different first letter keeps it from becoming "JSON".
        XCTAssertEqual(VocabularyCorrector.correct("用ison解析", terms: ["JSON"]) { _ in false }.text, "用ison解析")
    }

    func testJoinsNameSplitAcrossAHanCharacter() {
        // Real output for "ElegantWhisper" dictated in Chinese mode.
        let result = VocabularyCorrector.correct(
            "Electron App Elegan的 Visper Man",
            terms: ["ElegantWhisper", "Electron"]
        ) { ["electron", "app", "man"].contains($0) }
        XCTAssertEqual(result.text, "Electron App ElegantWhisper Man")
        XCTAssertEqual(result.corrections, 1)
    }

    func testDoesNotJoinRealWordsOrWeakMatches() {
        // Real words on either side never merge, even with a matching long term on screen.
        XCTAssertEqual(
            VocabularyCorrector.correct("red的 iris and elegant whisker", terms: ["Rediris", "ElegantWhisper"]) {
                ["red", "iris", "and", "elegant", "whisker"].contains($0)
            }.text,
            "red的 iris and elegant whisker"
        )
        // Two unknown fragments that are not close to any long term stay as they are.
        XCTAssertEqual(
            VocabularyCorrector.correct("Zorp的 Quax", terms: ["ElegantWhisper"]) { _ in false }.text,
            "Zorp的 Quax"
        )
    }

    func testDictionaryTermsFixCasingOfEnglishWordsButScreenTermsDoNot() {
        let isKnown: (String) -> Bool = { ["slack", "check"].contains($0) }
        XCTAssertEqual(
            VocabularyCorrector.correct("check slack later", userTerms: ["Slack"], terms: [], isKnownWord: isKnown).text,
            "check Slack later"
        )
        XCTAssertEqual(
            VocabularyCorrector.correct("check slack later", terms: ["Slack"], isKnownWord: isKnown).text,
            "check slack later"
        )
        // The user's spelling wins over the screen's when both are present.
        XCTAssertEqual(
            VocabularyCorrector.correct("open github", userTerms: ["Github"], terms: ["GitHub"]) { _ in false }.text,
            "open Github"
        )
    }

    func testPluralAndTiesAndNoTerms() {
        XCTAssertEqual(correct("restart both dockers").text, "restart both Dockers")
        // Equally close to two terms: leave it.
        XCTAssertEqual(VocabularyCorrector.correct("crate", terms: ["Crane", "Crave"]) { _ in false }.text, "crate")
        XCTAssertEqual(VocabularyCorrector.correct("redisk", terms: []) { _ in false }.corrections, 0)
    }
}

final class WindowTextReaderTests: XCTestCase {
    private struct FakeElement {
        var role = "AXGroup"
        var texts: [String] = []
        var children: [FakeElement] = []
    }

    private func collect(_ root: FakeElement, limits: AXWindowTextReader.Limits = .init(), now: @escaping () -> TimeInterval = { 0 }) -> AXWindowTextReader.Collected {
        AXWindowTextReader.collectTexts(root: root, limits: limits, now: now) { element in
            var node = AXWindowTextReader.Node<FakeElement>()
            node.isSecure = element.role == "AXSecureTextField"
            node.isChrome = element.role == "AXToolbar"
            node.texts = element.texts
            node.children = element.children
            return node
        }
    }

    func testCollectsTextBreadthFirstAndSkipsSecureFieldsAndChrome() {
        let window = FakeElement(children: [
            FakeElement(role: "AXToolbar", children: [FakeElement(role: "AXStaticText", texts: ["File Edit View"])]),
            FakeElement(role: "AXStaticText", texts: ["Deploy the useEffect hook to staging"]),
            FakeElement(role: "AXSecureTextField", texts: ["hunter2-secret"]),
            FakeElement(children: [FakeElement(role: "AXStaticText", texts: ["Restart Redis after the K8s rollout"])]),
        ])

        let collected = collect(window)

        XCTAssertEqual(collected.texts, ["Deploy the useEffect hook to staging", "Restart Redis after the K8s rollout"])
        XCTAssertFalse(collected.stoppedEarly)
        XCTAssertEqual(SpeechContextTermExtractor.terms(from: collected.texts), ["useEffect", "K8s"])
        // Window text also yields capitalized names such as "Redis", after the technical tokens.
        XCTAssertEqual(
            SpeechContextTermExtractor.windowTerms(from: collected.texts + ["Ask Redis team"]),
            ["useEffect", "K8s", "Redis", "Deploy", "Restart"]
        )
    }

    func testStopsAtElementCharacterAndTimeLimits() {
        let wide = FakeElement(children: (0..<50).map { FakeElement(role: "AXStaticText", texts: ["row \($0) text"]) })
        var limits = AXWindowTextReader.Limits()
        limits.maxElements = 10
        let byCount = collect(wide, limits: limits)
        XCTAssertEqual(byCount.visited, 10)
        XCTAssertTrue(byCount.stoppedEarly)

        limits = AXWindowTextReader.Limits()
        limits.maxCharacters = 25
        let byCharacters = collect(wide, limits: limits)
        XCTAssertLessThanOrEqual(byCharacters.characters, 25)
        XCTAssertTrue(byCharacters.stoppedEarly)

        var clock: TimeInterval = 0
        let byTime = collect(wide, now: {
            clock += 0.05
            return clock
        })
        XCTAssertTrue(byTime.stoppedEarly)
        XCTAssertLessThan(byTime.visited, 10)
    }
}
