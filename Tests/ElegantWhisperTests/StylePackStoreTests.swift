@testable import ElegantWhisper
import XCTest

final class StylePackStoreTests: XCTestCase {
    func testBuiltInPacksInitializeWithOneActivePack() throws {
        let store = StylePackStore(fileURL: try temporaryFile())
        let packs = store.packs()

        XCTAssertEqual(packs.count, 5)
        XCTAssertTrue(packs.contains { $0.id == StylePackStore.dictatePackID })
        XCTAssertEqual(packs.filter(\.active).count, 1)
        XCTAssertEqual(store.activePack().id, StylePackStore.programmerPackID)
    }

    func testStylePackPersistsPromptEdits() throws {
        let file = try temporaryFile()
        let store = StylePackStore(fileURL: file)
        var pack = store.activePack()
        pack.systemPrompt = "Edited prompt \(LLMPromptBuilder.hotwordPlaceholder)"
        store.save(pack)

        let reloaded = StylePackStore(fileURL: file)
        XCTAssertEqual(reloaded.activePack().systemPrompt, "Edited prompt \(LLMPromptBuilder.hotwordPlaceholder)")
    }

    func testSetActivePack() throws {
        let store = StylePackStore(fileURL: try temporaryFile())

        store.setActive(id: "builtin.technical")

        XCTAssertEqual(store.activePack().id, "builtin.technical")
        XCTAssertEqual(store.packs().filter(\.active).count, 1)
    }

    func testSeedTermsArePackMetadataOnly() throws {
        let store = StylePackStore(fileURL: try temporaryFile())

        XCTAssertTrue(StylePackStore.seedTerms(for: store.activePack().id).contains("Python"))

        let data = try JSONEncoder().encode(TestStylePackFile(version: 1, packs: store.packs()))
        let saved = String(data: data, encoding: .utf8)

        XCTAssertFalse(saved?.contains("seedTerms") ?? true)
    }

    func testResetBuiltinRestoresPrompt() throws {
        let store = StylePackStore(fileURL: try temporaryFile())
        var pack = store.activePack()
        pack.systemPrompt = "Broken"
        store.save(pack)

        XCTAssertTrue(store.resetBuiltin(id: pack.id))
        XCTAssertEqual(store.activePack().systemPrompt, LLMPromptBuilder.programmerTemplate)
    }

    func testExistingStorePromotesNewProgrammerPackOnce() throws {
        let file = try temporaryFile()
        let oldPacks = StylePackStore.builtinPacks
            .filter { $0.id != StylePackStore.programmerPackID }
            .enumerated()
            .map { offset, pack -> StylePack in
                var copy = pack
                copy.active = offset == 0
                return copy
            }
        let data = try JSONEncoder().encode(TestStylePackFile(version: 1, packs: oldPacks))
        try data.write(to: file)

        let store = StylePackStore(fileURL: file)

        XCTAssertEqual(store.activePack().id, StylePackStore.programmerPackID)
        XCTAssertEqual(store.packs().filter(\.active).count, 1)

        let migratedData = try Data(contentsOf: file)
        let migratedFile = try JSONDecoder().decode(TestStylePackFile.self, from: migratedData)
        XCTAssertTrue(migratedFile.packs.contains { $0.id == StylePackStore.programmerPackID })
        XCTAssertEqual(migratedFile.packs.first { $0.active }?.id, StylePackStore.programmerPackID)
    }

    func testEmptySavedPacksRestoreBuiltins() throws {
        let file = try temporaryFile()
        let data = try JSONEncoder().encode(TestStylePackFile(version: 1, packs: []))
        try data.write(to: file)

        let store = StylePackStore(fileURL: file)

        XCTAssertFalse(store.packs().isEmpty)
        XCTAssertEqual(store.packs().filter(\.active).count, 1)
        XCTAssertEqual(store.activePack().id, StylePackStore.programmerPackID)
        XCTAssertEqual(try savedPacks(at: file).filter(\.active).count, 1)
    }

    func testNoActivePackActivatesProgrammerPack() throws {
        let file = try temporaryFile()
        let packs = StylePackStore.builtinPacks.map { pack -> StylePack in
            var copy = pack
            copy.active = false
            return copy
        }
        let data = try JSONEncoder().encode(TestStylePackFile(version: 1, packs: packs))
        try data.write(to: file)

        let store = StylePackStore(fileURL: file)

        XCTAssertEqual(store.activePack().id, StylePackStore.programmerPackID)
        XCTAssertEqual(store.packs().filter(\.active).count, 1)
        XCTAssertEqual(try savedPacks(at: file).first { $0.active }?.id, StylePackStore.programmerPackID)
    }

    func testMultipleActivePacksKeepFirstActiveOnly() throws {
        let file = try temporaryFile()
        let packs = StylePackStore.builtinPacks.map { pack -> StylePack in
            var copy = pack
            copy.active = true
            return copy
        }
        let firstActive = try XCTUnwrap(packs.first?.id)
        let data = try JSONEncoder().encode(TestStylePackFile(version: 1, packs: packs))
        try data.write(to: file)

        let store = StylePackStore(fileURL: file)

        XCTAssertEqual(store.activePack().id, firstActive)
        XCTAssertEqual(store.packs().filter(\.active).count, 1)
        XCTAssertEqual(try savedPacks(at: file).filter(\.active).count, 1)
    }

    private func savedPacks(at file: URL) throws -> [StylePack] {
        let data = try Data(contentsOf: file)
        return try JSONDecoder().decode(TestStylePackFile.self, from: data).packs
    }

    private func temporaryFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ElegantWhisperTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("style-packs.json")
    }
}

private struct TestStylePackFile: Codable {
    let version: Int
    let packs: [StylePack]
}
