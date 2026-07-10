@testable import ElegantWhisper
import XCTest

final class LearningCandidateTests: XCTestCase {
    func testSmallReplacementCreatesCandidate() {
        let snapshot = snapshot(insertedText: "我用派森写脚本")
        let current = "我用 Python 写脚本"

        XCTAssertEqual(
            LearningDiffEngine.candidate(snapshot: snapshot, currentValue: current),
            LearningCandidateDraft(original: "派森", replacement: "Python")
        )
    }

    func testSingleHanCharacterDoesNotCreateCandidate() {
        let snapshot = snapshot(insertedText: "这里是精确测试")

        XCTAssertNil(LearningDiffEngine.candidate(snapshot: snapshot, currentValue: "这里是竞确测试"))
    }

    func testWholeSentenceReplacementDoesNotCreateCandidate() {
        let snapshot = snapshot(insertedText: "看看现在这个暴力史的效果怎么样了")

        XCTAssertNil(LearningDiffEngine.candidate(
            snapshot: snapshot,
            currentValue: "openrouter.ai/workspaces/default/keys"
        ))
    }

    func testMixedPhraseRewriteDoesNotCreateCandidate() {
        let snapshot = snapshot(insertedText: "我再说一句话看我能看清啊")

        XCTAssertNil(LearningDiffEngine.candidate(snapshot: snapshot, currentValue: "应该是transcribe"))
    }

    func testLargeRewriteDoesNotCreateCandidate() {
        let snapshot = snapshot(insertedText: "这个功能挺好用的")
        let current = "这个功能目前基本可用，但稳定性仍需验证"

        XCTAssertNil(LearningDiffEngine.candidate(snapshot: snapshot, currentValue: current))
    }

    func testDeletionDoesNotCreateCandidate() {
        let snapshot = snapshot(insertedText: "我用派森写脚本")
        let current = "我用写脚本"

        XCTAssertNil(LearningDiffEngine.candidate(snapshot: snapshot, currentValue: current))
    }

    func testOutsideInsertedRangeChangeDoesNotCreateCandidate() {
        let snapshot = LearningTextSnapshot(
            beforeValue: "prefix  suffix",
            selectedRangeBeforeInsertion: NSRange(location: 7, length: 0),
            insertedText: "派森",
            expectedRangeAfterInsertion: NSRange(location: 7, length: 2),
            prefixAnchor: "prefix ",
            suffixAnchor: " suffix"
        )

        XCTAssertNil(LearningDiffEngine.candidate(snapshot: snapshot, currentValue: "changed Python suffix"))
    }

    func testMissingAnchorDoesNotCreateCandidate() {
        let snapshot = LearningTextSnapshot(
            beforeValue: "prefix  suffix",
            selectedRangeBeforeInsertion: NSRange(location: 7, length: 0),
            insertedText: "派森",
            expectedRangeAfterInsertion: NSRange(location: 7, length: 2),
            prefixAnchor: "prefix ",
            suffixAnchor: " suffix"
        )

        XCTAssertNil(LearningDiffEngine.candidate(snapshot: snapshot, currentValue: "prefix Python"))
    }

    func testStoreMergesRepeatedCandidate() throws {
        let store = LearningCandidateStore(fileURL: try temporaryFile(named: "learning-candidates.json"))

        store.record(original: "派森", replacement: "Python", language: .simplifiedChinese, bundleIdentifier: "com.apple.TextEdit")
        let item = try XCTUnwrap(store.record(
            original: "派森",
            replacement: "Python",
            language: .simplifiedChinese,
            bundleIdentifier: "com.apple.TextEdit"
        ))

        XCTAssertEqual(item.occurrenceCount, 2)
        XCTAssertEqual(store.items().count, 1)
    }

    @MainActor
    func testDictionaryOnlyShowsRepeatedCandidates() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ElegantWhisperTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let candidates = LearningCandidateStore(fileURL: root.appendingPathComponent("candidates.json"))
        let model = DictionaryModel(
            dictionary: DictionaryStore(fileURL: root.appendingPathComponent("dictionary.json")),
            candidates: candidates,
            styles: StylePackStore(fileURL: root.appendingPathComponent("styles.json")),
            language: .simplifiedChinese
        )

        candidates.record(original: "派森", replacement: "Python", language: .simplifiedChinese, bundleIdentifier: "com.apple.TextEdit")
        model.reload()
        XCTAssertTrue(model.candidates.isEmpty)

        candidates.record(original: "派森", replacement: "Python", language: .simplifiedChinese, bundleIdentifier: "com.apple.TextEdit")
        model.reload()
        XCTAssertEqual(model.candidates.map(\.replacement), ["Python"])
    }

    func testAcceptCandidateAddsDictionaryTerm() throws {
        let dictionaryFile = try temporaryFile(named: "dictionary.json")
        let dictionary = DictionaryStore(fileURL: dictionaryFile)
        let candidate = LearningCandidate(
            original: "派森",
            replacement: "Python",
            language: .simplifiedChinese,
            bundleIdentifier: "com.apple.TextEdit"
        )

        XCTAssertTrue(dictionary.add(term: candidate.replacement, language: candidate.language))
        XCTAssertEqual(dictionary.terms(for: .simplifiedChinese), ["Python"])
    }

    func testLearningSettingDefaultsOff() {
        let suiteName = "ElegantWhisperTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(defaults: defaults, keychain: KeychainStore(service: suiteName))

        XCTAssertFalse(settings.postEditLearningEnabled)
    }

    @MainActor
    func testElegantWhisperFieldsDoNotStartLearningOrSaveHistory() {
        XCTAssertFalse(PostEditLearner.isSupportedApp(bundleIdentifier: AppConstants.bundleIdentifier))
        XCTAssertFalse(AppController.shouldSaveHistory(bundleIdentifier: AppConstants.bundleIdentifier))
        XCTAssertTrue(PostEditLearner.isSupportedApp(bundleIdentifier: "com.apple.TextEdit"))
        XCTAssertTrue(AppController.shouldSaveHistory(bundleIdentifier: "com.apple.TextEdit"))
    }

    @MainActor
    func testPostEditLearnerStopCanBeRepeated() {
        let learner = PostEditLearner()

        learner.stop()
        learner.stop()
    }

    @MainActor
    func testCallbackBoxWithNilSessionDoesNotScheduleRead() async throws {
        let spy = CallbackSchedulingSpy()
        let box = AXObserverCallbackBox(session: spy)
        let refcon = Unmanaged.passRetained(box).toOpaque()
        box.session = nil
        defer {
            Unmanaged<AXObserverCallbackBox>.fromOpaque(refcon).release()
        }

        AXObserverCallbackBox.scheduleRead(from: refcon)
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(spy.scheduleReadCount, 0)
    }

    @MainActor
    func testCallbackBoxSchedulesLiveSessionWeakly() async throws {
        let spy = CallbackSchedulingSpy()
        let box = AXObserverCallbackBox(session: spy)
        let refcon = Unmanaged.passRetained(box).toOpaque()
        defer {
            Unmanaged<AXObserverCallbackBox>.fromOpaque(refcon).release()
        }

        AXObserverCallbackBox.scheduleRead(from: refcon)
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(spy.scheduleReadCount, 1)
    }

    private func snapshot(insertedText: String) -> LearningTextSnapshot {
        LearningTextSnapshot(
            beforeValue: "",
            selectedRangeBeforeInsertion: NSRange(location: 0, length: 0),
            insertedText: insertedText,
            expectedRangeAfterInsertion: NSRange(location: 0, length: (insertedText as NSString).length),
            prefixAnchor: "",
            suffixAnchor: ""
        )
    }

    private func temporaryFile(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ElegantWhisperTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name)
    }
}

@MainActor
private final class CallbackSchedulingSpy: AXObserverCallbackScheduling {
    var scheduleReadCount = 0

    func scheduleReadFromObserver() {
        scheduleReadCount += 1
    }
}
