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
