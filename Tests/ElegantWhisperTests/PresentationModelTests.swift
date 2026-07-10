import XCTest
@testable import ElegantWhisper

final class PresentationModelTests: XCTestCase {
    @MainActor
    func testFloatingHUDKeepsBoundedNewestPreview() {
        let model = FloatingHUDModel()

        model.showRecording(text: "1234567890abcdefghijkl")

        XCTAssertTrue(model.showsWaveform)
        XCTAssertEqual(model.text, "7890abcdefghijkl")
        model.showStatus("Polishing...")
        XCTAssertFalse(model.showsWaveform)
        XCTAssertEqual(model.text, "Polishing...")
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
