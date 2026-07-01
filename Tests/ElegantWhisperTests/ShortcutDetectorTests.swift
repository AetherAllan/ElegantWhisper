import ApplicationServices
@testable import ElegantWhisper
import XCTest

final class ShortcutDetectorTests: XCTestCase {
    func testSingleLeftCommandTogglesOnRelease() {
        let detector = ShortcutDetector()

        XCTAssertNil(detector.handleFlagsChanged(keyCode: 55, flags: [.maskCommand]))
        XCTAssertEqual(detector.handleFlagsChanged(keyCode: 55, flags: []), .toggle)
    }

    func testSingleRightOptionTogglesOnRelease() {
        let detector = ShortcutDetector()

        XCTAssertNil(detector.handleFlagsChanged(keyCode: 61, flags: [.maskAlternate]))
        XCTAssertEqual(detector.handleFlagsChanged(keyCode: 61, flags: []), .toggle)
    }

    func testCommandChordDoesNotToggle() {
        let detector = ShortcutDetector()

        XCTAssertNil(detector.handleFlagsChanged(keyCode: 55, flags: [.maskCommand]))
        XCTAssertNil(detector.handleKeyDown(keyCode: 8))
        XCTAssertNil(detector.handleFlagsChanged(keyCode: 55, flags: []))
    }

    func testLeftRightCommandChordResetsAfterAllKeysRelease() {
        let detector = ShortcutDetector()

        XCTAssertNil(detector.handleFlagsChanged(keyCode: 55, flags: [.maskCommand]))
        XCTAssertNil(detector.handleFlagsChanged(keyCode: 54, flags: [.maskCommand]))
        XCTAssertNil(detector.handleFlagsChanged(keyCode: 55, flags: [.maskCommand]))
        XCTAssertNil(detector.handleFlagsChanged(keyCode: 54, flags: []))

        XCTAssertNil(detector.handleFlagsChanged(keyCode: 55, flags: [.maskCommand]))
        XCTAssertEqual(detector.handleFlagsChanged(keyCode: 55, flags: []), .toggle)
    }

    func testCommandOptionCrossChordDoesNotToggle() {
        let detector = ShortcutDetector()

        XCTAssertNil(detector.handleFlagsChanged(keyCode: 55, flags: [.maskCommand]))
        XCTAssertNil(detector.handleFlagsChanged(keyCode: 58, flags: [.maskCommand, .maskAlternate]))
        XCTAssertNil(detector.handleFlagsChanged(keyCode: 55, flags: [.maskAlternate]))
        XCTAssertNil(detector.handleFlagsChanged(keyCode: 58, flags: []))
    }

    func testEscapeCancelsAndResetsDetector() {
        let detector = ShortcutDetector()

        XCTAssertNil(detector.handleFlagsChanged(keyCode: 55, flags: [.maskCommand]))
        XCTAssertEqual(detector.handleKeyDown(keyCode: 53), .cancel)
        XCTAssertNil(detector.handleFlagsChanged(keyCode: 55, flags: []))
    }

    func testStrayModifierReleaseDoesNotArmDetector() {
        let detector = ShortcutDetector()

        XCTAssertNil(detector.handleFlagsChanged(keyCode: 55, flags: []))
        XCTAssertNil(detector.handleFlagsChanged(keyCode: 55, flags: []))
    }
}
