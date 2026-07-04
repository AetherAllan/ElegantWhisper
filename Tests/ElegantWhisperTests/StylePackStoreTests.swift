@testable import ElegantWhisper
import XCTest

final class StylePackStoreTests: XCTestCase {
    func testBuiltInPacksInitializeWithOneActivePack() throws {
        let store = StylePackStore(fileURL: try temporaryFile())
        let packs = store.packs()

        XCTAssertEqual(packs.count, 4)
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
