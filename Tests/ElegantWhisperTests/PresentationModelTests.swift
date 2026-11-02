import XCTest
@testable import ElegantWhisper

final class PresentationModelTests: XCTestCase {
    @MainActor
    func testFloatingHUDKeepsBoundedNewestPreview() {
        let model = FloatingHUDModel()

        let longText = String(repeating: "x", count: 10) + String(repeating: "0123456789", count: 5)
        model.showRecording(text: longText)

        XCTAssertTrue(model.showsWaveform)
        XCTAssertEqual(model.text.count, FloatingHUDModel.previewLimit)
        XCTAssertTrue(longText.hasSuffix(model.text))
        model.showStatus("Polishing...")
        XCTAssertFalse(model.showsWaveform)
        XCTAssertEqual(model.phase, .working)
        XCTAssertEqual(model.text, "Polishing...")
        model.showStatus("Inserted", phase: .success)
        XCTAssertEqual(model.phase, .success)
    }

    @MainActor
    func testFloatingHUDWaveformKeepsNewestLevelFirst() {
        let model = FloatingHUDModel()
        model.showRecording(text: "")

        // Two audio buffers' worth of slices; one is consumed per display frame.
        model.enqueueLevels(Array(repeating: 0.8, count: 20))
        model.advanceFrame()
        XCTAssertGreaterThan(model.levels[0], 0)
        XCTAssertLessThan(model.levels[0], 0.8, "bars ease toward the level instead of jumping")
        for _ in 0..<19 {
            model.advanceFrame()
        }

        XCTAssertEqual(model.levels.count, FloatingHUDModel.waveformHistoryCount)
        XCTAssertEqual(model.levels[0], 0.8, accuracy: 0.01)
        XCTAssertGreaterThan(model.levels[3], 0.5, "older samples ripple outward")
        // With the queue empty the level decays instead of freezing.
        for _ in 0..<30 {
            model.advanceFrame()
        }
        XCTAssertLessThan(model.levels[0], 0.1)
        model.stopListening()
        XCTAssertFalse(model.showsWaveform)
        XCTAssertEqual(model.levels, [CGFloat](repeating: 0, count: FloatingHUDModel.waveformHistoryCount))
    }

    func testTranscriptNormalizationRemovesSpacesAroundCJKPunctuation() {
        XCTAssertEqual(
            SpeechEngine.normalizedTranscript("明天下午 3:30开会 ，记得把报告发给王经理 。 好的"),
            "明天下午 3:30开会，记得把报告发给王经理。好的"
        )
        XCTAssertEqual(
            SpeechEngine.normalizedTranscript("Restart Redis, then push."),
            "Restart Redis, then push."
        )
    }

    func testFloatingPanelPlacementHandlesNegativeScreenCoordinates() {
        let origin = FloatingPanelPlacement.origin(
            panelSize: NSSize(width: 196, height: 40),
            visibleFrame: NSRect(x: -1920, y: -120, width: 1920, height: 1080)
        )

        XCTAssertEqual(origin.x, -1058)
        XCTAssertEqual(origin.y, -72)
    }

    func testFloatingPanelPlacementClampsToSmallVisibleFrame() {
        let origin = FloatingPanelPlacement.origin(
            panelSize: NSSize(width: 196, height: 40),
            visibleFrame: NSRect(x: 10, y: 20, width: 120, height: 60)
        )

        XCTAssertEqual(origin.x, 10)
        XCTAssertEqual(origin.y, 40)
    }

    @MainActor
    func testSettingsDraftSurvivesRuntimeRefreshAndConnectionTestSavesFirst() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        fixture.model.settings.draft.provider = .custom
        fixture.model.settings.draft.baseURL = "not-a-valid-provider-url"
        fixture.model.settings.draft.apiKey = "test-key"
        fixture.model.settings.draft.model = "local-model"
        fixture.model.settings.draft.timeout = 7
        XCTAssertTrue(fixture.model.settings.isDirty)

        fixture.model.refreshAfterActivation()
        XCTAssertEqual(fixture.model.settings.draft.model, "local-model")

        fixture.model.testConnection()

        XCTAssertEqual(fixture.settings.llmProvider, .custom)
        XCTAssertEqual(fixture.settings.apiBaseURL, "not-a-valid-provider-url")
        XCTAssertEqual(fixture.settings.apiKey, "test-key")
        XCTAssertEqual(fixture.settings.model, "local-model")
        XCTAssertEqual(fixture.settings.requestTimeout, 7)
        XCTAssertFalse(fixture.model.settings.isDirty)
    }

    @MainActor
    func testSettingsBeginEditingReloadsPersistentValues() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        fixture.model.settings.draft.model = "Unsaved model"
        fixture.settings.model = "Persisted model"

        fixture.model.settings.beginEditing()

        XCTAssertEqual(fixture.model.settings.draft.model, "Persisted model")
        XCTAssertFalse(fixture.model.settings.isDirty)
    }

    @MainActor
    func testStyleDraftSwitchSaveAndReset() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let target = try XCTUnwrap(fixture.styles.packs().first { !$0.active })

        fixture.model.selectStyle(id: target.id)
        XCTAssertEqual(fixture.model.styles.draft.id, target.id)
        XCTAssertEqual(fixture.model.dictionary.activeStyleName, target.name)

        fixture.model.styles.draft.prompt = "Temporary test prompt"
        XCTAssertTrue(fixture.model.styles.isDirty)
        fixture.model.refreshAfterActivation()
        XCTAssertEqual(fixture.model.styles.draft.prompt, "Temporary test prompt")
        fixture.model.saveStyle()
        XCTAssertEqual(fixture.styles.activePack().systemPrompt, "Temporary test prompt")
        XCTAssertFalse(fixture.model.styles.isDirty)

        fixture.model.resetStyle()
        let builtin = try XCTUnwrap(StylePackStore.builtinPacks.first { $0.id == target.id })
        XCTAssertEqual(fixture.styles.activePack().systemPrompt, builtin.systemPrompt)
    }

    @MainActor
    func testHistoryItemRoutesToDictionaryDraft() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let item = HistoryItem(
            id: UUID(),
            createdAt: Date(),
            appName: "Tests",
            bundleIdentifier: nil,
            text: "SwiftUI",
            result: .copied
        )

        fixture.model.useHistoryAsDictionaryTerm(item)

        XCTAssertEqual(fixture.model.route, .dictionary)
        XCTAssertEqual(fixture.model.dictionary.term, "SwiftUI")
    }

    @MainActor
    func testOpenSettingsSelectsMainWindowSettingsRoute() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        fixture.model.openSettings()

        XCTAssertEqual(fixture.model.route, .settings)
    }

    @MainActor
    func testOpenAboutSelectsMainWindowAboutRoute() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        fixture.model.openAbout()

        XCTAssertEqual(fixture.model.route, .about)
    }

    @MainActor
    func testOnboardingCompletionPersistsAndReplayKeepsItCompleted() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        XCTAssertFalse(fixture.model.onboardingCompleted)
        fixture.model.completeOnboarding()
        XCTAssertTrue(fixture.model.onboardingCompleted)
        XCTAssertTrue(fixture.settings.onboardingCompleted)

        fixture.model.prepareTutorialReplay()
        XCTAssertTrue(fixture.model.onboardingCompleted)
        XCTAssertTrue(fixture.settings.onboardingCompleted)
    }
}

final class VoiceLevelMeterTests: XCTestCase {
    private func rms(db: Float) -> Float {
        pow(10, db / 20)
    }

    private func settle(_ meter: inout VoiceLevelMeter, db: Float, chunks: Int) -> Float {
        var level: Float = 0
        for _ in 0..<chunks {
            level = meter.process(rms: rms(db: db))
        }
        return level
    }

    func testSteadyBackgroundNoiseReadsAsSilence() {
        var meter = VoiceLevelMeter()
        // Two seconds of a fan at -50 dBFS.
        XCTAssertLessThan(settle(&meter, db: -50, chunks: 120), 0.05)

        // A noisier room (-40 dBFS) is learned within a few seconds.
        var noisy = VoiceLevelMeter()
        XCTAssertLessThan(settle(&noisy, db: -40, chunks: 180), 0.05)
    }

    func testSpeechSitsMidRangeAndShoutingStaysBelowTheTop() {
        var meter = VoiceLevelMeter()
        _ = settle(&meter, db: -55, chunks: 60)

        let speech = settle(&meter, db: -25, chunks: 30)
        XCTAssertGreaterThan(speech, 0.45)
        XCTAssertLessThan(speech, 0.8)

        let shout = settle(&meter, db: -3, chunks: 30)
        XCTAssertGreaterThan(shout, speech)
        XCTAssertLessThanOrEqual(shout, VoiceLevelMeter.ceiling)
        XCTAssertLessThan(shout, 0.9)
    }

    func testBarsSettleGentlyAfterSpeechStops() {
        var meter = VoiceLevelMeter()
        _ = settle(&meter, db: -55, chunks: 60)
        let speaking = settle(&meter, db: -25, chunks: 30)

        let afterOneFrame = meter.process(rms: rms(db: -55))
        XCTAssertGreaterThan(afterOneFrame, speaking * 0.8, "no sudden drop")
        let afterHalfSecond = settle(&meter, db: -55, chunks: 30)
        XCTAssertLessThan(afterHalfSecond, 0.05)
    }
}

final class DashboardModelTests: XCTestCase {
    func testWordCountTreatsCJKCharactersAsWords() {
        XCTAssertEqual(UsageStats.wordCount("Don't restart Redis 2 times"), 5)
        XCTAssertEqual(UsageStats.wordCount("我想用 Python 解析"), 6)
        XCTAssertEqual(UsageStats.wordCount("  "), 0)
    }

    func testUsageStatsPaceAndTimeSaved() {
        var stats = UsageStats()
        stats.record(text: String(repeating: "word ", count: 120), duration: 60)

        XCTAssertEqual(stats.dictations, 1)
        XCTAssertEqual(stats.wordsPerMinute, 120)
        // 120 words take 3 minutes to type at 40 wpm; speaking took 1 minute.
        XCTAssertEqual(stats.minutesSaved, 2, accuracy: 0.001)
    }

    func testInsightsStreakAndWeek() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 12)))
        func item(daysAgo: Int, result: HistoryResult = .pasteAttempted) -> HistoryItem {
            HistoryItem(
                id: UUID(),
                createdAt: calendar.date(byAdding: .day, value: -daysAgo, to: now)!,
                appName: nil,
                bundleIdentifier: nil,
                text: "hello world",
                result: result
            )
        }
        // Yesterday and the two days before count; today is empty, and day 4 breaks the run.
        let items = [item(daysAgo: 1), item(daysAgo: 2), item(daysAgo: 3), item(daysAgo: 5), item(daysAgo: 9), item(daysAgo: 0, result: .failed)]
        let insights = HistoryInsights(items: items, now: now, calendar: calendar)

        XCTAssertEqual(insights.streakDays, 3)
        XCTAssertEqual(insights.dictationsThisWeek, 4)
        XCTAssertEqual(insights.dailyWords.count, 14)
        XCTAssertEqual(insights.dailyWords.last?.words, 0)
        XCTAssertEqual(insights.dailyWords[12].words, 2)
    }

    func testHistoryGroupsByDayNewestFirst() throws {
        let calendar = Calendar(identifier: .gregorian)
        let base = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 15)))
        let times = [0.0, -3_600, -86_400, -90_000].map { base.addingTimeInterval($0) }
        let items = times.map {
            HistoryItem(id: UUID(), createdAt: $0, appName: nil, bundleIdentifier: nil, text: "x", result: .copied)
        }
        let sections = HistoryDaySection.group(items, calendar: calendar)

        XCTAssertEqual(sections.map(\.items.count), [2, 2])
        XCTAssertEqual(sections.first?.items.first?.id, items.first?.id)
    }

    @MainActor
    func testImmediateSettingAppliesAndSyncsFromMenuBar() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let settings = fixture.model.settings
        settings.draft.model = "unsaved-model"

        settings.immediate(\.language) { $0.language = $1 }.wrappedValue = .japanese
        XCTAssertEqual(fixture.settings.language, .japanese)
        XCTAssertEqual(fixture.model.currentLanguage, .japanese)

        // A change from the menu bar must reach the open form without clobbering unsaved fields.
        fixture.model.setLLMEnabled(true)
        XCTAssertTrue(settings.draft.llmEnabled)
        XCTAssertEqual(settings.draft.model, "unsaved-model")
        XCTAssertTrue(settings.isDirty)
    }
}

@MainActor
private final class Fixture {
    let root: URL
    let suiteName: String
    let keychain: KeychainStore
    let settings: SettingsStore
    let styles: StylePackStore
    let model: AppModel

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ElegantWhisper-PresentationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        suiteName = "com.aetherallan.ElegantWhisper.presentation-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        keychain = KeychainStore(service: suiteName)
        settings = SettingsStore(defaults: defaults, keychain: keychain)
        styles = StylePackStore(fileURL: root.appendingPathComponent("styles.json"))
        let controller = AppController(settings: settings, stylePacks: styles)
        model = AppModel(
            controller: controller,
            settings: settings,
            history: HistoryStore(fileURL: root.appendingPathComponent("history.json")),
            dictionary: DictionaryStore(fileURL: root.appendingPathComponent("dictionary.json")),
            candidates: LearningCandidateStore(fileURL: root.appendingPathComponent("candidates.json")),
            styles: styles
        )
    }

    func cleanup() {
        keychain.setString("", for: "apiKey")
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }
}
