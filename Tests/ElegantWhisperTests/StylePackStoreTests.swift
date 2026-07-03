@testable import ElegantWhisper
import XCTest

final class StylePackStoreTests: XCTestCase {
    func testBuiltInPacksInitializeWithOneActivePack() throws {
        let store = StylePackStore(fileURL: try temporaryFile())
        let packs = store.packs()

        XCTAssertEqual(packs.count, 3)
        XCTAssertEqual(packs.filter(\.active).count, 1)
        XCTAssertEqual(store.activePack().id, "builtin.conservative")
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
        XCTAssertEqual(store.activePack().systemPrompt, LLMPromptBuilder.conservativeTemplate)
    }

    private func temporaryFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ElegantWhisperTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("style-packs.json")
    }
}
